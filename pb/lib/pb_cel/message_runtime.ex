defmodule PB.CEL.MessageRuntime do
  @moduledoc false

  # Protobuf-backed implementation of the `PB.CEL.Message.Runtime` behaviour.
  #
  # This is the adapter that binds CEL evaluation to PB's protobuf message
  # representation: schema-backed field access, schema-projection/adapter
  # conversion, well-known-type conversion, raw-field normalization, and `Any`
  # packing/unpacking. It is part of the protobuf binding (`lib/pb_cel`) rather
  # than the CEL subsystem so the subsystem keeps no logic edges back to the
  # protobuf runtime; callers inject it via `PB.CEL.Env`'s `:message_runtime`
  # (and the evaluator's `:message_runtime` option).

  alias PB.CEL.FieldReader
  alias PB.CEL.MessageSchema, as: Schema
  alias PB.CEL.Runtime.Time
  alias PB.CEL.Schema.Field
  alias PB.CEL.Value
  alias PB.CEL.WellKnownTypes
  alias PB.Runtime.Codec
  alias PB.Runtime.Errors
  alias PB.Runtime.MessageView
  alias PB.Runtime.MessageEquality
  alias PB.WellKnownTypes.Any
  alias PB.WellKnownTypes.Codec, as: WKTCodec
  alias PB.WellKnownTypes.Time, as: WKTTime
  alias PB.Runtime.Representation
  alias PB.Runtime.Scalar
  alias PB.Wire

  require Field

  @behaviour PB.CEL.Message.Runtime

  @nanos_per_second 1_000_000_000
  @json_exact_integer_limit 9_007_199_254_740_992
  @adapted_payload :__pb_adapted_message__

  @timestamp_type "google.protobuf.Timestamp"
  @duration_type "google.protobuf.Duration"

  @type t :: {:message, atom(), term()}

  @spec from_decoded(Schema.schema(), atom(), term()) :: {:ok, Value.t()} | {:error, term}
  def from_decoded(schema, message, decoded) when is_atom(message) do
    with {:ok, msg} <- Schema.fetch_message(schema, message) do
      cond do
        adapter = message_adapter(msg) ->
          from_adapted_decoded(schema, message, adapter, decoded)

        represented?(msg) ->
          {:ok, {:message, message, decoded}}

        true ->
          from_proto_decoded(schema, message, decoded)
      end
    else
      :error -> {:error, {:unknown_message, message}}
    end
  end

  def from_decoded(_schema, _message, _decoded), do: {:error, :invalid_message}

  @spec from_proto_fields(Schema.schema(), atom(), map()) :: {:ok, Value.t()} | {:error, term}
  def from_proto_fields(schema, message, fields) when is_atom(message) and is_map(fields) do
    case well_known_decoded_value(schema, message, fields) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, {:message, message, fields}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec from_literal(Schema.schema(), atom(), [map()], boolean()) ::
          {:ok, Value.t()} | :unknown | {:error, term}
  def from_literal(schema, message, fields, wkt_unwrap?)
      when is_atom(message) and is_list(fields) and is_boolean(wkt_unwrap?) do
    with {:ok, {:message, message, payload}} <- from_literal_message(schema, message, fields) do
      if wkt_unwrap? do
        case well_known_decoded_value(schema, message, payload) do
          {:ok, value} -> {:ok, value}
          :error -> {:ok, {:message, message, payload}}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, {:message, message, payload}}
      end
    else
      :unknown -> :unknown
      {:error, reason} -> {:error, reason}
    end
  end

  def from_literal(_schema, _message, _fields, _wkt_unwrap?), do: :unknown

  @spec from_literal_message(Schema.schema(), atom(), [map()]) ::
          {:ok, t()} | :unknown | {:error, term}
  def from_literal_message(schema, message, fields) when is_atom(message) and is_list(fields) do
    with {:ok, fields} <- literal_fields(schema, message, fields) do
      {:ok, {:message, message, fields}}
    else
      :error -> :unknown
      {:error, reason} -> {:error, reason}
    end
  end

  def from_literal_message(_schema, _message, _fields), do: :unknown

  @spec select(Schema.schema(), t(), String.t(), boolean()) ::
          {:ok, Value.t()} | :not_applicable | {:error, term}
  def select(schema, {:message, message, fields}, field, test_only?)
      when is_atom(message) and is_binary(field) do
    with {:ok, msg} <- Schema.fetch_message(schema, message),
         {:ok, fields} <- proto_fields(schema, message, msg, fields, []),
         {:ok, %{field: field, info: info}} <- resolve_field(schema, message, field) do
      if test_only? do
        {:ok, Value.bool(FieldReader.present?(schema, msg, fields, field, info))}
      else
        FieldReader.read(schema, msg, fields, field, info)
      end
    else
      :unknown_message -> :not_applicable
      :unknown_field -> {:error, "no such field #{inspect(field)}"}
      {:error, reason} -> {:error, reason}
      :error -> :not_applicable
    end
  end

  def select(_schema, _message, _field, _test_only?), do: :not_applicable

  @spec select_ref(Schema.schema(), t(), Schema.field_ref(), boolean()) ::
          {:ok, Value.t()} | :not_applicable | {:error, term}
  def select_ref(
        schema,
        {:message, message, fields},
        %{message: message, field: field},
        test_only?
      )
      when is_atom(message) and is_atom(field) do
    case Schema.fetch_message(schema, message) do
      {:ok, msg} ->
        with {:ok, fields} <- proto_fields(schema, message, msg, fields, []),
             {:ok, info} <- Map.fetch(msg.fields_by_name, field) do
          if test_only? do
            {:ok, Value.bool(FieldReader.present?(schema, msg, fields, field, info))}
          else
            FieldReader.read(schema, msg, fields, field, info)
          end
        else
          {:error, reason} ->
            {:error, reason}

          :error ->
            {:error, "no such field #{inspect(Atom.to_string(field))}"}
        end

      :error ->
        {:error, "unknown message #{inspect(Atom.to_string(message))}"}
    end
  end

  def select_ref(
        schema,
        {:message, message, fields},
        %{message: message, extension: extension},
        test_only?
      )
      when is_atom(message) and is_atom(extension) do
    case Schema.fetch_message(schema, message) do
      {:ok, msg} ->
        with {:ok, fields} <- proto_fields(schema, message, msg, fields, []),
             {:ok, info} <- Map.fetch(msg.extensions_by_name, extension) do
          if test_only? do
            {:ok, Value.bool(FieldReader.extension_present?(schema, msg, fields, extension, info))}
          else
            FieldReader.read_extension(schema, msg, fields, extension, info)
          end
        else
          {:error, reason} ->
            {:error, reason}

          :error ->
            {:error, "no such field #{inspect(Atom.to_string(extension))}"}
        end

      :error ->
        {:error, "unknown message #{inspect(Atom.to_string(message))}"}
    end
  end

  def select_ref(_schema, {:message, actual, _fields}, %{message: expected}, _test_only?)
      when is_atom(actual) and is_atom(expected) do
    {:error,
     "expected message #{inspect(Atom.to_string(expected))}, got #{inspect(Atom.to_string(actual))}"}
  end

  def select_ref(_schema, _message, _field_ref, _test_only?), do: :not_applicable

  @spec optional_select(Schema.schema(), Value.t(), String.t()) ::
          {:ok, Value.t()} | :not_applicable | {:error, term}
  def optional_select(schema, {:message, message, fields}, field)
      when is_atom(message) and is_binary(field) do
    with {:ok, msg} <- Schema.fetch_message(schema, message),
         {:ok, fields} <- proto_fields(schema, message, msg, fields, []),
         {:ok, %{field: field, info: info}} <- resolve_field(schema, message, field) do
      FieldReader.read_optional(schema, msg, fields, field, info)
    else
      :unknown_message -> :not_applicable
      :unknown_field -> {:ok, Value.optional_none()}
      {:error, reason} -> {:error, reason}
      :error -> :not_applicable
    end
  end

  def optional_select(_schema, _message, _field), do: :not_applicable

  @spec optional_select_ref(Schema.schema(), Value.t(), Schema.field_ref()) ::
          {:ok, Value.t()} | :not_applicable | {:error, term}
  def optional_select_ref(
        schema,
        {:message, message, fields},
        %{message: message, field: field}
      )
      when is_atom(message) and is_atom(field) do
    case Schema.fetch_message(schema, message) do
      {:ok, msg} ->
        with {:ok, fields} <- proto_fields(schema, message, msg, fields, []),
             {:ok, info} <- Map.fetch(msg.fields_by_name, field) do
          FieldReader.read_optional(schema, msg, fields, field, info)
        else
          {:error, reason} ->
            {:error, reason}

          :error ->
            {:error, "no such field #{inspect(Atom.to_string(field))}"}
        end

      :error ->
        {:error, "unknown message #{inspect(Atom.to_string(message))}"}
    end
  end

  def optional_select_ref(_schema, {:message, actual, _fields}, %{message: expected})
      when is_atom(actual) and is_atom(expected) do
    {:error,
     "expected message #{inspect(Atom.to_string(expected))}, got #{inspect(Atom.to_string(actual))}"}
  end

  def optional_select_ref(_schema, _message, _field_ref), do: :not_applicable

  @spec field_value(Schema.schema(), map(), term()) :: {:ok, Value.t()} | {:error, term}
  def field_value(schema, %{cardinality: :repeated} = field, values) when is_list(values) do
    field = maybe_enum_field(schema, field)

    with {:ok, values} <- map_while_ok(values, &singular_field_value(schema, field, &1)) do
      {:ok, Value.list(values)}
    end
  end

  def field_value(
        schema,
        %{cardinality: :map, map_key: key_field, map_value: value_field},
        values
      )
      when is_map(values) do
    key_field = maybe_enum_field(schema, key_field)
    value_field = maybe_enum_field(schema, value_field)

    values
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- singular_field_value(schema, key_field, key),
           {:ok, value} <- singular_field_value(schema, value_field, value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Value.map(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  def field_value(schema, field, value) do
    singular_field_value(schema, maybe_enum_field(schema, field), value)
  end

  @spec raw_fields_for_encode(Schema.schema(), atom(), term()) :: {:ok, map()} | {:error, term()}
  def raw_fields_for_encode(schema, message, fields) when is_atom(message) do
    with {:ok, msg} <- Schema.fetch_message(schema, message),
         {:ok, fields} <- proto_fields(schema, message, msg, fields, []) do
      FieldReader.raw_fields_for_encode(schema, message, fields)
    else
      :error -> {:ok, fields}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec equal?(Schema.schema(), t(), t()) :: {:ok, boolean()} | :not_applicable
  def equal?(schema, {:message, left_name, left_fields}, {:message, right_name, right_fields})
      when is_atom(left_name) and is_atom(right_name) do
    with true <- left_name == right_name,
         {:ok, msg} <- Schema.fetch_message(schema, left_name),
         {:ok, left_fields} <- proto_fields(schema, left_name, msg, left_fields, []),
         {:ok, right_fields} <- proto_fields(schema, right_name, msg, right_fields, []),
         {:ok, equal?} <- MessageEquality.equal?(schema, left_name, left_fields, right_fields) do
      {:ok, equal?}
    else
      false -> {:ok, false}
      _error -> :not_applicable
    end
  end

  def equal?(_schema, _left, _right), do: :not_applicable

  # Any host is accepted: the last path segment names the message, as for
  # ProtoJSON and Go's resolvers. `Timestamp` and `Duration` unpack without a
  # schema; other messages unpack when the schema knows them and are otherwise
  # kept as an opaque object value.
  @spec from_any(Schema.schema(), String.t(), binary) :: {:ok, Value.t()} | {:error, term}
  def from_any(schema, type_url, value) when is_binary(type_url) and is_binary(value) do
    case WellKnownTypes.type_url_name(type_url) do
      @timestamp_type ->
        with {:ok, message} <- WKTCodec.decode_timestamp(value) do
          WKTTime.from_proto_timestamp(message)
        end

      @duration_type ->
        with {:ok, message} <- WKTCodec.decode_duration(value),
             {:ok, {:duration, ns}} <- WKTTime.from_proto_duration(message),
             true <- Time.duration_ns?(ns) do
          {:ok, Value.duration(ns)}
        else
          false -> {:error, :duration_out_of_range}
          {:error, reason} -> {:error, reason}
        end

      name ->
        case Schema.resolve_message(schema, name) do
          {:ok, message} ->
            with {:ok, decoded} <- PB.decode(value, schema, message),
                 {:ok, value} <- from_decoded(schema, message, decoded) do
              {:ok, value}
            else
              {:error, reason} -> {:error, {:object_decode_error, message, reason}}
            end

          :error ->
            {:ok, Value.object(type_url, value)}
        end
    end
  end

  @spec to_any(Schema.schema(), Value.t()) :: {:ok, map} | {:error, term}
  def to_any(_schema, {:timestamp, _ns} = value) do
    with {:ok, message} <- WKTTime.to_proto_timestamp(value),
         {:ok, iodata} <- WKTCodec.encode_timestamp(message) do
      {:ok, %{type_url: Any.type_url(@timestamp_type), value: IO.iodata_to_binary(iodata)}}
    end
  end

  def to_any(_schema, {:duration, _ns} = value) do
    with {:ok, message} <- WKTTime.to_proto_duration(value),
         {:ok, iodata} <- WKTCodec.encode_duration(message) do
      {:ok, %{type_url: Any.type_url(@duration_type), value: IO.iodata_to_binary(iodata)}}
    end
  end

  defp from_adapted_decoded(schema, message, adapter, decoded) do
    if well_known_message?(schema, message) do
      with {:ok, fields} <- Codec.adapter_to_proto(adapter, message, decoded, []) do
        from_proto_decoded(schema, message, fields)
      end
    else
      {:ok, {:message, message, {@adapted_payload, decoded}}}
    end
  end

  defp from_proto_decoded(schema, message, decoded) when is_map(decoded) do
    case well_known_decoded_value(schema, message, decoded) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, {:message, message, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_proto_decoded(_schema, :"google.protobuf.Timestamp", {:timestamp, _ns} = value),
    do: {:ok, value}

  defp from_proto_decoded(_schema, :"google.protobuf.Duration", {:duration, _ns} = value),
    do: {:ok, value}

  defp from_proto_decoded(_schema, message, decoded) do
    {:error, {:invalid_message_value, message, decoded}}
  end

  defp proto_fields(_schema, _message, msg, fields, path)
       when is_map(fields) and not is_struct(fields) do
    if represented?(msg) do
      Representation.canonicalize_proto_fields(msg, fields, path)
    else
      {:ok, fields}
    end
  end

  defp proto_fields(
         _schema,
         message,
         %{projection: %{adapter: adapter}},
         {@adapted_payload, value},
         path
       )
       when not is_nil(adapter) do
    Codec.adapter_to_proto(adapter, message, value, path)
  end

  defp proto_fields(schema, message, msg, fields, path) do
    MessageView.to_proto_fields(schema, message, msg, fields, path)
  end

  defp represented?(%{projection: projection}) do
    projection.struct_mod != nil or projection.unwrap_field != nil or
      map_size(projection.oneofs) > 0
  end

  defp represented?(_msg), do: false

  defp message_adapter(%{projection: %{adapter: adapter}}) when not is_nil(adapter), do: adapter
  defp message_adapter(_msg), do: nil

  defp well_known_message?(schema, message) do
    message in [
      :"google.protobuf.Any",
      :"google.protobuf.Timestamp",
      :"google.protobuf.Duration",
      :"google.protobuf.Value",
      :"google.protobuf.ListValue",
      :"google.protobuf.Struct"
    ] or FieldReader.wrapper_field(schema, message) != nil
  end

  defp resolve_field(schema, message, field) do
    case Schema.field(schema, message, field) do
      {:ok, field} -> {:ok, field}
      :unknown_message -> :unknown_message
      :unknown_field -> :unknown_field
    end
  end

  defp oneof_by_name(msg, name) do
    Enum.find_value(msg.oneofs, fn {_index, oneof} ->
      if oneof.name == name, do: oneof
    end)
  end

  defp literal_fields(schema, message, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      with {:ok, info} <- Schema.field_info_ref(schema, field.field_ref),
           {:ok, entry} <- raw_literal_entry(schema, message, field, info, field.value) do
        case entry do
          nil ->
            {:cont, {:ok, acc}}

          {key, value} ->
            {:cont, {:ok, Map.put(acc, key, value)}}
        end
      else
        :error ->
          {:halt, {:error, "no such field #{inspect(field.field)}"}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp raw_literal_entry(_schema, _message, _field, info, :null)
       when info.cardinality == :singular and Field.message_type?(info.type) and
              info.type_name != :"google.protobuf.Value",
       do: {:ok, nil}

  defp raw_literal_entry(schema, message, field, info, value) do
    with {:ok, value} <- raw_field_value(schema, info, value),
         {:ok, value} <- normalized_raw_field_value(schema, message, info, value, [field.field]) do
      {:ok, literal_entry(field, value)}
    end
  end

  defp literal_entry(_field, :omit), do: nil

  defp literal_entry(%{cardinality: :oneof, oneof_name: oneof_name, field: field}, value),
    do: {oneof_name, {field, value}}

  defp literal_entry(%{field: field}, value), do: {field, value}

  defp normalized_raw_field_value(
         schema,
         message,
         %{cardinality: :repeated} = field,
         values,
         path
       )
       when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalized_singular_raw_value(schema, message, field, value, path ++ [{:index, index}],
             omit_default?: false
           ) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, :omit}
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalized_raw_field_value(
         schema,
         message,
         %{cardinality: :map, map_key: key_field, map_value: value_field},
         values,
         path
       )
       when is_map(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      entry_path = path ++ [{:key, key}]

      with {:ok, key} <-
             normalized_singular_raw_value(
               schema,
               message,
               key_field,
               key,
               entry_path ++ [:key],
               omit_default?: false
             ),
           {:ok, value} <-
             normalized_singular_raw_value(
               schema,
               message,
               value_field,
               value,
               entry_path ++ [:value],
               omit_default?: false
             ) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} when map_size(values) == 0 -> {:ok, :omit}
      result -> result
    end
  end

  defp normalized_raw_field_value(schema, message, field, value, path) do
    normalized_singular_raw_value(schema, message, field, value, path, omit_default?: true)
  end

  defp normalized_singular_raw_value(
         schema,
         message,
         %{type: type, type_name: type_name},
         value,
         path,
         _opts
       )
       when Field.message_type?(type) and is_map(value) do
    normalize_message_raw_value(schema, message, type_name, value, path)
  end

  defp normalized_singular_raw_value(schema, message, field, value, path, opts) do
    field = maybe_enum_field(schema, field)

    with :ok <- Scalar.validate_encode(field, value, path) do
      value = canonical_scalar_value(field, value)

      if Keyword.fetch!(opts, :omit_default?) and Scalar.implicit_presence?(field) and
           Scalar.default_value?(field, value) do
        {:ok, :omit}
      else
        {:ok, value}
      end
    else
      {:error, reason} -> {:error, Errors.to_error(reason, :normalize, message)}
    end
  end

  defp normalize_message_raw_value(schema, message, type_name, fields, path) do
    if field = FieldReader.wrapper_field(schema, type_name) do
      normalize_wrapper_raw_value(schema, message, field, fields, path)
    else
      with {:ok, msg} <- Schema.fetch_message(schema, type_name) do
        normalize_message_raw_fields(schema, message, msg, fields, path)
      else
        :error -> {:ok, fields}
      end
    end
  end

  defp normalize_message_raw_fields(schema, message, msg, fields, path) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        field = msg.fields_by_name[key] ->
          case normalized_raw_field_value(schema, message, field, value, path ++ [key]) do
            {:ok, :omit} -> {:cont, {:ok, acc}}
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        oneof = oneof_by_name(msg, key) ->
          case normalize_oneof_raw_value(schema, message, msg, oneof, value, path ++ [key]) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
          {:halt,
           {:error,
            Errors.to_error({:unknown_field, message, path ++ [key]}, :normalize, message)}}
      end
    end)
  end

  defp normalize_oneof_raw_value(schema, message, msg, oneof, {field, value}, path)
       when is_atom(field) do
    cond do
      field not in oneof.fields ->
        {:error,
         Errors.to_error({:invalid_oneof, path, {:unknown_member, field}}, :normalize, message)}

      info = msg.fields_by_name[field] ->
        case normalized_singular_raw_value(
               schema,
               message,
               info,
               value,
               path ++ [field],
               omit_default?: false
             ) do
          {:ok, :omit} -> {:ok, nil}
          {:ok, value} -> {:ok, {field, value}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error,
         Errors.to_error({:invalid_oneof, path, {:unknown_member, field}}, :normalize, message)}
    end
  end

  defp normalize_oneof_raw_value(_schema, _message, _msg, _oneof, nil, _path), do: {:ok, nil}

  defp normalize_oneof_raw_value(_schema, message, _msg, _oneof, _value, path) do
    {:error, Errors.to_error({:invalid_oneof, path, :expected_member_tuple}, :normalize, message)}
  end

  defp normalize_wrapper_raw_value(schema, message, field, fields, path) do
    field = Map.put_new(field, :presence, :implicit)

    case Map.fetch(fields, :value) do
      {:ok, value} ->
        case normalized_singular_raw_value(schema, message, field, value, path ++ [:value],
               omit_default?: true
             ) do
          {:ok, :omit} -> {:ok, %{}}
          {:ok, value} -> {:ok, %{value: value}}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:ok, %{}}
    end
  end

  defp canonical_scalar_value(%{type: :TYPE_FLOAT}, value) do
    value
    |> Wire.encode_float32()
    |> Wire.decode_float32()
  end

  defp canonical_scalar_value(%{type: :TYPE_DOUBLE}, value) do
    value
    |> Wire.encode_float64()
    |> Wire.decode_float64()
  end

  defp canonical_scalar_value(_field, value), do: value

  defp raw_field_value(schema, %{cardinality: :repeated} = field, {:list, values}) do
    map_while_ok(values, &singular_raw_value(schema, field, &1))
  end

  defp raw_field_value(
         schema,
         %{cardinality: :map, map_key: key_field, map_value: value_field},
         {:map, values}
       ) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- singular_raw_value(schema, key_field, key),
           {:ok, value} <- singular_raw_value(schema, value_field, value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp raw_field_value(schema, field, value), do: singular_raw_value(schema, field, value)

  defp singular_field_value(_schema, %{type: type}, value) when Field.signed_int_type?(type) do
    {:ok, Value.int(value)}
  end

  defp singular_field_value(_schema, %{type: type}, value) when Field.unsigned_int_type?(type) do
    {:ok, Value.uint(value)}
  end

  defp singular_field_value(_schema, %{type: type}, value)
       when Field.float_type?(type) do
    {:ok, Value.double(value)}
  end

  defp singular_field_value(_schema, %{type: :TYPE_BOOL}, value), do: {:ok, Value.bool(value)}
  defp singular_field_value(_schema, %{type: :TYPE_STRING}, value), do: {:ok, Value.string(value)}
  defp singular_field_value(_schema, %{type: :TYPE_BYTES}, value), do: {:ok, Value.bytes(value)}

  defp singular_field_value(_schema, %{type: :TYPE_ENUM, type_name: type_name} = field, value) do
    with {:ok, number} <- enum_number(field, value) do
      {:ok, Value.enum(Atom.to_string(type_name), number)}
    end
  end

  defp singular_field_value(_schema, %{type: :TYPE_ENUM} = field, value) do
    with {:ok, number} <- enum_number(field, value) do
      {:ok, Value.int(number)}
    end
  end

  defp singular_field_value(schema, %{type: type, type_name: type_name}, value)
       when Field.message_type?(type) do
    from_decoded(schema, type_name, value)
  end

  defp singular_field_value(_schema, %{type: type}, value) do
    {:error, {:unsupported_field_value, type, value}}
  end

  defp singular_raw_value(_schema, %{type: type}, {:int, value})
       when Field.signed_int_type?(type) do
    {:ok, value}
  end

  defp singular_raw_value(_schema, %{type: type}, {:uint, value})
       when Field.unsigned_int_type?(type) do
    {:ok, value}
  end

  defp singular_raw_value(_schema, %{type: type}, {:double, value})
       when type == :TYPE_DOUBLE do
    {:ok, value}
  end

  defp singular_raw_value(_schema, %{type: :TYPE_FLOAT}, {:double, value}) do
    {:ok, value}
  end

  defp singular_raw_value(_schema, %{type: :TYPE_BOOL}, {:bool, value}), do: {:ok, value}
  defp singular_raw_value(_schema, %{type: :TYPE_STRING}, {:string, value}), do: {:ok, value}
  defp singular_raw_value(_schema, %{type: :TYPE_BYTES}, {:bytes, value}), do: {:ok, value}

  defp singular_raw_value(_schema, %{type: :TYPE_ENUM} = field, {:int, value}) do
    {:ok, raw_enum_value(field, value)}
  end

  defp singular_raw_value(_schema, %{type: :TYPE_ENUM} = field, {:enum, _type, value}) do
    {:ok, raw_enum_value(field, value)}
  end

  defp singular_raw_value(schema, %{type: type} = field, value)
       when Field.message_type?(type) do
    raw_message_value(schema, field, value)
  end

  defp singular_raw_value(_schema, %{type: type}, value) do
    {:error, {:invalid_literal_field_value, type, value}}
  end

  defp raw_message_value(schema, %{type_name: type_name}, {:message, message_name, fields})
       when message_name == type_name do
    raw_fields_for_encode(schema, type_name, fields)
  end

  defp raw_message_value(
         schema,
         %{type_name: type_name} = field,
         {:message, message_name, fields}
       )
       when is_binary(message_name) do
    if Atom.to_string(type_name) == message_name do
      raw_fields_for_encode(schema, type_name, fields)
    else
      value = {:message, message_name, fields}

      case raw_well_known_value(schema, well_known_encode_destination(schema, field), value) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        :error -> {:error, {:message_type_mismatch, type_name, message_name}}
      end
    end
  end

  defp raw_message_value(schema, %{type_name: type_name} = field, value) do
    case raw_well_known_value(schema, well_known_encode_destination(schema, field), value) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :error -> {:error, {:invalid_message_value, type_name, value}}
    end
  end

  defp well_known_encode_destination(schema, %{type_name: type_name}) do
    case FieldReader.wrapper_field(schema, type_name) do
      nil -> well_known_encode_destination(type_name)
      field -> {:wrapper_field, field}
    end
  end

  defp well_known_encode_destination(:"google.protobuf.Timestamp"), do: :timestamp_field
  defp well_known_encode_destination(:"google.protobuf.Duration"), do: :duration_field
  defp well_known_encode_destination(:"google.protobuf.Value"), do: :google_value_field
  defp well_known_encode_destination(:"google.protobuf.ListValue"), do: :list_value_field
  defp well_known_encode_destination(:"google.protobuf.Struct"), do: :struct_field
  defp well_known_encode_destination(:"google.protobuf.Any"), do: :any_field
  defp well_known_encode_destination(type_name), do: {:ordinary_message_field, type_name}

  defp raw_well_known_value(schema, {:wrapper_field, field}, value) do
    with {:ok, value} <- singular_raw_value(schema, field, value), do: {:ok, %{value: value}}
  end

  defp raw_well_known_value(_schema, :timestamp_field, value), do: raw_timestamp(value)
  defp raw_well_known_value(_schema, :duration_field, value), do: raw_duration(value)

  defp raw_well_known_value(schema, :google_value_field, value),
    do: raw_google_value(schema, value)

  defp raw_well_known_value(schema, :list_value_field, value), do: raw_list_value(schema, value)
  defp raw_well_known_value(schema, :struct_field, value), do: raw_struct(schema, value)
  defp raw_well_known_value(schema, :any_field, value), do: raw_any(schema, value)
  defp raw_well_known_value(_schema, {:ordinary_message_field, _type_name}, _value), do: :error

  defp raw_timestamp({:timestamp, ns}) when is_integer(ns) do
    seconds = floor_div(ns, @nanos_per_second)
    {:ok, %{seconds: seconds, nanos: ns - seconds * @nanos_per_second}}
  end

  defp raw_timestamp(_value), do: :error

  defp raw_duration({:duration, ns}) when is_integer(ns) do
    {:ok, %{seconds: div(ns, @nanos_per_second), nanos: rem(ns, @nanos_per_second)}}
  end

  defp raw_duration(_value), do: :error

  defp raw_google_value(_schema, :null), do: {:ok, %{kind: {:null_value, :NULL_VALUE}}}
  defp raw_google_value(_schema, {:bool, value}), do: {:ok, %{kind: {:bool_value, value}}}

  defp raw_google_value(_schema, {:int, value})
       when value > @json_exact_integer_limit or value < -@json_exact_integer_limit do
    {:ok, %{kind: {:string_value, Integer.to_string(value)}}}
  end

  defp raw_google_value(_schema, {:int, value}), do: {:ok, %{kind: {:number_value, value}}}

  defp raw_google_value(_schema, {:uint, value}) when value > @json_exact_integer_limit do
    {:ok, %{kind: {:string_value, Integer.to_string(value)}}}
  end

  defp raw_google_value(_schema, {:uint, value}), do: {:ok, %{kind: {:number_value, value}}}
  defp raw_google_value(_schema, {:double, :nan}), do: {:ok, %{kind: {:string_value, "NaN"}}}

  defp raw_google_value(_schema, {:double, :infinity}),
    do: {:ok, %{kind: {:string_value, "Infinity"}}}

  defp raw_google_value(_schema, {:double, :negative_infinity}),
    do: {:ok, %{kind: {:string_value, "-Infinity"}}}

  defp raw_google_value(_schema, {:double, value}), do: {:ok, %{kind: {:number_value, value}}}
  defp raw_google_value(_schema, {:string, value}), do: {:ok, %{kind: {:string_value, value}}}

  defp raw_google_value(_schema, {:bytes, value}) when is_binary(value) do
    {:ok, %{kind: {:string_value, Base.encode64(value)}}}
  end

  defp raw_google_value(_schema, {:timestamp, _ns} = value) do
    with {:ok, value} <- Time.format_timestamp(value) do
      {:ok, %{kind: {:string_value, value}}}
    end
  end

  defp raw_google_value(_schema, {:duration, _ns} = value) do
    with {:ok, value} <- Time.format_duration(value) do
      {:ok, %{kind: {:string_value, value}}}
    end
  end

  defp raw_google_value(schema, {:list, _values} = value) do
    with {:ok, value} <- raw_list_value(schema, value) do
      {:ok, %{kind: {:list_value, value}}}
    end
  end

  defp raw_google_value(schema, {:map, _values} = value) do
    with {:ok, value} <- raw_struct(schema, value) do
      {:ok, %{kind: {:struct_value, value}}}
    end
  end

  defp raw_google_value(_schema, {:message, :"google.protobuf.Value", fields}), do: {:ok, fields}

  defp raw_google_value(_schema, {:message, :"google.protobuf.ListValue", fields}) do
    {:ok, %{kind: {:list_value, fields}}}
  end

  defp raw_google_value(_schema, {:message, :"google.protobuf.Struct", fields}) do
    {:ok, %{kind: {:struct_value, fields}}}
  end

  defp raw_google_value(_schema, {:message, :"google.protobuf.Empty", fields})
       when fields == %{} do
    {:ok, %{kind: {:struct_value, %{fields: %{}}}}}
  end

  defp raw_google_value(schema, {:message, :"google.protobuf.Timestamp", fields}) do
    with {:ok, value} <- well_known_decoded_value(schema, :"google.protobuf.Timestamp", fields) do
      raw_google_value(schema, value)
    end
  end

  defp raw_google_value(schema, {:message, :"google.protobuf.Duration", fields}) do
    with {:ok, value} <- well_known_decoded_value(schema, :"google.protobuf.Duration", fields) do
      raw_google_value(schema, value)
    end
  end

  defp raw_google_value(_schema, {:message, :"google.protobuf.FieldMask", fields})
       when is_map(fields) do
    with {:ok, paths} <- field_mask_paths(fields) do
      {:ok, %{kind: {:string_value, Enum.map_join(paths, ",", &camel_case/1)}}}
    end
  end

  defp raw_google_value(schema, {:message, message, fields}) when is_binary(message) do
    case message_atom(schema, message) do
      {:ok, message} -> raw_google_value(schema, {:message, message, fields})
      :error -> :error
    end
  end

  defp raw_google_value(schema, {:message, message, fields}) when is_atom(message) do
    case well_known_decoded_value(schema, message, fields) do
      {:ok, value} -> raw_google_value(schema, value)
      :error -> :error
      {:error, _reason} -> :error
    end
  end

  defp raw_google_value(_schema, _value), do: :error

  defp field_mask_paths(fields) do
    case Map.get(fields, :paths, Map.get(fields, "paths", [])) do
      paths when is_list(paths) ->
        map_while_ok(paths, fn
          {:string, path} when is_binary(path) -> {:ok, path}
          path when is_binary(path) -> {:ok, path}
          _other -> :error
        end)

      _other ->
        :error
    end
  end

  defp raw_list_value(schema, {:list, values}) do
    with {:ok, values} <- map_while_ok(values, &raw_google_value(schema, &1)) do
      {:ok, %{values: values}}
    end
  end

  defp raw_list_value(_schema, {:message, :"google.protobuf.ListValue", fields}),
    do: {:ok, fields}

  defp raw_list_value(_schema, _value), do: :error

  defp raw_struct(schema, {:map, values}) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:string, key} <- key,
           {:ok, value} <- raw_google_value(schema, value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _other -> {:halt, {:error, {:invalid_struct_key, key}}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, %{fields: fields}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_struct(_schema, {:message, :"google.protobuf.Struct", fields}), do: {:ok, fields}
  defp raw_struct(_schema, _value), do: :error

  defp raw_any(_schema, {:object, type_url, value}),
    do: {:ok, %{type_url: type_url, value: value}}

  defp raw_any(_schema, {:message, :"google.protobuf.Any", fields}), do: {:ok, fields}

  defp raw_any(_schema, :null), do: {:ok, %{}}

  defp raw_any(schema, {:bool, value}) do
    encode_any(schema, :"google.protobuf.BoolValue", %{value: value})
  end

  defp raw_any(schema, {:int, value}) do
    encode_any(schema, :"google.protobuf.Int64Value", %{value: value})
  end

  defp raw_any(schema, {:uint, value}) do
    encode_any(schema, :"google.protobuf.UInt64Value", %{value: value})
  end

  defp raw_any(schema, {:double, value}) do
    encode_any(schema, :"google.protobuf.DoubleValue", %{value: value})
  end

  defp raw_any(schema, {:string, value}) do
    encode_any(schema, :"google.protobuf.StringValue", %{value: value})
  end

  defp raw_any(schema, {:bytes, value}) do
    encode_any(schema, :"google.protobuf.BytesValue", %{value: value})
  end

  defp raw_any(schema, {:timestamp, _ns} = value) do
    with {:ok, fields} <- raw_timestamp(value) do
      encode_any(schema, :"google.protobuf.Timestamp", fields)
    end
  end

  defp raw_any(schema, {:duration, _ns} = value) do
    with {:ok, fields} <- raw_duration(value) do
      encode_any(schema, :"google.protobuf.Duration", fields)
    end
  end

  defp raw_any(schema, {:list, _values} = value) do
    with {:ok, fields} <- raw_list_value(schema, value) do
      encode_any(schema, :"google.protobuf.ListValue", fields)
    end
  end

  defp raw_any(schema, {:map, _values} = value) do
    with {:ok, fields} <- raw_struct(schema, value) do
      encode_any(schema, :"google.protobuf.Struct", fields)
    end
  end

  defp raw_any(schema, {:message, message, fields}) when is_atom(message) do
    encode_any(schema, message, fields)
  end

  defp raw_any(_schema, _value), do: :error

  defp encode_any(schema, message, fields) do
    with {:ok, fields} <- raw_fields_for_encode(schema, message, fields),
         {:ok, iodata} <- PB.encode(fields, schema, message) do
      {:ok,
       %{
         type_url: Any.type_url(message),
         value: IO.iodata_to_binary(iodata)
       }}
    end
  end

  defp well_known_decoded_value(schema, :"google.protobuf.Any", fields) do
    case {Map.get(fields, :type_url), Map.get(fields, :value)} do
      {type_url, value} when is_binary(type_url) and is_binary(value) ->
        decode_object_value(schema, type_url, value)

      {type_url, nil} when is_binary(type_url) ->
        decode_object_value(schema, type_url, "")

      _other ->
        {:error, "conversion error"}
    end
  end

  defp well_known_decoded_value(schema, :"google.protobuf.Value", fields) do
    google_value(schema, fields)
  end

  defp well_known_decoded_value(schema, :"google.protobuf.ListValue", fields) do
    list_value(schema, fields)
  end

  defp well_known_decoded_value(schema, :"google.protobuf.Struct", fields) do
    struct_value(schema, fields)
  end

  defp well_known_decoded_value(_schema, :"google.protobuf.Timestamp", fields) do
    with {:ok, seconds} <- raw_int(fields, :seconds, 0),
         {:ok, nanos} <- raw_int(fields, :nanos, 0),
         {:ok, value} <- Time.timestamp(seconds * @nanos_per_second + nanos) do
      {:ok, value}
    end
  end

  defp well_known_decoded_value(_schema, :"google.protobuf.Duration", fields) do
    with {:ok, seconds} <- raw_int(fields, :seconds, 0),
         {:ok, nanos} <- raw_int(fields, :nanos, 0),
         {:ok, value} <- Time.duration(seconds * @nanos_per_second + nanos) do
      {:ok, value}
    end
  end

  defp well_known_decoded_value(schema, message, fields) do
    case FieldReader.wrapper_field(schema, message) do
      nil -> :error
      field -> wrapper_value(schema, field, fields)
    end
  end

  defp wrapper_value(schema, field, fields) do
    case fetch_field(fields, :value) do
      {:ok, value} -> singular_field_value(schema, field, value)
      :error -> FieldReader.default_value(schema, field)
    end
  end

  defp google_value(_schema, %{kind: {:null_value, _value}}), do: {:ok, Value.null()}

  defp google_value(_schema, %{kind: {:number_value, value}}),
    do: {:ok, Value.double(value * 1.0)}

  defp google_value(_schema, %{kind: {:string_value, value}}), do: {:ok, Value.string(value)}
  defp google_value(_schema, %{kind: {:bool_value, value}}), do: {:ok, Value.bool(value)}

  defp google_value(schema, %{kind: {:struct_value, value}}) do
    struct_value(schema, value)
  end

  defp google_value(schema, %{kind: {:list_value, value}}) do
    list_value(schema, value)
  end

  defp google_value(_schema, %{}), do: {:ok, Value.null()}

  defp list_value(schema, fields) do
    with {:ok, values} <- map_while_ok(Map.get(fields, :values, []), &google_value(schema, &1)) do
      {:ok, Value.list(values)}
    end
  end

  defp struct_value(schema, fields) do
    fields
    |> Map.get(:fields, %{})
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, value} <- google_value(schema, value) do
        {:cont, {:ok, Map.put(acc, Value.string(key), value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Value.map(fields)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_object_value(schema, type_url, value) do
    type_name = WellKnownTypes.type_url_name(type_url)

    case Schema.resolve_message(schema, type_name) do
      {:ok, message} ->
        with {:ok, decoded} <- PB.decode(value, schema, message) do
          from_decoded(schema, message, decoded)
        end

      :error ->
        {:ok, Value.object(type_url, value)}
    end
  end

  defp enum_number(_field, value) when is_integer(value), do: {:ok, value}

  defp enum_number(%{enum: %{by_name: by_name}}, value) when is_atom(value) do
    case Map.fetch(by_name, value) do
      {:ok, number} -> {:ok, number}
      :error -> {:error, {:unknown_enum_value, value}}
    end
  end

  defp enum_number(_field, value), do: {:error, {:unknown_enum_value, value}}

  defp raw_enum_value(%{enum: %{by_number: by_number}}, value) do
    Map.get(by_number, value, value)
  end

  defp raw_enum_value(_field, value), do: value

  defp maybe_enum_field(_schema, field), do: field

  defp raw_int(fields, key, default) do
    case Map.get(fields, key, Map.get(fields, Atom.to_string(key), default)) do
      value when is_integer(value) -> {:ok, value}
      value -> {:error, "invalid #{key} field for time value: #{inspect(value)}"}
    end
  end

  defp fetch_field(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(fields, Atom.to_string(key))
    end
  end

  defp message_atom(schema, message) do
    case Schema.resolve_message(schema, message) do
      {:ok, message} -> {:ok, message}
      :error -> existing_atom(message)
    end
  end

  defp existing_atom("." <> message), do: existing_atom(message)

  defp existing_atom(message) do
    {:ok, String.to_existing_atom(message)}
  rescue
    ArgumentError -> :error
  end

  defp camel_case(name) do
    name
    |> :erlang.binary_to_list()
    |> camel_chars(false)
    |> :erlang.list_to_binary()
  end

  defp camel_chars([], _upper), do: []
  defp camel_chars([?_ | rest], _upper), do: camel_chars(rest, true)

  defp camel_chars([c | rest], true) when c >= ?a and c <= ?z,
    do: [c - 32 | camel_chars(rest, false)]

  defp camel_chars([c | rest], _upper), do: [c | camel_chars(rest, false)]

  defp floor_div(value, divisor) do
    quotient = div(value, divisor)
    remainder = rem(value, divisor)

    if remainder != 0 and remainder < 0 != divisor < 0 do
      quotient - 1
    else
      quotient
    end
  end

  defp map_while_ok(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
        :error -> {:halt, {:error, :error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end
end

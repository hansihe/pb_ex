defmodule PB.Runtime.Encoder do
  @moduledoc false

  alias PB.Runtime.Errors
  alias PB.Runtime.MessageView
  alias PB.Runtime.Options
  alias PB.Runtime.RequiredFields
  alias PB.Runtime.Scalar
  alias PB.Runtime.Schema, as: RuntimeSchema
  alias PB.Schema.Features
  alias PB.UnknownField
  alias PB.Wire

  @extension_key :__extensions__
  @message_name_key :__message_name__

  @typedoc "Public runtime encode options accepted by `PB.encode/4`."
  @type opts :: keyword()

  @typedoc "Normalized encode options shared by projection and field encoding."
  @type normalized_opts :: %{
          required(:unknown_fields) => :error | :ignore
        }

  @opts [unknown_fields: {[:error, :ignore], :error}]

  @typedoc "Current protobuf path used for encode errors."
  @type path :: [PB.Error.path_element()]

  @typedoc "Encoded protobuf message iodata."
  @type encoded :: iodata()

  @spec encode(PB.schema(), PB.Schema.Compiled.message_name(), term()) ::
          {:ok, encoded()} | {:error, PB.Error.t()}
  @spec encode(PB.schema(), PB.Schema.Compiled.message_name(), term(), opts()) ::
          {:ok, encoded()} | {:error, PB.Error.t()}
  def encode(schema, message_name, data, opts \\ []) do
    result =
      with {:ok, opts} <- normalize_opts(opts),
           {:ok, msg} <- RuntimeSchema.fetch_message(schema, message_name),
           {:ok, iodata} <- encode_message(schema, msg, message_name, data, [], opts) do
        {:ok, iodata}
      end

    Errors.normalize_result(result, :encode, message_name)
  end

  @spec encode!(PB.schema(), PB.Schema.Compiled.message_name(), term()) :: encoded()
  @spec encode!(PB.schema(), PB.Schema.Compiled.message_name(), term(), opts()) ::
          encoded()
  def encode!(schema, message_name, data, opts \\ []) do
    case encode(schema, message_name, data, opts) do
      {:ok, iodata} ->
        iodata

      {:error, %{__exception__: true} = error} ->
        raise error
    end
  end

  @spec normalize_opts(term()) :: {:ok, normalized_opts()} | {:error, term()}
  defp normalize_opts(opts), do: Options.validate(opts, @opts)

  defp oneof_member_field?(msg, field) do
    Map.has_key?(msg.oneof_field_names, field.name)
  end

  defp validate_required_fields(msg, data, path) do
    case RequiredFields.missing_path(msg.required_fields, data, path) do
      nil -> :ok
      missing -> {:error, {:missing_required, missing}}
    end
  end

  defp invalid_value(path, expected, value) do
    {:error, {:invalid_value, path, expected, Errors.type_of(value)}}
  end

  defp map_field?(schema, field) do
    Features.map?(field) and
      match?(%{map_entry: true}, RuntimeSchema.map_entry_message(schema, field))
  end

  defp encode_message(schema, msg, msg_name, nil, path, opts) do
    # A nil singular message is absent — unless the message has an adapter, for
    # which nil is a native value the adapter interprets (a JSON `null` `Value`,
    # a wrapper default, ...). Route those through the adapter; skip otherwise.
    if message_adapter?(msg) do
      do_encode_message(schema, msg, msg_name, nil, path, opts)
    else
      {:error, :absent}
    end
  end

  defp encode_message(schema, msg, msg_name, data, path, opts) do
    do_encode_message(schema, msg, msg_name, data, path, opts)
  end

  defp message_adapter?(%{projection: %{adapter: adapter}}), do: not is_nil(adapter)
  defp message_adapter?(_msg), do: false

  defp do_encode_message(schema, msg, msg_name, data, path, opts) do
    with {:ok, data} <- MessageView.to_proto_fields(schema, msg_name, msg, data, path),
         :ok <- validate_message_name(data, msg_name, path),
         {:ok, fields} <-
           Enum.reduce_while(data, {:ok, []}, fn {key, value}, {:ok, acc} ->
             encode_message_field(schema, msg, msg_name, key, value, path, acc, opts)
           end),
         {:ok, extensions} <-
           encode_extensions(
             schema,
             msg,
             msg_name,
             Map.get(data, @extension_key, %{}),
             path,
             opts
           ),
         {:ok, unknowns} <- UnknownField.encode_all(Map.get(data, UnknownField.key(), [])),
         :ok <- validate_required_fields(msg, data, path) do
      # Field order on the wire is unconstrained, but we emit in ascending
      # field-number order so output is deterministic and byte-assertable in
      # tests. `data` iterates in arbitrary map order, so we sort here; the cost
      # is O(f log f) over a message's handful of fields (unknown fields, which
      # we don't order, stay trailing).
      fields =
        (fields ++ extensions)
        |> Enum.sort_by(fn {num, _} -> num end)
        |> Enum.flat_map(fn {_, encoded} -> encoded end)

      {:ok, [fields | unknowns]}
    end
  end

  defp encode_message_field(schema, msg, msg_name, key, value, path, acc, opts) do
    cond do
      key == UnknownField.key() ->
        {:cont, {:ok, acc}}

      key == @extension_key ->
        {:cont, {:ok, acc}}

      key == @message_name_key ->
        {:cont, {:ok, acc}}

      field = msg.fields_by_name[key] ->
        field_path = path ++ [key]

        cond do
          oneof_member_field?(msg, field) ->
            {:halt, {:error, {:invalid_oneof, field_path, :oneof_member_must_use_wrapper}}}

          skip_encode_field?(schema, field, value, field_path) ->
            {:cont, {:ok, acc}}

          true ->
            continue_encoding(
              encode_field(schema, field, value, field_path, opts),
              field.number,
              acc
            )
        end

      oneof = find_oneof(msg, key) ->
        encode_oneof_field(schema, msg, oneof, key, value, path, acc, opts)

      opts.unknown_fields == :ignore ->
        {:cont, {:ok, acc}}

      true ->
        {:halt, {:error, {:unknown_field, msg_name, path ++ [key]}}}
    end
  end

  defp encode_oneof_field(schema, msg, oneof, key, value, path, acc, opts) do
    case oneof_encode_value(msg, oneof, key, value, path) do
      {:ok, {fname, inner}} ->
        field = Map.fetch!(msg.fields_by_name, fname)

        continue_encoding(
          encode_field(schema, field, inner, path ++ [key, fname], opts),
          field.number,
          acc
        )

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp oneof_encode_value(msg, oneof, key, {fname, inner}, path) when is_atom(fname) do
    cond do
      fname not in oneof.fields ->
        {:error, {:invalid_oneof, path ++ [key], {:unknown_member, fname}}}

      Map.has_key?(msg.fields_by_name, fname) ->
        {:ok, {fname, inner}}

      true ->
        {:error, {:invalid_oneof, path ++ [key], {:unknown_member, fname}}}
    end
  end

  defp oneof_encode_value(msg, oneof, key, %module{} = value, path) do
    if identity_oneof?(msg, oneof) do
      case Map.fetch(oneof.term_by_struct, module) do
        {:ok, fname} ->
          {:ok, {fname, value}}

        :error ->
          {:error, {:invalid_oneof, path ++ [key], {:unknown_member_struct, module}}}
      end
    else
      {:error, {:invalid_oneof, path ++ [key], :expected_member_tuple}}
    end
  end

  defp oneof_encode_value(msg, oneof, key, _value, path) do
    if identity_oneof?(msg, oneof) do
      {:error, {:invalid_oneof, path ++ [key], :expected_member_struct}}
    else
      {:error, {:invalid_oneof, path ++ [key], :expected_member_tuple}}
    end
  end

  defp identity_oneof?(%{projection: %{oneofs: oneofs}}, %{name: name}) do
    Map.get(oneofs, name) == :identity
  end

  defp identity_oneof?(_msg, _oneof), do: false

  defp encode_extensions(_schema, _msg, _msg_name, extensions, _path, _opts)
       when extensions == %{},
       do: {:ok, []}

  defp encode_extensions(schema, msg, msg_name, extensions, path, opts)
       when is_map(extensions) and not is_struct(extensions) do
    Enum.reduce_while(extensions, {:ok, []}, fn {name, value}, {:ok, acc} ->
      case Map.fetch(msg.extensions_by_name, name) do
        {:ok, field} ->
          field_path = path ++ [@extension_key, name]

          if skip_encode_field?(schema, field, value, field_path) do
            {:cont, {:ok, acc}}
          else
            continue_encoding(
              encode_field(schema, field, value, field_path, opts),
              field.number,
              acc
            )
          end

        :error ->
          {:halt, {:error, {:unknown_field, msg_name, path ++ [@extension_key, name]}}}
      end
    end)
  end

  defp encode_extensions(_schema, _msg, _msg_name, value, path, _opts) do
    invalid_value(path ++ [@extension_key], :map, value)
  end

  defp validate_message_name(%{@message_name_key => expected}, expected, _path), do: :ok

  defp validate_message_name(%{@message_name_key => actual}, expected, path) do
    {:error, {:message_name_mismatch, path ++ [@message_name_key], expected, actual}}
  end

  defp validate_message_name(_data, _expected, _path), do: :ok

  defp continue_encoding({:error, :absent}, _number, acc), do: {:cont, {:ok, acc}}

  defp continue_encoding({:ok, encoded}, number, acc),
    do: {:cont, {:ok, [{number, encoded} | acc]}}

  defp continue_encoding({:error, _reason} = error, _number, _acc), do: {:halt, error}

  defp find_oneof(%{oneofs_by_name: oneofs_by_name}, name) do
    Map.get(oneofs_by_name, name)
  end

  defp skip_encode_field?(_schema, %{type: :TYPE_MESSAGE}, _value, _path), do: false

  defp skip_encode_field?(_schema, field, value, path) do
    with {:ok, value} <- Scalar.normalize_encode_value(field, value, path) do
      Scalar.implicit_presence?(field) and Scalar.default_value?(field, value)
    else
      {:error, _reason} -> false
    end
  end

  defp encode_field(schema, field, value, path, opts) do
    cond do
      map_field?(schema, field) ->
        if is_map(value) and not is_struct(value),
          do: encode_map_field(schema, field, value, path, opts),
          else: invalid_value(path, :map, value)

      Features.packed?(field) ->
        encode_packed(schema, field, value, path)

      Features.repeated?(field) and is_list(value) ->
        encode_repeated(schema, field, value, path, opts)

      Features.repeated?(field) ->
        invalid_value(path, :list, value)

      true ->
        encode_singular(schema, field, value, path, opts)
    end
  end

  defp encode_map_field(schema, field, entries, path, opts) do
    with {:ok, encoded} <-
           Enum.reduce_while(entries, {:ok, []}, fn {key, value}, {:ok, acc} ->
             entry = %{key: key, value: value}

             case encode_singular(schema, field, entry, path ++ [{:key, key}], opts) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, :absent} -> {:cont, {:ok, acc}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      {:ok, Enum.reverse(encoded)}
    end
  end

  defp encode_repeated(schema, field, values, path, opts) do
    with {:ok, encoded} <-
           values
           |> Enum.with_index()
           |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
             case encode_singular(schema, field, value, path ++ [{:index, index}], opts) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, :absent} -> {:cont, {:ok, acc}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      {:ok, Enum.reverse(encoded)}
    end
  end

  defp encode_singular(schema, field, value, path, opts) do
    with {:ok, encoded} <- encode_typed_value(schema, field, value, path, opts) do
      {:ok, [field.tag | encoded]}
    end
  end

  defp encode_packed(_schema, _field, [], _path), do: {:ok, []}

  defp encode_packed(schema, field, values, path) when is_list(values) do
    with {:ok, encoded} <-
           values
           |> Enum.with_index()
           |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
             case encode_scalar_value(schema, field, value, path ++ [{:index, index}]) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      encoded = Enum.reverse(encoded)
      {:ok, [field.packed_tag, Wire.encode_varint(IO.iodata_length(encoded)) | encoded]}
    end
  end

  defp encode_packed(_schema, _field, values, path), do: invalid_value(path, :list, values)

  defp encode_typed_value(schema, field, value, path, opts) do
    case field.type do
      :TYPE_MESSAGE ->
        # `encode_message` applies the message's own adapter/representation one
        # level (via `MessageView`) and recurses its children, so a referenced
        # adaptered message composes with no field-level special case here.
        inner =
          with {:ok, msg} <- RuntimeSchema.fetch_message(schema, field.type_name) do
            encode_message(schema, msg, field.type_name, value, path, opts)
          else
            {:error, reason} ->
              {:error, PB.Error.prepend_path(Errors.to_error(reason), path)}
          end

        with {:ok, inner} <- inner do
          {:ok, Wire.encode_message_value(field.number, field.encoding, inner)}
        end

      _ ->
        encode_scalar_value(schema, field, value, path)
    end
  end

  defp encode_scalar_value(_schema, field, value, path), do: Scalar.encode(field, value, path)
end

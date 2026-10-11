defmodule PB.JSON.Encoder do
  @moduledoc false

  # ProtoJSON encode pipeline. Four layers:
  #
  #   encode_message    (axis 1: WKT vs regular, by message name)
  #     encode_regular  (iterates declared fields)
  #       encode_field  (axis 2: map / repeated / singular)
  #         encode_scalar (axis 3: per protobuf type;
  #                        TYPE_MESSAGE -> recurse to encode_message)
  #
  # WKT dispatch happens once, in encode_message. Nothing else looks at
  # the WKT table.

  alias PB.JSON.{Errors, Scalars, WKT}
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.RequiredFields
  alias PB.Runtime.Scalar
  alias PB.Schema.Features


  @doc false
  def run(data, schema, name, opts) do
    Errors.guard(:json_encode, name, fn ->
      encode_message(name, data, schema, opts)
    end)
  end

  # Callbacks bag for Any's back-edge into the pipeline.
  defp callbacks, do: %{encode_message: &encode_message/4, decode_message: nil}

  # ── axis 1 ───────────────────────────────────────────────────────────
  defp encode_message(name, data, schema, opts) do
    case WKT.lookup(name) do
      %{enc: :wrapper} ->
        encode_wrapper(name, data, schema, opts)

      %{enc: _} = entry ->
        WKT.encode(entry, data, schema, opts, callbacks())

      _ ->
        case schema.messages[name] do
          nil -> Errors.raise!(:unknown_message, name, details: %{type_name: name})
          msg -> encode_regular(msg, data, schema, opts)
        end
    end
  end

  # ── wrappers ─────────────────────────────────────────────────────────
  # A wrapper prints as its `value` field, which an absent value leaves at
  # its default.
  defp encode_wrapper(name, data, schema, opts) when is_map(data) do
    field = schema.messages[name].fields_by_name.value

    value =
      case Map.fetch(data, :value) do
        {:ok, value} when value != nil -> value
        _unset -> field |> Scalar.default_value() |> elem(1)
      end

    encode_scalar(field, value, schema, opts)
  end

  defp encode_wrapper(_name, data, _schema, _opts) do
    Errors.raise!(:invalid_value, "expected wrapper value", details: %{got: data})
  end

  # ── regular message ──────────────────────────────────────────────────
  defp encode_regular(msg, data, schema, opts) when is_map(data) do
    check_required!(msg, data)

    encoded =
      Enum.reduce(data, %{}, fn {key, value}, acc ->
        cond do
          field = msg.fields_by_name[key] ->
            maybe_put(acc, schema, msg, field, value, opts)

          oneof = find_oneof(msg.oneofs, key) ->
            encode_oneof_wrapper(acc, schema, msg, oneof, value, opts)

          true ->
            acc
        end
      end)

    if opts[:emit_defaults], do: fill_defaults(encoded, schema, msg, opts), else: encoded
  end

  defp encode_regular(_msg, data, _schema, _opts) do
    Errors.raise!(:invalid_value, "expected message data map",
      details: %{expected: :map, got: data}
    )
  end

  defp encode_oneof_wrapper(acc, _schema, _msg, _oneof, nil, _opts), do: acc

  defp encode_oneof_wrapper(acc, schema, msg, _oneof, {fname, inner}, opts) do
    case msg.fields_by_name[fname] do
      nil ->
        acc

      field ->
        # Oneof members always have presence; emit even if value matches a default.
        Map.put(acc, json_key(field, opts), encode_field(field, inner, schema, opts))
    end
  end

  defp maybe_put(acc, schema, msg, field, value, opts) do
    if should_emit?(schema, msg, field, value, opts) do
      Map.put(acc, json_key(field, opts), encode_field(field, value, schema, opts))
    else
      acc
    end
  end

  defp should_emit?(_schema, _msg, _field, nil, _opts), do: false

  defp should_emit?(_schema, _msg, field, value, opts) do
    cond do
      opts[:emit_defaults] -> true
      has_presence?(field) -> true
      Features.repeated?(field) and value in [[], %{}] -> false
      Features.repeated?(field) -> true
      Scalar.default_value?(field, value) -> false
      true -> true
    end
  end

  # ── axis 2 ───────────────────────────────────────────────────────────
  defp encode_field(field, value, schema, opts) do
    cond do
      map_field?(schema, field) ->
        encode_map(schema, field, value, opts)

      Features.repeated?(field) ->
        Enum.map(value, &encode_scalar(field, &1, schema, opts))

      true ->
        encode_scalar(field, value, schema, opts)
    end
  end

  defp encode_map(schema, field, value, opts) when is_map(value) do
    ref = schema.messages[field.type_name]
    value_field = ref.fields_by_name[:value]

    Map.new(value, fn {k, v} ->
      {Scalars.map_key_to_string(k), encode_scalar(value_field, v, schema, opts)}
    end)
  end

  # ── axis 3 ───────────────────────────────────────────────────────────
  defp encode_scalar(%{type: :TYPE_MESSAGE} = field, value, schema, opts),
    do: encode_message(field.type_name, value, schema, opts)

  # Scalars are checked by the same rules as `PB.encode/4` before printing.
  defp encode_scalar(field, value, schema, opts) do
    case Scalar.validate_encode(field, value, []) do
      :ok -> encode_valid_scalar(field, value, schema, opts)
      {:error, reason} -> raise RuntimeErrors.to_error(reason)
    end
  end

  defp encode_valid_scalar(field, value, schema, opts) do
    case field.type do
      :TYPE_ENUM -> Scalars.encode_enum(schema, field, value, opts)
      :TYPE_STRING -> value
      :TYPE_BYTES -> Base.encode64(value)
      :TYPE_BOOL -> value == true
      :TYPE_DOUBLE -> Scalars.encode_float(value)
      :TYPE_FLOAT -> Scalars.encode_float(value)
      :TYPE_INT64 -> Integer.to_string(value)
      :TYPE_UINT64 -> Integer.to_string(value)
      :TYPE_FIXED64 -> Integer.to_string(value)
      :TYPE_SFIXED64 -> Integer.to_string(value)
      :TYPE_SINT64 -> Integer.to_string(value)
      :TYPE_INT32 -> value
      :TYPE_UINT32 -> value
      :TYPE_FIXED32 -> value
      :TYPE_SFIXED32 -> value
      :TYPE_SINT32 -> value
    end
  end

  # ── default-filling ──────────────────────────────────────────────────
  defp fill_defaults(encoded, schema, msg, opts) do
    Enum.reduce(msg.fields_by_name, encoded, fn {_fname, field}, acc ->
      key = json_key(field, opts)

      cond do
        Map.has_key?(acc, key) -> acc
        in_oneof?(field) -> acc
        has_presence?(field) -> acc
        true -> Map.put(acc, key, default_json_value(schema, field, opts))
      end
    end)
  end

  defp default_json_value(schema, field, opts) do
    cond do
      map_field?(schema, field) -> %{}
      Features.repeated?(field) -> []
      true -> default_scalar_json(schema, field, opts)
    end
  end

  defp default_scalar_json(schema, field, opts) do
    {:ok, default} = Scalar.default_value(field)
    encode_valid_scalar(field, default, schema, opts)
  end

  # ── helpers ──────────────────────────────────────────────────────────
  defp find_oneof(oneofs, name) do
    Enum.find_value(oneofs, fn {_i, o} -> if o.name == name, do: o end)
  end

  defp map_field?(schema, field) do
    Features.map?(field) and field.type == :TYPE_MESSAGE and
      match?(%{map_entry: true}, schema.messages[field.type_name])
  end

  defp in_oneof?(field), do: Features.oneof?(field)
  defp has_presence?(field), do: Features.has_presence?(field)

  defp check_required!(msg, data) do
    case RequiredFields.missing_path(msg.required_fields, data) do
      nil -> :ok
      path -> Errors.raise!(:missing_required, nil, path: path)
    end
  end

  defp json_key(field, opts) do
    if opts[:use_proto_names] do
      Atom.to_string(field.name)
    else
      case Map.get(field, :json_name) do
        nil -> Scalars.camel_case(Atom.to_string(field.name))
        v when is_binary(v) -> v
      end
    end
  end
end

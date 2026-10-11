defmodule PB.JSON.Decoder do
  @moduledoc false

  # ProtoJSON decode pipeline. Mirror of Encoder.
  #
  #   decode_message    (axis 1: WKT vs regular, by message name)
  #     decode_regular  (consumes the JSON object)
  #       decode_field  (axis 2: map / repeated / singular)
  #         decode_scalar (axis 3: per protobuf type;
  #                        TYPE_MESSAGE -> recurse to decode_message)
  #
  # The `:skip` sentinel is contained inside `Scalars.decode_enum`.
  # `decode_scalar` returns a value or raises -- no sentinel in its
  # contract. The three places that need `:skip` honor it locally:
  #
  #   1. singular-field bind: leave the field absent
  #   2. repeated-element filter: drop the element
  #   3. map-entry filter: drop the entry

  alias PB.JSON.{Depth, Errors, Scalars, WKT}
  alias PB.Runtime.{Oneofs, RequiredFields, Scalar}
  alias PB.Schema.Features

  @doc false
  def run(json, schema, name, opts) do
    Errors.guard(:json_decode, name, fn ->
      decode_message(name, json, schema, opts)
    end)
  end

  defp callbacks(depth) do
    %{
      encode_message: nil,
      decode_message: fn name, json, schema, opts ->
        decode_message(name, json, schema, opts, Depth.descend!(depth))
      end,
      descend: &Depth.descend!/1
    }
  end

  # ── axis 1 ───────────────────────────────────────────────────────────
  defp decode_message(name, json, schema, opts), do: decode_message(name, json, schema, opts, 0)

  defp decode_message(name, json, schema, opts, depth) do
    case WKT.lookup(name) do
      %{dec: _} = entry ->
        WKT.decode(entry, json, schema, opts, callbacks(depth), depth)

      _ ->
        case schema.messages[name] do
          nil -> Errors.raise!(:unknown_message, name, details: %{type_name: name})
          msg -> decode_regular(msg, json, schema, opts, depth)
        end
    end
  end

  # ── regular message ──────────────────────────────────────────────────
  defp decode_regular(msg, json, schema, opts, depth) when is_map(json) do
    lookup = field_lookup(msg)

    {fields, _oneof_seen, _field_seen} =
      Enum.reduce(json, {%{}, MapSet.new(), MapSet.new()}, fn {raw_key, value},
                                                              {acc, oneof_seen, field_seen} ->
        key = Scalars.stringify_key(raw_key)

        case Map.get(lookup, key) do
          nil ->
            if opts[:ignore_unknown] do
              {acc, oneof_seen, field_seen}
            else
              Errors.raise!(:unknown_field, key, path: [key])
            end

          field ->
            # ProtoJSON rejects duplicates regardless of whether the
            # duplicate spellings differ in casing (e.g.
            # `optional_nested_message` and `optionalNestedMessage` both
            # naming field `optional_nested_message`).
            if MapSet.member?(field_seen, field.name) do
              Errors.raise!(:duplicate_field, key,
                path: [key],
                details: %{field: field.name}
              )
            end

            {acc, oneof_seen} = decode_one(schema, field, value, acc, oneof_seen, opts, depth)
            {acc, oneof_seen, MapSet.put(field_seen, field.name)}
        end
      end)

    check_required!(msg, fields)
    Oneofs.wrap(fields, msg)
  end

  defp decode_regular(_msg, json, _schema, _opts, _depth) do
    Errors.raise!(:malformed_json, "expected JSON object",
      details: %{expected: :object, got: json}
    )
  end

  # ── singular-field handling for one JSON entry ───────────────────────
  # JSON null on a singular field of a nullable-WKT type binds the field
  # to that type's null sentinel; for any other type, and for repeated
  # /map fields whose entire JSON value is null, the field is left
  # absent.
  defp decode_one(_schema, field, nil, acc, seen, _opts, _depth) do
    cond do
      Features.repeated?(field) or Features.map?(field) ->
        {acc, seen}

      binding = WKT.null_binding(Map.get(field, :type_name)) ->
        {:bind, decoded} = binding
        seen = check_oneof_dup!(field, seen)
        {Map.put(acc, field.name, decoded), seen}

      true ->
        {acc, seen}
    end
  end

  defp decode_one(schema, field, value, acc, seen, opts, depth) do
    case decode_field(field, value, schema, opts, depth) do
      :skip ->
        # Singular unknown enum with `ignore_unknown` -- leave the
        # field absent and don't claim the oneof slot.
        {acc, seen}

      decoded ->
        seen = check_oneof_dup!(field, seen)
        {Map.put(acc, field.name, decoded), seen}
    end
  end

  # ── axis 2 ───────────────────────────────────────────────────────────
  # Returns a value, or `:skip` (only for singular unknown enum).
  defp decode_field(field, value, schema, opts, depth) do
    cond do
      map_field?(schema, field) ->
        decode_map(field, value, schema, opts, depth)

      Features.repeated?(field) ->
        unless is_list(value) do
          Errors.raise!(:invalid_value, "expected JSON array",
            details: %{expected: :array, got: value}
          )
        end

        Enum.flat_map(value, fn v ->
          case decode_element(field, v, schema, opts, depth) do
            :skip -> []
            decoded -> [decoded]
          end
        end)

      true ->
        decode_element(field, value, schema, opts, depth)
    end
  end

  defp decode_map(field, value, schema, opts, depth) when is_map(value) do
    ref = schema.messages[field.type_name]
    key_field = ref.fields_by_name[:key]
    value_field = ref.fields_by_name[:value]

    value
    |> Enum.flat_map(fn {k, v} ->
      case decode_element(value_field, v, schema, opts, depth) do
        :skip -> []
        decoded -> [{Scalars.parse_map_key(key_field, Scalars.stringify_key(k)), decoded}]
      end
    end)
    |> Map.new()
  end

  defp decode_map(_field, value, _schema, _opts, _depth) do
    Errors.raise!(:invalid_value, "expected JSON object for map",
      details: %{expected: :object, got: value}
    )
  end

  # Used for singular fields and for repeated/map elements alike. JSON
  # null inside a repeated/map element binds a WKT null sentinel or
  # raises (same rule as today).
  defp decode_element(field, nil, _schema, _opts, _depth) do
    case WKT.null_binding(Map.get(field, :type_name)) do
      {:bind, decoded} -> decoded
      nil -> Errors.raise!(:malformed_json, "null is not allowed inside arrays or map values")
    end
  end

  defp decode_element(field, value, schema, opts, depth) do
    case field.type do
      :TYPE_ENUM -> Scalars.decode_enum(schema, field, value, opts)
      _ -> decode_scalar(field, value, schema, opts, depth)
    end
  end

  # ── axis 3 ───────────────────────────────────────────────────────────
  defp decode_scalar(field, value, schema, opts, depth) do
    case field.type do
      :TYPE_MESSAGE ->
        # Note: WKT decoders accept non-object JSON (Value, ListValue,
        # wrappers, FieldMask, Timestamp, Duration). Only regular
        # messages need the is_map check, which lives in decode_regular.
        decode_message(field.type_name, value, schema, opts, Depth.descend!(depth))

      :TYPE_STRING ->
        unless is_binary(value) do
          Errors.raise!(:invalid_value, "expected string",
            details: %{expected: :string, got: value}
          )
        end

        value

      :TYPE_BYTES ->
        unless is_binary(value) do
          Errors.raise!(:invalid_value, "expected base64 string",
            details: %{expected: :base64_string, got: value}
          )
        end

        Scalars.decode_base64!(value)

      :TYPE_BOOL ->
        case value do
          true ->
            true

          false ->
            false

          _ ->
            Errors.raise!(:invalid_value, "expected boolean",
              details: %{expected: :boolean, got: value}
            )
        end

      t when t in [:TYPE_DOUBLE, :TYPE_FLOAT] ->
        Scalars.decode_float!(value, t)

      integer_type ->
        {min, max} = Scalar.integer_range(integer_type)
        Scalars.decode_int!(value, min, max)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────
  defp map_field?(schema, field) do
    Features.map?(field) and field.type == :TYPE_MESSAGE and
      match?(%{map_entry: true}, schema.messages[field.type_name])
  end

  defp in_oneof?(field), do: Features.oneof?(field)

  defp check_oneof_dup!(field, seen) do
    if in_oneof?(field) do
      idx = field.oneof_index

      if MapSet.member?(seen, idx) do
        Errors.raise!(:invalid_oneof, "multiple values for the same oneof")
      end

      MapSet.put(seen, idx)
    else
      seen
    end
  end

  defp check_required!(msg, fields) do
    case RequiredFields.missing_path(msg.required_fields, fields) do
      nil -> :ok
      path -> Errors.raise!(:missing_required, nil, path: path)
    end
  end

  defp field_lookup(msg) do
    Enum.reduce(msg.fields_by_name, %{}, fn {fname, field}, acc ->
      proto = Atom.to_string(fname)
      camel = Map.get(field, :json_name) || Scalars.camel_case(proto)

      acc
      |> Map.put(proto, field)
      |> Map.put(camel, field)
    end)
  end
end

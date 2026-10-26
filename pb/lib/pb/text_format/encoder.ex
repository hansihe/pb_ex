defmodule PB.TextFormat.Encoder do
  @moduledoc false

  # Turns a canonical proto-map into PB.TextFormat.Layout entries: what to
  # print and in which order. The input is the shape a wire decode produces,
  # so values are already validated, enum numbers with a name are names,
  # implicit-presence defaults are omitted and floats carry their field's
  # precision. PB.TextFormat gets there by encoding and decoding the caller's
  # value, which applies exactly the rules of `PB.encode/4`.
  #
  # Output follows the C++ printer:
  #
  #   * fields and extensions in field-number order (a oneof's member at its
  #     own number), then unknown fields as stored
  #   * repeated fields once per element; with `short_repeated`, numeric,
  #     boolean and enum fields as one `[a, b]` list instead
  #   * map entries sorted by key, each printing both key and value
  #   * group-like fields by their type name, extensions as `[full.name]`
  #   * a google.protobuf.Any expanded as `[type_url] { ... }` when its type
  #     URL has a prefix the parsers resolve and its bytes decode; otherwise
  #     its raw `type_url` and `value`
  #   * unknown fields by number: varints in decimal, fixed32/fixed64 in hex,
  #     length-delimited values as a nested message when they parse as one
  #     (to a depth of 10, like C++) and as a bytes literal otherwise

  alias PB.TextFormat.{FieldNames, Scalars}
  alias PB.UnknownField
  alias PB.WellKnownTypes.Any
  alias PB.Wire

  import Bitwise

  @any :"google.protobuf.Any"
  @extension_key :__extensions__
  @unknown_key :__unknown_fields__
  @unknown_message_depth 10

  @short_repeated_types [
    :TYPE_DOUBLE,
    :TYPE_FLOAT,
    :TYPE_INT32,
    :TYPE_INT64,
    :TYPE_UINT32,
    :TYPE_UINT64,
    :TYPE_SINT32,
    :TYPE_SINT64,
    :TYPE_FIXED32,
    :TYPE_FIXED64,
    :TYPE_SFIXED32,
    :TYPE_SFIXED64,
    :TYPE_BOOL,
    :TYPE_ENUM
  ]

  @spec entries(atom, map, map, keyword) :: [PB.TextFormat.Layout.entry()]
  def entries(name, fields, schema, opts), do: message_entries(name, fields, schema, opts)

  # ── messages ─────────────────────────────────────────────────────────

  defp message_entries(@any, fields, schema, opts) do
    case expand_any(fields, schema) do
      {:ok, url, name, packed} ->
        [{:message, "[#{url}]", message_entries(name, packed, schema, opts)}]

      :error ->
        regular_entries(@any, fields, schema, opts)
    end
  end

  defp message_entries(name, fields, schema, opts),
    do: regular_entries(name, fields, schema, opts)

  defp regular_entries(name, fields, schema, opts) do
    msg = schema.messages[name]

    known =
      fields
      |> Enum.flat_map(&present_fields(&1, msg))
      |> Enum.sort_by(fn {field, _value} -> field.number end)
      |> Enum.flat_map(fn {field, value} -> field_entries(name, field, value, schema, opts) end)

    if opts.print_unknown_fields,
      do: known ++ unknown_entries(Map.get(fields, @unknown_key, []), @unknown_message_depth),
      else: known
  end

  defp present_fields({@unknown_key, _unknowns}, _msg), do: []

  defp present_fields({@extension_key, extensions}, msg),
    do:
      Enum.map(extensions, fn {name, value} ->
        {Map.fetch!(msg.extensions_by_name, name), value}
      end)

  defp present_fields({key, value}, msg) do
    case Map.fetch(msg.oneofs_by_name, key) do
      {:ok, _oneof} ->
        {member, member_value} = value
        [{Map.fetch!(msg.fields_by_name, member), member_value}]

      :error ->
        [{Map.fetch!(msg.fields_by_name, key), value}]
    end
  end

  # A packed Any is expanded only when the result parses back: the prefix
  # must be one the parsers accept and the bytes must decode as the type.
  defp expand_any(%{type_url: url} = fields, schema) when map_size(fields) <= 2 do
    with {:ok, prefix, type} <- Any.split_type_url(url),
         true <- prefix in Any.google_prefixes(),
         name when is_atom(name) <- existing_atom(type),
         true <- Map.has_key?(schema.messages, name),
         {:ok, packed} <- Any.unpack(Map.get(fields, :value, ""), schema, name) do
      {:ok, url, name, packed}
    else
      _ -> :error
    end
  end

  defp expand_any(_fields, _schema), do: :error

  # ── fields ───────────────────────────────────────────────────────────

  defp field_entries(message_name, field, value, schema, opts) do
    name = FieldNames.text_name(message_name, field)

    cond do
      field.cardinality == :map ->
        entry_fields = schema.messages[field.type_name].fields_by_name

        value
        |> Enum.sort()
        |> Enum.map(fn {key, entry_value} ->
          {:message, name,
           [
             value_entry("key", entry_fields.key, key, schema, opts),
             value_entry("value", entry_fields.value, entry_value, schema, opts)
           ]}
        end)

      field.cardinality == :repeated ->
        if opts.short_repeated and field.type in @short_repeated_types and
             value != [] do
          [{:list, name, Enum.map(value, &Scalars.format(field, &1))}]
        else
          Enum.map(value, &value_entry(name, field, &1, schema, opts))
        end

      true ->
        [value_entry(name, field, value, schema, opts)]
    end
  end

  defp value_entry(name, %{type: :TYPE_MESSAGE} = field, value, schema, opts),
    do: {:message, name, message_entries(field.type_name, value, schema, opts)}

  defp value_entry(name, field, value, _schema, _opts),
    do: {:scalar, name, Scalars.format(field, value)}

  # ── unknown fields ───────────────────────────────────────────────────

  defp unknown_entries(unknowns, depth), do: Enum.map(unknowns, &unknown_entry(&1, depth))

  defp unknown_entry(%UnknownField{number: number, wire_type: wire_type, raw: raw}, depth) do
    {:ok, _tag, rest} = Wire.decode_tag(raw)
    name = Integer.to_string(number)

    case wire_type do
      0 ->
        {:ok, value, _rest} = Wire.decode_varint(rest)
        {:scalar, name, Integer.to_string(value)}

      1 ->
        <<value::little-64>> = rest
        {:scalar, name, hex(value, 16)}

      5 ->
        <<value::little-32>> = rest
        {:scalar, name, hex(value, 8)}

      2 ->
        {:ok, bytes, _rest} = Wire.read_wire(2, rest)

        case depth > 0 and bytes != "" and parse_unknowns(bytes) do
          {:ok, nested} -> {:message, name, unknown_entries(nested, depth - 1)}
          _ -> {:scalar, name, Scalars.quote_bytes(bytes)}
        end

      3 ->
        {:ok, body, _raw, _rest} = Wire.read_message_field(number, :delimited, rest)
        {:ok, nested} = parse_unknowns(body)
        {:message, name, unknown_entries(nested, depth - 1)}
    end
  end

  # Reads bytes as a sequence of unknown fields, as C++ does to decide whether
  # a length-delimited value is an embedded message.
  defp parse_unknowns(bytes, acc \\ [])
  defp parse_unknowns(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_unknowns(bytes, acc) do
    with {:ok, tag, rest} <- Wire.decode_tag(bytes),
         number = tag >>> 3,
         wire_type = tag &&& 0x07,
         :ok <- Wire.validate_field_number(number),
         true <- wire_type in [0, 1, 2, 3, 5],
         {:ok, raw, rest} <- Wire.read_wire_raw(number, wire_type, rest) do
      parse_unknowns(rest, [UnknownField.from_raw(number, wire_type, raw) | acc])
    else
      _ -> :error
    end
  end

  defp hex(value, width),
    do: [
      "0x",
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    ]

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end

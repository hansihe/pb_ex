defmodule PB.TextFormat.Decoder do
  @moduledoc false

  # Schema-aware pass over the parser's syntax tree. Produces the canonical
  # proto-map the wire decoder produces (implicit-presence defaults omitted,
  # oneofs wrapped, maps as Elixir maps, known enum values as name atoms),
  # which PB.TextFormat then hands to the Frontend for projections.
  #
  # Field rules follow the C++ parser:
  #
  #   * a non-repeated field, or a second member of a oneof, may not be set
  #     twice. (C++ checks `HasField`, so it lets an implicit-presence field
  #     repeat after a default value; PB rejects every repeat.)
  #   * scalar fields need a colon after the name; message fields don't
  #   * a list is only allowed for repeated fields and its elements must match
  #     the field type; repeated fields may also be given once per occurrence
  #   * map fields are written as repeated entry messages; a missing key or
  #     value takes its default, and a repeated key keeps the last entry
  #   * with `ignore_unknown`, unknown fields are skipped as C++ does with
  #     `allow_unknown_field`
  #
  # Failures are thrown as `{:text_error, reason}` and returned by run/4. A
  # reason is a `PB.Runtime.Errors` tuple carrying a path, or one of
  # `{:malformed_text, message, offset, path}` and
  # `{:duplicate_field, name, offset, path}` for problems tied to a position.

  alias PB.Runtime.{Oneofs, RequiredFields, Scalar}
  alias PB.Schema.Features
  alias PB.TextFormat.Scalars

  @any :"google.protobuf.Any"

  @spec run([PB.TextFormat.Parser.field()], map, atom, keyword) :: {:ok, map} | {:error, tuple}
  def run(fields, schema, message_name, opts) do
    {:ok, decode_message(message_name, fields, schema, opts, [])}
  catch
    {:text_error, reason} -> {:error, reason}
  end

  # ── messages ─────────────────────────────────────────────────────────

  defp decode_message(name, fields, schema, opts, path) do
    msg = schema.messages[name]

    {acc, _seen} =
      Enum.reduce(fields, {%{}, %{}}, fn node, {acc, seen} ->
        case resolve(name, msg, node, opts, path) do
          :skip ->
            {acc, seen}

          field ->
            seen = claim!(field, node, seen, path)
            {put_field(acc, field, node, schema, opts, path ++ [field.name]), seen}
        end
      end)

    fields =
      Map.new(acc, fn
        {name, {:repeated, _count, reversed}} -> {name, Enum.reverse(reversed)}
        entry -> entry
      end)

    check_required!(msg, fields, path)
    Oneofs.wrap(fields, msg)
  end

  defp resolve(name, msg, %{name: {:field, field_name}} = node, opts, path) do
    case lookup(msg.fields_by_name, field_name) do
      nil -> unknown!(name, node, field_name, opts, path)
      field -> field
    end
  end

  defp resolve(name, msg, %{name: {:extension, ext_name}} = node, opts, path) do
    if lookup(msg.extensions_by_name, ext_name) do
      malformed!("extension fields are not supported in text format yet", node, path)
    else
      unknown!(name, node, "[#{ext_name}]", opts, path)
    end
  end

  defp resolve(@any, _msg, %{name: {:type_url, _url}} = node, _opts, path),
    do: malformed!("expanded google.protobuf.Any values are not supported yet", node, path)

  defp resolve(_name, _msg, %{name: {:type_url, url}} = node, _opts, path),
    do: malformed!("\"[#{url}]\" is only allowed in a google.protobuf.Any", node, path)

  # Like C++ `SkipField`, a skipped field without a colon must hold a message.
  defp unknown!(message_name, node, field_name, opts, path) do
    cond do
      not Keyword.get(opts, :ignore_unknown, false) ->
        throw({:text_error, {:unknown_field, message_name, path ++ [field_name]}})

      node.value.kind == :list and not node.colon ->
        malformed!(~s(expected ":" before a list value), node.value, path)

      true ->
        :skip
    end
  end

  defp claim!(field, node, seen, path) do
    if not Features.repeated?(field) and Map.has_key?(seen, field.name) do
      throw({:text_error, {:duplicate_field, field.name, node.offset, path ++ [field.name]}})
    end

    seen =
      if Features.oneof?(field) do
        case Map.fetch(seen, {:oneof, field.oneof_index}) do
          {:ok, other} ->
            reason = "#{field.name} is set along with #{other}, another member of the same oneof"
            throw({:text_error, {:invalid_oneof, path ++ [field.name], reason}})

          :error ->
            Map.put(seen, {:oneof, field.oneof_index}, field.name)
        end
      else
        seen
      end

    Map.put(seen, field.name, true)
  end

  # ── fields ───────────────────────────────────────────────────────────

  defp put_field(acc, field, node, schema, opts, path) do
    if field.type != :TYPE_MESSAGE and not node.colon do
      malformed!(~s(expected ":" after field name "#{field.name}"), node, path)
    end

    cond do
      Features.map?(field) ->
        entries = Map.get(acc, field.name, %{})
        Map.put(acc, field.name, put_map_entries(entries, field, node, schema, opts, path))

      Features.repeated?(field) ->
        {count, reversed} =
          case Map.fetch(acc, field.name) do
            {:ok, {:repeated, count, reversed}} -> {count, reversed}
            :error -> {0, []}
          end

        {count, reversed} =
          node
          |> elements()
          |> Enum.reduce({count, reversed}, fn value, {index, acc} ->
            {index + 1,
             [decode_value(field, value, schema, opts, path ++ [{:index, index}]) | acc]}
          end)

        Map.put(acc, field.name, {:repeated, count, reversed})

      node.value.kind == :list ->
        malformed!("a list is only allowed for repeated fields", node.value, path)

      true ->
        value = decode_value(field, node.value, schema, opts, path)

        if Features.implicit_presence?(field) and Scalar.default_value?(field, value),
          do: acc,
          else: Map.put(acc, field.name, value)
    end
  end

  defp elements(%{value: %{kind: :list, values: values}}), do: values
  defp elements(%{value: value}), do: [value]

  defp put_map_entries(entries, field, node, schema, opts, path) do
    entry_name = field.type_name
    entry_fields = schema.messages[entry_name].fields_by_name

    node
    |> elements()
    |> Enum.with_index()
    |> Enum.reduce(entries, fn {value, index}, entries ->
      entry_path = path ++ [{:index, index}]
      entry = decode_message_value(entry_name, value, schema, opts, entry_path)
      key = map_entry_part(entry, entry_fields.key, schema, opts, entry_path)
      value = map_entry_part(entry, entry_fields.value, schema, opts, entry_path)
      Map.put(entries, key, value)
    end)
  end

  defp map_entry_part(entry, field, schema, opts, path) do
    case Map.fetch(entry, field.name) do
      {:ok, value} ->
        value

      :error when field.type == :TYPE_MESSAGE ->
        decode_message(field.type_name, [], schema, opts, path ++ [field.name])

      :error ->
        {:ok, default} = Scalar.default_value(field)
        default
    end
  end

  # ── values ───────────────────────────────────────────────────────────

  defp decode_value(%{type: :TYPE_MESSAGE} = field, value, schema, opts, path),
    do: decode_message_value(field.type_name, value, schema, opts, path)

  defp decode_value(%{type: :TYPE_ENUM} = field, value, schema, _opts, path),
    do: decode_enum(field, value, schema, path)

  defp decode_value(field, value, _schema, _opts, path) do
    result =
      case field.type do
        :TYPE_STRING -> Scalars.string(value, Features.verify_utf8?(field))
        :TYPE_BYTES -> Scalars.string(value, false)
        :TYPE_BOOL -> Scalars.bool(value)
        type when type in [:TYPE_DOUBLE, :TYPE_FLOAT] -> Scalars.float(value, type)
        type -> Scalars.integer(value, type)
      end

    unwrap!(result, path)
  end

  defp decode_message_value(name, %{kind: :message, fields: fields}, schema, opts, path),
    do: decode_message(name, fields, schema, opts, path)

  defp decode_message_value(_name, value, _schema, _opts, path),
    do: malformed!(~s(expected a message value in "{...}" or "<...>"), value, path)

  defp decode_enum(field, %{kind: :identifier, negative: false} = value, schema, path) do
    enum = schema.enums[field.type_name]
    name = existing_atom(value.value)

    if name && Map.has_key?(enum.by_name, name),
      do: name,
      else: throw({:text_error, {:unknown_enum_value, path, field.type_name, value.value}})
  end

  defp decode_enum(field, %{kind: :integer} = value, schema, path) do
    enum = schema.enums[field.type_name]
    number = unwrap!(Scalars.integer(value, :TYPE_INT32), path)

    case Map.fetch(enum.by_number, number) do
      {:ok, name} ->
        name

      :error ->
        if Features.closed_enum?(enum),
          do: throw({:text_error, {:unknown_enum_value, path, field.type_name, number}}),
          else: number
    end
  end

  defp decode_enum(_field, value, _schema, path),
    do: throw({:text_error, {:invalid_value, path, :enum, Scalars.source(value)}})

  # ── helpers ──────────────────────────────────────────────────────────

  defp unwrap!({:ok, value}, _path), do: value

  defp unwrap!({:error, {:invalid_value, expected, got}}, path),
    do: throw({:text_error, {:invalid_value, path, expected, got}})

  defp unwrap!({:error, {:value_out_of_range, min, max, value}}, path),
    do: throw({:text_error, {:value_out_of_range, path, min, max, value}})

  defp malformed!(message, node, path),
    do: throw({:text_error, {:malformed_text, message, node.offset, path}})

  defp check_required!(msg, fields, path) do
    case RequiredFields.missing_path(msg.required_fields, fields, path) do
      nil -> :ok
      missing -> throw({:text_error, {:missing_required, missing}})
    end
  end

  defp lookup(by_name, name) do
    case existing_atom(name) do
      nil -> nil
      atom -> Map.get(by_name, atom)
    end
  end

  # Every schema name was interned at compile time, so a text name that is
  # not an existing atom cannot match, and this never grows the atom table.
  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end

defmodule PB.Schema.ExtensionMaterializer do
  @moduledoc false

  # Materializes descriptor options that were encoded as protobuf extensions.
  #
  # Descriptor decoding initially preserves option extensions as unknown fields
  # because user descriptors and option definitions arrive in the same
  # `FileDescriptorSet`. Once the compiler has built a draft schema, this module
  # decodes those option unknowns through a temporary prepared view of the same
  # schema and writes structured option values back into the draft.
  #
  # The important invariant is that `materialize/1` returns a draft schema. The
  # temporary prepared schema is only a decoder aid; runtime metadata from it must
  # not leak into the compiler output. Validation annotation still needs
  # materialized `:options`, and final runtime preparation happens later.

  alias PB.Schema.Prepare
  alias PB.UnknownField

  @extensions :__extensions__
  @unknowns UnknownField.key()

  @field_options :"google.protobuf.FieldOptions"
  @message_options :"google.protobuf.MessageOptions"
  @oneof_options :"google.protobuf.OneofOptions"
  @extension_range_options :"google.protobuf.ExtensionRangeOptions"

  @doc """
  Rewrites descriptor `:options` fields with structured extension values.

  The returned schema preserves draft-schema invariants: options are still
  present, but runtime indexes/tags/refs from the temporary decode schema are
  not copied back.
  """
  def materialize(schema) when is_map(schema) do
    # Prepare a single decode aid. Synthetic extendee messages (for option
    # extendees whose own type is not in the schema, e.g. when descriptors are
    # compiled without `--include_imports`) are folded in before this one
    # prepare so option decoding can look them up without re-preparing the
    # whole schema per extendee. The synthetic messages stay in `decode_schema`
    # only; the returned draft below is built from the original `schema`.
    decode_schema = schema |> with_synthetic_extendees() |> Prepare.prepare()

    schema
    |> Map.update!(:extensions_by_name, fn extensions ->
      Map.new(extensions, fn {name, extension} ->
        {name, materialize_field_options(decode_schema, extension)}
      end)
    end)
    |> Map.update!(:messages, fn messages ->
      Map.new(messages, fn {fqn, message} ->
        {fqn, materialize_message(decode_schema, message)}
      end)
    end)
  end

  def materialize_message_value(_schema, _message_name, value)
      when not is_map(value) or is_struct(value),
      do: value

  def materialize_message_value(schema, message_name, value) when is_atom(message_name) do
    case materialization_message(schema, message_name) do
      nil ->
        value

      message ->
        value
        |> materialize_field_values(schema, message)
        |> materialize_oneof_values(schema, message)
        |> materialize_extension_values(schema, message)
        |> materialize_unknown_extensions(schema, message_name)
    end
  end

  def referenced_extension_names(value) do
    value
    |> collect_referenced_extensions(MapSet.new())
    |> MapSet.to_list()
  end

  defp materialize_message(schema, message) do
    message
    |> materialize_options(schema, @message_options)
    |> materialize_fields(schema)
    |> materialize_message_extensions(schema)
    |> materialize_oneofs(schema)
    |> materialize_extension_ranges(schema)
  end

  defp materialize_fields(message, schema) do
    fields_by_name =
      message.fields_by_name
      |> Map.new(fn {name, field} -> {name, materialize_field_options(schema, field)} end)

    message
    |> Map.put(:fields_by_name, fields_by_name)
  end

  defp materialize_message_extensions(message, schema) do
    extensions_by_name =
      message.extensions_by_name
      |> Map.new(fn {name, extension} ->
        {name, materialize_field_options(schema, extension)}
      end)

    message
    |> Map.put(:extensions_by_name, extensions_by_name)
  end

  defp materialize_oneofs(message, schema) do
    Map.update!(message, :oneofs, fn oneofs ->
      Map.new(oneofs, fn {index, oneof} ->
        {index, materialize_options(oneof, schema, @oneof_options)}
      end)
    end)
  end

  defp materialize_extension_ranges(message, schema) do
    Map.update!(message, :extension_ranges, fn ranges ->
      Enum.map(ranges, &materialize_options(&1, schema, @extension_range_options))
    end)
  end

  defp materialize_field_options(schema, field) do
    materialize_options(field, schema, @field_options)
  end

  defp materialize_options(entry, schema, options_message) do
    case Map.fetch(entry, :options) do
      {:ok, options} ->
        Map.put(entry, :options, materialize_message_value(schema, options_message, options))

      :error ->
        entry
    end
  end

  defp materialize_field_values(value, schema, message) do
    Enum.reduce(message.fields_by_name, value, fn {name, field}, value ->
      case Map.fetch(value, name) do
        {:ok, field_value} ->
          Map.put(value, name, materialize_field_value(schema, field, field_value))

        :error ->
          value
      end
    end)
  end

  defp materialize_oneof_values(value, schema, message) do
    Enum.reduce(message.oneofs, value, fn {_index, oneof}, value ->
      case Map.fetch(value, oneof.name) do
        {:ok, {field_name, field_value}} ->
          case Map.fetch(message.fields_by_name, field_name) do
            {:ok, field} ->
              Map.put(
                value,
                oneof.name,
                {field_name, materialize_field_value(schema, field, field_value)}
              )

            :error ->
              value
          end

        _other ->
          value
      end
    end)
  end

  defp materialize_extension_values(value, schema, message) do
    case Map.fetch(value, @extensions) do
      {:ok, extensions} when is_map(extensions) ->
        extensions =
          Map.new(extensions, fn {name, extension_value} ->
            case Map.fetch(message.extensions_by_name, name) do
              {:ok, field} -> {name, materialize_field_value(schema, field, extension_value)}
              :error -> {name, extension_value}
            end
          end)

        Map.put(value, @extensions, extensions)

      _other ->
        value
    end
  end

  defp materialize_field_value(
         schema,
         %{cardinality: :map, map_value: %{type: :TYPE_MESSAGE, type_name: type_name}},
         values
       )
       when is_map(values) and not is_struct(values) do
    Map.new(values, fn {key, value} ->
      {key, materialize_message_value(schema, type_name, value)}
    end)
  end

  defp materialize_field_value(
         schema,
         %{cardinality: :repeated, type: :TYPE_MESSAGE, type_name: type_name},
         values
       )
       when is_list(values) do
    Enum.map(values, &materialize_message_value(schema, type_name, &1))
  end

  defp materialize_field_value(schema, %{type: :TYPE_MESSAGE, type_name: type_name}, value) do
    materialize_message_value(schema, type_name, value)
  end

  defp materialize_field_value(_schema, _field, value), do: value

  # TODO(schema): The schema compiler materializes extension options by
  # synthesizing a temporary message and calling public PB.decode/3. That
  # couples descriptor compilation to runtime decode behavior; a lower-level
  # extension/options decoder would be easier to reason about.
  defp materialize_unknown_extensions(value, schema, message_name) do
    unknowns = Map.get(value, @unknowns, [])

    if unknowns == [] do
      value
    else
      # `message_name` is guaranteed present in `schema` (the prepared decode
      # aid): either a real message or a synthetic extendee folded in by
      # `with_synthetic_extendees/1` before preparation.
      case PB.decode(
             IO.iodata_to_binary(Enum.map(unknowns, & &1.raw)),
             schema,
             message_name
           ) do
        {:ok, decoded} ->
          merge_materialized_unknowns(value, decoded)

        {:error, error} ->
          raise ArgumentError,
                "could not materialize extension fields for #{Atom.to_string(message_name)}: " <>
                  Exception.message(error)
      end
    end
  end

  defp merge_materialized_unknowns(value, decoded) do
    decoded_extensions = Map.get(decoded, @extensions, %{})
    decoded_unknowns = Map.get(decoded, @unknowns, [])
    decoded_fields = Map.drop(decoded, [@extensions, @unknowns])

    value
    |> Map.merge(decoded_fields)
    |> merge_extension_values(decoded_extensions)
    |> put_unknowns(decoded_unknowns)
  end

  defp merge_extension_values(value, extensions) when extensions == %{}, do: value

  defp merge_extension_values(value, extensions) do
    Map.update(value, @extensions, extensions, &Map.merge(&1, extensions))
  end

  defp put_unknowns(value, []), do: Map.delete(value, @unknowns)
  defp put_unknowns(value, unknowns), do: Map.put(value, @unknowns, unknowns)

  # `schema` is the prepared decode aid, which already contains any synthetic
  # extendee messages (folded in by `with_synthetic_extendees/1`), so a plain
  # lookup covers both real and synthetic-extendee option messages.
  defp materialization_message(schema, message_name), do: Map.get(schema.messages, message_name)

  # Builds stand-in messages for option extendees whose own message type is
  # absent from the schema, so that extensions on them (custom options) can
  # still be decoded. Real messages always win on name conflict.
  defp with_synthetic_extendees(schema) do
    Map.update!(schema, :messages, fn messages ->
      Map.merge(synthetic_extendee_messages(schema), messages)
    end)
  end

  defp synthetic_extendee_messages(schema) do
    schema.extensions_by_name
    |> Enum.group_by(fn {_name, extension} -> extension[:extendee] end)
    |> Enum.reject(fn {extendee, _extensions} ->
      is_nil(extendee) or Map.has_key?(schema.messages, extendee)
    end)
    |> Map.new(fn {extendee, extensions} ->
      {extendee, synthetic_message(Map.new(extensions))}
    end)
  end

  defp synthetic_message(extensions_by_name) do
    %{
      kind: :message,
      fields_by_name: %{},
      oneofs: %{},
      extension_ranges: [],
      extensions_by_name: extensions_by_name,
      map_entry: false
    }
  end

  defp collect_referenced_extensions(value, acc) when is_map(value) and not is_struct(value) do
    acc =
      case Map.fetch(value, @extensions) do
        {:ok, extensions} when is_map(extensions) ->
          Enum.reduce(extensions, acc, fn {name, extension_value}, acc ->
            extension_value
            |> collect_referenced_extensions(acc)
            |> MapSet.put(name)
          end)

        _other ->
          acc
      end

    Enum.reduce(value, acc, fn {_key, item}, acc -> collect_referenced_extensions(item, acc) end)
  end

  defp collect_referenced_extensions(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_referenced_extensions/2)
  end

  defp collect_referenced_extensions(value, acc) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> collect_referenced_extensions(acc)
  end

  defp collect_referenced_extensions(_value, acc), do: acc
end

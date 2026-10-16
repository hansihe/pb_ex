defmodule PB.Runtime.Decoder.Finalize do
  @moduledoc false

  # Final decode phase for runtime decode accumulators.
  #
  # `PB.Runtime.Decoder.Scan` produces a private accumulator that preserves
  # the information needed to apply protobuf decode semantics cheaply: repeated
  # values are reversed, maps are stored as repeated map-entry accumulators,
  # singular messages are already merged, and unknowns/extensions live under
  # private keys.
  #
  # This module is the semantic boundary between that accumulator and the public
  # decoded map. Finalization collapses duplicate map keys, reverses repeated
  # fields into wire order, validates required fields after all merges that can
  # affect presence, applies requested defaults, wraps oneofs, preserves unknowns,
  # and projects field adapters and configured term representations when
  # requested.

  alias PB.Runtime.Codec
  alias PB.Runtime.MessageView
  alias PB.Runtime.RequiredFields
  alias PB.Runtime.Scalar
  alias PB.Runtime.Schema, as: RuntimeSchema
  alias PB.Schema.Features

  @extension_key :__extensions__
  @unknown_key :__unknown_fields__

  @typedoc "Normalized runtime decode options."
  @type opts :: PB.Runtime.Decoder.Scan.opts()

  @typedoc "Current protobuf path used for decode errors."
  @type path :: PB.Runtime.Decoder.Scan.path()

  @typedoc "Public decoded protobuf message term."
  @type decoded :: term()

  @typedoc "Finalized protobuf field map before public term projection."
  @type proto_fields :: map()

  @typedoc "Raw winning map value before defaulting or message finalization."
  @type map_value_acc :: :absent | {:present, PB.Runtime.Decoder.Scan.occurrence_value()}

  @typedoc "Map entries after duplicate keys have been collapsed to their winning value."
  @type collapsed_map_entries :: [{term(), map_value_acc()}]

  @spec message(
          PB.Runtime.Decoder.Scan.t(),
          PB.Schema.Compiled.message(),
          PB.schema(),
          opts(),
          path()
        ) ::
          {:ok, decoded()} | {:error, PB.Error.t() | term()}
  def message(acc, msg, schema, opts, path) do
    with :ok <- ensure_required(acc, msg, path),
         {:ok, fields} <- finalize_present_fields(acc, msg, schema, opts, path),
         {:ok, fields} <- maybe_apply_defaults(fields, msg, schema, opts, path) do
      MessageView.from_proto_fields(schema, msg, fields, acc, path)
    end
  end

  defp finalize_present_fields(acc, msg, schema, opts, path) do
    Enum.reduce_while(acc, {:ok, %{}}, fn
      {@unknown_key, _unknowns}, {:ok, fields} ->
        {:cont, {:ok, fields}}

      {@extension_key, extensions}, {:ok, fields} ->
        case finalize_extensions(fields, extensions, msg, schema, opts, path) do
          {:ok, fields} -> {:cont, {:ok, fields}}
          {:error, _reason} = error -> {:halt, error}
        end

      {name, value}, {:ok, fields} ->
        field = Map.fetch!(msg.fields_by_name, name)

        case finalize_field(schema, msg, field, value, opts, path, :field) do
          {:ok, :omit} -> {:cont, {:ok, fields}}
          {:ok, {key, value}} -> {:cont, {:ok, Map.put(fields, key, value)}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp finalize_extensions(fields, extensions, msg, schema, opts, path) do
    Enum.reduce_while(extensions, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      field = Map.fetch!(msg.extensions_by_name, name)

      case finalize_field(schema, msg, field, value, opts, path, :extension) do
        {:ok, :omit} -> {:cont, {:ok, acc}}
        {:ok, {^name, value}} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:ok, {_key, value}} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, finalized} when map_size(finalized) == 0 -> {:ok, fields}
      {:ok, finalized} -> {:ok, Map.put(fields, @extension_key, finalized)}
      {:error, _reason} = error -> error
    end
  end

  defp finalize_field(schema, msg, field, value, opts, path, storage) do
    field_path = path ++ field_path(field, storage)

    with {:ok, value} <- finalize_field_value(schema, field, value, opts, field_path) do
      cond do
        omit_decoded_field?(schema, field, value, opts) ->
          {:ok, :omit}

        Features.oneof?(field) and storage == :field ->
          # Wrap uniformly as `{member, value}`; identity-oneof projection
          # (collapsing to the bare member struct) is owned by
          # `Representation.from_proto`, which runs next via `from_proto_fields`.
          oneof = msg.oneofs[field.oneof_index]
          {:ok, {oneof.name, {field.name, value}}}

        true ->
          {:ok, {field.name, value}}
      end
    end
  end

  defp finalize_field_value(schema, %{cardinality: :map} = field, values, opts, path) do
    if field[:map_entry] do
      finalize_map_values(values, field.map_entry, schema, opts, path)
    else
      {:ok, Enum.reverse(values)}
    end
  end

  defp finalize_field_value(
         schema,
         %{cardinality: :repeated, type: :TYPE_MESSAGE} = field,
         values,
         opts,
         path
       ) do
    values
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case finalize_message_field_value(schema, field, value, opts, path ++ [{:index, index}]) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp finalize_field_value(_schema, %{cardinality: :repeated}, values, _opts, _path) do
    {:ok, Enum.reverse(values)}
  end

  defp finalize_field_value(schema, %{type: :TYPE_MESSAGE} = field, value, opts, path) do
    finalize_message_field_value(schema, field, value, opts, path)
  end

  defp finalize_field_value(_schema, _field, value, _opts, _path), do: {:ok, value}

  defp finalize_message_field_value(schema, field, value, opts, path) do
    # Recurse the child with full opts so *its* descendants reach their native
    # form, then apply this field's adapter one level on the native children.
    with {:ok, ref} <- RuntimeSchema.fetch_message(schema, field.type_name),
         {:ok, value} <- message(value, ref, schema, opts, path),
         {:ok, value} <- maybe_field_adapter_from_proto(field, value, path) do
      {:ok, value}
    end
  end

  defp finalize_map_values(values, map_msg, schema, opts, path) do
    key_field = Map.fetch!(map_msg.fields_by_name, :key)
    value_field = Map.fetch!(map_msg.fields_by_name, :value)

    with {:ok, collapsed} <-
           collapse_map_entries(values, key_field, value_field, schema, opts, path) do
      finalize_collapsed_map_values(collapsed, value_field, schema, opts, path)
    end
  end

  defp collapse_map_entries(values, key_field, value_field, schema, opts, path) do
    # Duplicate map keys replace the whole entry value, but each winning entry's
    # value still needs normal field finalization. Collapse by finalized key
    # first so overwritten message values cannot fail required validation.
    values
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {entry, index}, {:ok, acc} ->
      entry_path = path ++ [{:index, index}]

      case map_entry_key(entry, key_field, schema, opts, entry_path) do
        {:ok, key} ->
          value_acc =
            case Map.fetch(entry, value_field.name) do
              {:ok, value} -> {:present, value}
              :error -> :absent
            end

          {:cont, {:ok, Map.put(acc, key, {index, value_acc})}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, collapsed} -> {:ok, order_collapsed_map_entries(collapsed)}
      {:error, _reason} = error -> error
    end
  end

  defp map_entry_key(entry, field, schema, opts, path) do
    path = path ++ [field.name]

    case Map.fetch(entry, field.name) do
      {:ok, value} -> finalize_field_value(schema, field, value, opts, path)
      :error -> default_for_type(schema, field, path)
    end
  end

  defp order_collapsed_map_entries(collapsed) do
    collapsed
    |> Enum.map(fn {key, {index, value_acc}} -> {index, key, value_acc} end)
    |> Enum.sort_by(fn {index, _key, _value_acc} -> index end)
    |> Enum.map(fn {_index, key, value_acc} -> {key, value_acc} end)
  end

  defp finalize_collapsed_map_values(collapsed, value_field, schema, opts, path) do
    Enum.reduce_while(collapsed, {:ok, %{}}, fn {key, value_acc}, {:ok, acc} ->
      case finalize_collapsed_map_value(
             value_acc,
             value_field,
             schema,
             opts,
             path ++ [{:key, key}]
           ) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp finalize_collapsed_map_value(:absent, field, schema, _opts, path) do
    default_for_type(schema, field, path)
  end

  defp finalize_collapsed_map_value({:present, value}, field, schema, opts, path) do
    finalize_field_value(schema, field, value, opts, path)
  end

  defp omit_decoded_field?(_schema, _field, _value, %{defaults: true}), do: false

  defp omit_decoded_field?(_schema, field, value, _opts) do
    Features.implicit_presence?(field) and
      Scalar.default_value?(field, value)
  end

  defp maybe_apply_defaults(fields, msg, schema, %{defaults: true}, path) do
    apply_defaults(fields, msg, schema, path)
  end

  defp maybe_apply_defaults(fields, _msg, _schema, _opts, _path), do: {:ok, fields}

  defp ensure_required(fields, msg, path) do
    case RequiredFields.missing_path(msg.required_fields, fields, path, nil_message: :present) do
      nil -> :ok
      missing -> {:error, {:missing_required, missing}}
    end
  end

  defp apply_defaults(fields, msg, schema, path) do
    Enum.reduce_while(msg.default_fields, {:ok, fields}, fn field, {:ok, acc} ->
      cond do
        Map.has_key?(acc, field.name) ->
          {:cont, {:ok, acc}}

        field.cardinality == :map ->
          {:cont, {:ok, Map.put(acc, field.name, %{})}}

        field.cardinality == :repeated ->
          {:cont, {:ok, Map.put(acc, field.name, [])}}

        true ->
          case default_for_type(schema, field, path ++ [field.name]) do
            {:ok, default} -> {:cont, {:ok, Map.put(acc, field.name, default)}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp default_for_type(_schema, field, path), do: Scalar.default_value(field, path)

  defp maybe_field_adapter_from_proto(%{adapter: adapter, type_name: fqn}, value, path) do
    Codec.adapter_from_proto(adapter, fqn, value, path)
  end

  defp maybe_field_adapter_from_proto(_field, value, _path), do: {:ok, value}

  defp field_path(field, :field), do: [field.name]
  defp field_path(field, :extension), do: [@extension_key, field.name]
end

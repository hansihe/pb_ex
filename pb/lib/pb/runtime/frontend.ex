defmodule PB.Runtime.Frontend do
  @moduledoc false

  # Backend-agnostic "frontend": converts between a canonical protobuf field map
  # (the proto-map pivot) and the schema's configured *native* representation —
  # the pluggable adapter (`PB.Adapter`) and struct/unwrap representation layers.
  #
  # The wire codec applies this same logic fused into its decode/encode
  # traversal (for single-pass performance). The ProtoJSON backend, which is not
  # on the hot path, keeps its format walk pure and runs this as a separate pass
  # at the message boundary — so `PB.JSON` honors projections identically to
  # `PB.encode`/`PB.decode`. Representation is a property of the *schema*; the
  # serialization format is a property of the *call*.
  #
  # An adapter is a *one-level* conversion: recursion is always owned by this
  # engine, not the adapter. On `from_proto` we recurse into children first, so
  # the adapter sees native children; on `to_proto` the adapter runs first and
  # we recurse its output, so child terms it leaves native are converted back to
  # proto-map. (Adapters that nest — e.g. WKT `Value`/`Struct`/`ListValue` —
  # therefore compose without re-implementing recursion. The contract for an
  # adapter author: emit native children, never proto-map children.)
  #
  # `from_proto` recurses into children *then* applies this message's adapter or
  # representation; `to_proto` is the mirror — adapter/representation first, then
  # recurse. Both share `recurse/4` + `convert_value/4`, parameterized by the
  # per-child converter.

  alias PB.Runtime.Codec
  alias PB.Runtime.MessageView

  @extension_key :__extensions__

  @doc """
  Converts a decoded proto-map for message `fqn`/`msg` into the schema's native
  representation. Returns `{:ok, term}` or `{:error, reason}` (raw reason /
  exception — funnel through `PB.Runtime.Errors`).
  """
  @spec from_proto(
          term(),
          PB.Schema.Compiled.message_name(),
          PB.Schema.Compiled.message(),
          PB.schema()
        ) ::
          {:ok, term()} | {:error, term()}
  def from_proto(nil, _fqn, _msg, _schema), do: {:ok, nil}

  def from_proto(fields, fqn, msg, schema) do
    with {:ok, fields} <- recurse(fields, msg, schema, &from_proto_child/3) do
      case adapter(msg) do
        nil ->
          # Oneofs arrive wrapped as `{member, value}`; identity-oneof
          # projection is owned by `Representation.from_proto` (reached via
          # `from_proto_fields`), identically to the wire decode path.
          MessageView.from_proto_fields(schema, msg, fields, %{}, [])

        adapter ->
          Codec.adapter_from_proto(adapter, fqn, fields, [])
      end
    end
  end

  @doc """
  Converts a native message value for `fqn`/`msg` into the canonical proto-map.
  Mirror of `from_proto/4`.
  """
  @spec to_proto(
          term(),
          PB.Schema.Compiled.message_name(),
          PB.Schema.Compiled.message(),
          PB.schema()
        ) ::
          {:ok, term()} | {:error, term()}
  def to_proto(value, fqn, msg, schema) do
    case adapter(msg) do
      # No adapter: a nil message is absent; otherwise project representation.
      nil when is_nil(value) ->
        {:ok, nil}

      nil ->
        with {:ok, fields} <- MessageView.to_proto_fields(schema, fqn, msg, value, []) do
          recurse(fields, msg, schema, &to_proto_child/3)
        end

      # An adapter interprets nil as a native value (a JSON `null` `Value`, ...).
      adapter ->
        with {:ok, fields} <- Codec.adapter_to_proto(adapter, fqn, value, []) do
          recurse(fields, msg, schema, &to_proto_child/3)
        end
    end
  end

  # ── shared recursion ─────────────────────────────────────────────────

  # Convert message-typed values in place — regular fields first, then known
  # extensions (stored under `:__extensions__` by full name), then the member
  # held by each oneof (stored as `oneof.name => {member_field, value}`).
  defp recurse(fields, msg, schema, child) when is_map(fields) and not is_struct(fields) do
    with {:ok, fields} <- recurse_regular(fields, msg, schema, child),
         {:ok, fields} <- recurse_extensions(fields, msg, schema, child) do
      recurse_oneofs(fields, msg, schema, child)
    end
  end

  defp recurse(fields, _msg, _schema, _child), do: {:ok, fields}

  defp recurse_regular(fields, msg, schema, child) do
    Enum.reduce_while(msg.fields_by_name, {:ok, fields}, fn {name, field}, {:ok, acc} ->
      case Map.fetch(acc, name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case convert_value(field, value, schema, child) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  # Names the schema does not know are left for encode validation to report.
  defp recurse_extensions(%{@extension_key => extensions} = fields, msg, schema, child)
       when is_map(extensions) do
    extensions
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case Map.fetch(msg.extensions_by_name, name) do
        {:ok, field} ->
          case convert_value(field, value, schema, child) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
    |> case do
      {:ok, extensions} -> {:ok, Map.put(fields, @extension_key, extensions)}
      {:error, _reason} = error -> error
    end
  end

  defp recurse_extensions(fields, _msg, _schema, _child), do: {:ok, fields}

  defp recurse_oneofs(fields, msg, schema, child) do
    Enum.reduce_while(msg.oneofs, {:ok, fields}, fn {_index, oneof}, {:ok, acc} ->
      case Map.fetch(acc, oneof.name) do
        {:ok, {member, value}} when is_atom(member) ->
          field = Map.fetch!(msg.fields_by_name, member)

          case convert_value(field, value, schema, child) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, oneof.name, {member, value})}}
            {:error, _reason} = error -> {:halt, error}
          end

        _other ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  # Recurse only into message-typed values; scalars/enums pass through.
  defp convert_value(
         %{type: :TYPE_MESSAGE, cardinality: :repeated} = field,
         values,
         schema,
         child
       )
       when is_list(values) do
    map_ok(values, fn value -> child.(field.type_name, value, schema) end)
  end

  defp convert_value(%{type: :TYPE_MESSAGE, cardinality: :map} = field, entries, schema, child)
       when is_map(entries) and not is_struct(entries) do
    case field[:map_value] do
      %{type: :TYPE_MESSAGE, type_name: value_fqn} ->
        Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case child.(value_fqn, value, schema) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      _scalar_value ->
        {:ok, entries}
    end
  end

  defp convert_value(%{type: :TYPE_MESSAGE, type_name: fqn}, value, schema, child) do
    child.(fqn, value, schema)
  end

  defp convert_value(_field, value, _schema, _child), do: {:ok, value}

  defp from_proto_child(fqn, value, schema), do: dispatch(fqn, value, schema, &from_proto/4)
  defp to_proto_child(fqn, value, schema), do: dispatch(fqn, value, schema, &to_proto/4)

  defp dispatch(fqn, value, schema, fun) do
    case schema.messages[fqn] do
      nil -> {:ok, value}
      ref -> fun.(value, fqn, ref, schema)
    end
  end

  defp adapter(%{projection: %{adapter: adapter}}) when not is_nil(adapter), do: adapter
  defp adapter(_msg), do: nil

  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end

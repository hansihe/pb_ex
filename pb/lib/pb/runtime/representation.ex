defmodule PB.Runtime.Representation do
  @moduledoc false

  alias PB.Runtime.Errors
  alias PB.Schema.Features

  @extension_key :__extensions__
  @unknown_key :__unknown_fields__

  @spec from_proto(
          map(),
          map(),
          PB.Schema.Compiled.message(),
          PB.schema(),
          [PB.Error.path_element()]
        ) ::
          {:ok, term()} | {:error, term()}
  def from_proto(fields, acc, msg, schema, path) do
    fields = canonicalize_identity_oneofs_from_proto(msg, fields)
    do_from_proto(fields, acc, msg, schema, path)
  end

  @spec to_proto(
          PB.schema(),
          PB.Schema.Compiled.message(),
          PB.Schema.Compiled.message_name(),
          term(),
          [PB.Error.path_element()]
        ) ::
          {:ok, map()} | {:error, term()}
  def to_proto(_schema, msg, _msg_name, data, path) do
    do_to_proto(msg, data, path)
  end

  @spec canonicalize_proto_fields(PB.Schema.Compiled.message(), map(), [
          PB.Error.path_element()
        ]) ::
          {:ok, map()} | {:error, term()}
  def canonicalize_proto_fields(msg, fields, path)
      when is_map(fields) and not is_struct(fields) do
    canonicalize_oneofs(msg, fields, path)
  end

  defp do_from_proto(fields, acc, %{projection: %{struct_mod: struct_mod}} = msg, _schema, path)
       when not is_nil(struct_mod) do
    unknowns = unknown_fields(acc)

    with {:ok, values} <- struct_field_values(fields, msg),
         {:ok, values} <- apply_unknown_fields_from_proto(values, unknowns, msg, path),
         {:ok, values} <- apply_extensions_from_proto(values, fields, msg, path) do
      {:ok, struct!(struct_mod, values)}
    end
  end

  defp do_from_proto(
         fields,
         acc,
         %{projection: %{unwrap_field: unwrap_field}} = msg,
         _schema,
         path
       )
       when not is_nil(unwrap_field) do
    unknowns = unknown_fields(acc)

    with :ok <- check_unknown_fields(unknowns, msg, path),
         :ok <- check_extensions(fields, msg, path) do
      field = Map.fetch!(msg.fields_by_name, unwrap_field)
      {:ok, Map.get(fields, field.name, absent_field_value(field))}
    end
  end

  defp do_from_proto(fields, acc, _msg, _schema, _path) do
    {:ok, put_unknown_fields(fields, acc)}
  end

  defp do_to_proto(%{projection: %{struct_mod: struct_mod}} = msg, data, path)
       when not is_nil(struct_mod) do
    if struct?(data, struct_mod) do
      data = Map.from_struct(data)

      with {:ok, fields} <- struct_to_proto_fields(msg, data),
           {:ok, fields} <- apply_unknown_fields_to_proto(fields, data, msg),
           {:ok, fields} <- apply_extensions_to_proto(fields, data, msg),
           {:ok, fields} <- canonicalize_oneofs(msg, fields, path) do
        {:ok, fields}
      end
    else
      {:error, {:invalid_value, path, {:struct, struct_mod}, Errors.type_of(data)}}
    end
  end

  defp do_to_proto(%{projection: %{unwrap_field: unwrap_field}} = msg, data, _path)
       when not is_nil(unwrap_field) do
    field = Map.fetch!(msg.fields_by_name, unwrap_field)

    if data == nil and not (Features.repeated?(field) or Features.map?(field)) do
      {:ok, %{}}
    else
      {:ok, %{unwrap_field => data}}
    end
  end

  defp do_to_proto(msg, data, path) when is_map(data) and not is_struct(data) do
    canonicalize_oneofs(msg, data, path)
  end

  defp do_to_proto(_msg, data, _path), do: {:ok, data}

  defp struct?(%module{}, module), do: true
  defp struct?(_value, _module), do: false

  defp struct_field_values(fields, msg) do
    values =
      msg.fields_by_name
      |> Map.values()
      |> Enum.reject(&oneof_field?/1)
      |> Map.new(fn field ->
        {field.name, Map.get(fields, field.name, absent_field_value(field))}
      end)

    values =
      Enum.reduce(msg.oneofs, values, fn {_index, oneof}, acc ->
        Map.put(acc, oneof.name, Map.get(fields, oneof.name, nil))
      end)

    {:ok, values}
  end

  defp oneof_field?(%{presence: :oneof}), do: true
  defp oneof_field?(_field), do: false

  defp absent_field_value(%{cardinality: :repeated}), do: []
  defp absent_field_value(%{cardinality: :map}), do: %{}
  defp absent_field_value(_field), do: nil

  defp unknown_fields(acc) do
    acc
    |> Map.get(@unknown_key, [])
    |> Enum.reverse()
  end

  defp put_unknown_fields(fields, acc) do
    case unknown_fields(acc) do
      [] -> fields
      unknowns -> Map.put(fields, @unknown_key, unknowns)
    end
  end

  defp apply_unknown_fields_from_proto(values, unknowns, msg, path) do
    case msg.projection.preserved_unknown_fields do
      :drop ->
        {:ok, values}

      :reject ->
        with :ok <- reject_unknown_fields(unknowns, path), do: {:ok, values}

      {:field, field} ->
        {:ok, Map.put(values, field, unknowns)}
    end
  end

  defp check_unknown_fields(unknowns, msg, path) do
    case msg.projection.preserved_unknown_fields do
      :drop -> :ok
      :reject -> reject_unknown_fields(unknowns, path)
    end
  end

  defp reject_unknown_fields([], _path), do: :ok
  defp reject_unknown_fields(unknowns, path), do: {:error, {:unknown_wire_fields, path, unknowns}}

  defp apply_extensions_from_proto(values, fields, msg, path) do
    extensions = Map.get(fields, @extension_key, %{})

    case msg.projection.extensions do
      :reject ->
        with :ok <- reject_extensions(extensions, path), do: {:ok, values}

      {:field, field} ->
        {:ok, Map.put(values, field, extensions)}
    end
  end

  defp check_extensions(fields, msg, path) do
    case msg.projection.extensions do
      :reject -> reject_extensions(Map.get(fields, @extension_key, %{}), path)
    end
  end

  defp reject_extensions(extensions, _path) when extensions in [%{}, nil], do: :ok
  defp reject_extensions(extensions, path), do: {:error, {:extensions_present, path, extensions}}

  defp struct_to_proto_fields(msg, data) do
    fields =
      msg.fields_by_name
      |> Map.values()
      |> Enum.reject(&oneof_field?/1)
      |> Enum.reduce(%{}, fn field, acc ->
        put_regular_field(acc, field, Map.get(data, field.name))
      end)

    fields =
      Enum.reduce(msg.oneofs, fields, fn {_index, oneof}, acc ->
        put_oneof_field(acc, oneof, Map.get(data, oneof.name))
      end)

    {:ok, fields}
  end

  defp put_regular_field(acc, field, nil) do
    if Features.repeated?(field) or Features.map?(field) do
      Map.put(acc, field.name, nil)
    else
      acc
    end
  end

  defp put_regular_field(acc, field, value), do: Map.put(acc, field.name, value)

  defp put_oneof_field(acc, _oneof, nil), do: acc
  defp put_oneof_field(acc, oneof, value), do: Map.put(acc, oneof.name, value)

  # Decode-side mirror of `canonicalize_oneofs`: an identity-oneof slot decoded
  # as `{member, value}` (the shape both decode backends emit — the wire decoder
  # in `Finalize`, the JSON decoder in `Frontend`) collapses to the bare member
  # `value`, which `from_proto` then projects by struct identity. Idempotent: a
  # slot that is already bare (a member struct, or absent) never matches the
  # `{member, value}` tuple pattern and is left untouched, so callers that
  # pre-canonicalize stay correct. Only identity oneofs appear in
  # `projection.oneofs`, so non-identity oneofs and oneof-free messages pay just
  # the `map_size/1` guard.
  defp canonicalize_identity_oneofs_from_proto(%{projection: %{oneofs: oneofs}}, fields)
       when is_map(fields) and not is_struct(fields) and map_size(oneofs) > 0 do
    Enum.reduce(oneofs, fields, fn
      {name, :identity}, acc ->
        case acc do
          %{^name => {member, value}} when is_atom(member) -> Map.put(acc, name, value)
          _other -> acc
        end

      {_name, _representation}, acc ->
        acc
    end)
  end

  defp canonicalize_identity_oneofs_from_proto(_msg, fields), do: fields

  defp canonicalize_oneofs(msg, fields, path) do
    Enum.reduce_while(msg.oneofs, {:ok, fields}, fn {_index, oneof}, {:ok, acc} ->
      case canonical_oneof_value(msg, oneof, Map.fetch(acc, oneof.name), path) do
        {:ok, :absent} -> {:cont, {:ok, acc}}
        {:ok, :delete} -> {:cont, {:ok, Map.delete(acc, oneof.name)}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, oneof.name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp canonical_oneof_value(_msg, _oneof, :error, _path), do: {:ok, :absent}
  defp canonical_oneof_value(_msg, _oneof, {:ok, nil}, _path), do: {:ok, :delete}

  defp canonical_oneof_value(_msg, oneof, {:ok, {field, _value} = entry}, path)
       when is_atom(field) do
    if field in oneof.fields do
      {:ok, entry}
    else
      {:error, {:invalid_oneof, path ++ [oneof.name], {:unknown_member, field}}}
    end
  end

  defp canonical_oneof_value(msg, oneof, {:ok, %module{} = value}, path) do
    if identity_oneof?(msg, oneof) do
      case Map.fetch(oneof.term_by_struct, module) do
        {:ok, field} ->
          {:ok, {field, value}}

        :error ->
          {:error, {:invalid_oneof, path ++ [oneof.name], {:unknown_member_struct, module}}}
      end
    else
      {:ok, value}
    end
  end

  defp canonical_oneof_value(msg, oneof, {:ok, _value} = fetched, path) do
    if identity_oneof?(msg, oneof) do
      {:error, {:invalid_oneof, path ++ [oneof.name], :expected_member_struct}}
    else
      {_ok, value} = fetched
      {:ok, value}
    end
  end

  defp apply_unknown_fields_to_proto(fields, data, msg) do
    case msg.projection.preserved_unknown_fields do
      {:field, field} -> put_aux_field(fields, @unknown_key, Map.get(data, field), [])
      _policy -> {:ok, fields}
    end
  end

  defp apply_extensions_to_proto(fields, data, msg) do
    case msg.projection.extensions do
      {:field, field} -> put_aux_field(fields, @extension_key, Map.get(data, field), %{})
      :reject -> {:ok, fields}
    end
  end

  defp put_aux_field(fields, _key, empty, empty), do: {:ok, fields}
  defp put_aux_field(fields, key, value, _empty), do: {:ok, Map.put(fields, key, value)}

  defp identity_oneof?(%{projection: %{oneofs: oneofs}}, %{name: name}) do
    Map.get(oneofs, name) == :identity
  end

  defp identity_oneof?(_msg, _oneof), do: false
end

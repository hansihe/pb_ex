defmodule PB.Runtime.MessageView do
  @moduledoc false

  alias PB.Runtime.Codec
  alias PB.Runtime.Errors
  alias PB.Runtime.Representation

  @extension_key :__extensions__

  @type proto_fields :: map()
  @type decode_acc :: PB.Runtime.Decoder.Scan.t()

  @spec to_proto_fields(
          PB.schema(),
          PB.Schema.Compiled.message_name(),
          PB.Schema.Compiled.message(),
          term(),
          [PB.Error.path_element()]
        ) ::
          {:ok, map()} | {:error, term()}
  def to_proto_fields(schema, message_name, message, data, path) do
    with {:ok, data} <- adapter_to_proto(message, message_name, data, path),
         {:ok, fields} <- Representation.to_proto(schema, message, message_name, data, path),
         :ok <- require_proto_fields(fields, path) do
      {:ok, drop_unset(fields, message)}
    end
  end

  @spec from_proto_fields(
          PB.schema(),
          PB.Schema.Compiled.message(),
          proto_fields(),
          decode_acc(),
          [PB.Error.path_element()]
        ) :: {:ok, term()} | {:error, term()}
  def from_proto_fields(schema, message, fields, acc, path) do
    Representation.from_proto(fields, acc, message, schema, path)
  end

  # The adapter is one level: the engine recurses its output. An adapter-mode
  # message has no representation (mutual exclusivity), so the downstream
  # `Representation.to_proto` is a no-op.
  defp adapter_to_proto(message, message_name, data, path) do
    case message_adapter(message) do
      nil ->
        {:ok, data}

      adapter ->
        Codec.adapter_to_proto(adapter, message_name, data, path)
    end
  end

  defp message_adapter(%{projection: %{adapter: adapter}}) when not is_nil(adapter), do: adapter
  defp message_adapter(_message), do: nil

  # `nil` means unset: a field, oneof or extension set to nil is the same as
  # one left out, for every consumer of the proto view. The exception is a
  # message field whose type has an adapter, since nil may be one of the
  # adapter's native values (a `google.protobuf.Value` null). Keys the message
  # does not know are kept, so they are still reported.
  # Encoding runs this for every message, so the common case of no nil
  # values is a scan that allocates nothing.
  defp drop_unset(fields, message) do
    fields =
      if has_nil?(:maps.iterator(fields)),
        do: Map.filter(fields, fn {key, value} -> value != nil or keeps_nil?(message, key) end),
        else: fields

    drop_unset_extensions(fields, message)
  end

  defp has_nil?(iterator) do
    case :maps.next(iterator) do
      {_key, nil, _next} -> true
      {_key, _value, next} -> has_nil?(next)
      :none -> false
    end
  end

  defp drop_unset_extensions(%{@extension_key => extensions} = fields, message)
       when is_map(extensions) and not is_struct(extensions) do
    if has_nil?(:maps.iterator(extensions)) do
      extensions =
        Map.filter(extensions, fn {name, value} ->
          value != nil or adapter_field?(message.extensions_by_name, name)
        end)

      %{fields | @extension_key => extensions}
    else
      fields
    end
  end

  defp drop_unset_extensions(fields, _message), do: fields

  defp keeps_nil?(message, key) do
    cond do
      Map.has_key?(message.fields_by_name, key) -> adapter_field?(message.fields_by_name, key)
      Map.has_key?(message.oneofs_by_name, key) or key == @extension_key -> false
      true -> true
    end
  end

  defp adapter_field?(fields_by_name, name),
    do: match?(%{^name => %{adapter: _}}, fields_by_name)

  defp require_proto_fields(fields, _path) when is_map(fields) and not is_struct(fields), do: :ok

  defp require_proto_fields(fields, path) do
    {:error, {:invalid_value, path, :map, Errors.type_of(fields)}}
  end
end

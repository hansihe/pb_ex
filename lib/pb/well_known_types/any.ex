defmodule PB.WellKnownTypes.Any do
  @moduledoc false

  # Shared `google.protobuf.Any` helpers. An Any is stored as
  # `%{type_url: binary, value: bytes}`. Formats that show the packed message
  # inline (ProtoJSON's `@type`, text format's `[type_url] { ... }`) convert
  # between the bytes and the packed message's canonical proto-map here, going
  # through the schema's native representation so projected types work.
  #
  # Which type URLs a format accepts is the format's own rule: ProtoJSON takes
  # any host and reads the last path segment, while C++ text format only takes
  # the prefixes in `google_prefixes/0`.

  alias PB.Runtime.Errors
  alias PB.Runtime.Frontend
  alias PB.SchemaError

  @default_prefix "type.googleapis.com/"
  @google_prefixes [@default_prefix, "type.googleprod.com/"]

  @doc "The prefix PB uses when it builds a type URL."
  @spec default_prefix() :: String.t()
  def default_prefix, do: @default_prefix

  @doc "The prefixes Google's own resolvers accept."
  @spec google_prefixes() :: [String.t()]
  def google_prefixes, do: @google_prefixes

  @doc "Builds the type URL for a message name."
  @spec type_url(atom | String.t()) :: String.t()
  def type_url(message_name), do: @default_prefix <> to_string(message_name)

  @doc """
  Splits a type URL after its last `/` into the prefix (ending in `/`) and the
  message name. Returns `:error` when there is no `/` or nothing follows it.
  """
  @spec split_type_url(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_type_url(url) when is_binary(url) do
    case :binary.matches(url, "/") do
      [] ->
        :error

      matches ->
        {slash, 1} = List.last(matches)
        split = slash + 1

        case binary_part(url, split, byte_size(url) - split) do
          "" -> :error
          name -> {:ok, binary_part(url, 0, split), name}
        end
    end
  end

  @doc """
  Encodes a packed message, given as a canonical proto-map, into `Any.value`
  bytes.
  """
  @spec pack(map, PB.schema(), atom) :: {:ok, binary} | {:error, PB.Error.t()}
  def pack(fields, schema, message_name) do
    with {:ok, msg} <- fetch_message(schema, message_name),
         {:ok, native} <-
           fields
           |> Frontend.from_proto(message_name, msg, schema)
           |> Errors.normalize_result(:encode, message_name) do
      PB.encode(native, schema, message_name)
    end
  end

  @doc """
  Decodes `Any.value` bytes into the packed message's canonical proto-map.
  """
  @spec unpack(binary, PB.schema(), atom) :: {:ok, map} | {:error, PB.Error.t()}
  def unpack(bytes, schema, message_name) do
    with {:ok, msg} <- fetch_message(schema, message_name),
         {:ok, native} <- PB.decode(bytes, schema, message_name) do
      native
      |> Frontend.to_proto(message_name, msg, schema)
      |> Errors.normalize_result(:decode, message_name)
    end
  end

  defp fetch_message(schema, message_name) do
    case schema.messages[message_name] do
      nil -> {:error, %SchemaError{kind: :unknown_message, name: message_name}}
      msg -> {:ok, msg}
    end
  end
end

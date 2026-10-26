defmodule PB.Runtime.Schema do
  @moduledoc false

  @spec fetch_message(PB.schema(), PB.Schema.Compiled.message_name()) ::
          {:ok, PB.Schema.Compiled.message()}
          | {:error, {:unknown_message, PB.Schema.Compiled.message_name()}}
  def fetch_message(schema, message_name) do
    case schema.messages[message_name] do
      nil -> {:error, {:unknown_message, message_name}}
      msg -> {:ok, msg}
    end
  end

  @spec map_entry_message(PB.schema(), PB.Schema.Compiled.field()) ::
          PB.Schema.Compiled.message() | nil
  def map_entry_message(_schema, %{cardinality: :map, map_entry: %{map_entry: true} = map_msg}),
    do: map_msg

  def map_entry_message(_schema, _field), do: nil
end

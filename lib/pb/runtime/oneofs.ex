defmodule PB.Runtime.Oneofs do
  @moduledoc false

  @doc """
  Moves each set oneof member of a canonical proto-map under its oneof name as
  `{member, value}`, the shape the wire decoder produces. For decoders that
  collect fields by name first; at most one member per oneof may be present.
  """
  @spec wrap(map, PB.Schema.Compiled.message()) :: map
  def wrap(fields, msg) do
    Enum.reduce(msg.oneofs, fields, fn {_index, oneof}, acc ->
      case Enum.find(oneof.fields, &Map.has_key?(acc, &1)) do
        nil -> acc
        member -> acc |> Map.delete(member) |> Map.put(oneof.name, {member, acc[member]})
      end
    end)
  end
end

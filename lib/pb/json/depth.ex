defmodule PB.JSON.Depth do
  @moduledoc false

  alias PB.JSON.Errors

  @max_decode_depth PB.Wire.max_decode_depth()

  @doc false
  def max_decode_depth, do: @max_decode_depth

  @doc false
  def descend(depth) when is_integer(depth) and depth < @max_decode_depth,
    do: {:ok, depth + 1}

  def descend(_depth), do: :error

  @doc false
  def descend!(depth) do
    case descend(depth) do
      {:ok, depth} -> depth
      :error -> Errors.raise!(:malformed_json, :max_decode_depth_exceeded)
    end
  end
end

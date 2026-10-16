defmodule PB.UnknownField do
  @moduledoc """
  Preserved protobuf wire field that is not represented by the compiled schema.

  `raw` contains the complete encoded field, including tag and value bytes.
  """

  alias PB.Wire

  @enforce_keys [:number, :wire_type, :raw]
  defstruct [:number, :wire_type, :raw]

  @type t :: %__MODULE__{
          number: pos_integer(),
          wire_type: 0..5,
          raw: binary()
        }

  @key :__unknown_fields__
  @max_field_number 0x1FFFFFFF

  @spec key() :: :__unknown_fields__
  def key, do: @key

  @spec new(pos_integer(), 0..5, binary()) :: t
  def new(number, wire_type, raw) do
    validate!(number, wire_type, raw)
    %__MODULE__{number: number, wire_type: wire_type, raw: raw}
  end

  @spec from_raw(pos_integer(), 0..5, binary()) :: t
  def from_raw(number, wire_type, raw_body) do
    validate!(number, wire_type, <<>>)

    new(number, wire_type, IO.iodata_to_binary([Wire.encode_tag(number, wire_type), raw_body]))
  end

  defp validate!(number, wire_type, raw)
       when is_integer(number) and number >= 1 and number <= @max_field_number and
              wire_type in 0..5 and is_binary(raw),
       do: :ok

  defp validate!(number, wire_type, raw) do
    raise ArgumentError,
          "expected unknown field number 1..#{@max_field_number}, wire type 0..5, " <>
            "and binary raw bytes; got number: #{inspect(number)}, " <>
            "wire_type: #{inspect(wire_type)}, raw: #{inspect(raw)}"
  end

  @spec append(map, t) :: map
  def append(fields, %__MODULE__{} = unknown) when is_map(fields) do
    Map.update(fields, @key, [unknown], &[unknown | &1])
  end

  @spec reverse_all(map) :: map
  def reverse_all(fields) when is_map(fields) do
    case Map.fetch(fields, @key) do
      {:ok, unknowns} -> Map.put(fields, @key, Enum.reverse(unknowns))
      :error -> fields
    end
  end

  @spec encode_all(term) :: {:ok, [binary()]} | {:error, term}
  def encode_all(nil), do: {:ok, []}
  def encode_all([]), do: {:ok, []}

  def encode_all(unknowns) when is_list(unknowns) do
    Enum.reduce_while(unknowns, {:ok, []}, fn
      %__MODULE__{raw: raw}, {:ok, acc} ->
        {:cont, {:ok, [raw | acc]}}

      value, {:ok, _acc} ->
        {:halt, {:error, {:invalid_unknown_field, value}}}
    end)
    |> case do
      {:ok, raw} -> {:ok, Enum.reverse(raw)}
      {:error, _reason} = error -> error
    end
  end

  def encode_all(value), do: {:error, {:invalid_unknown_fields, value}}
end

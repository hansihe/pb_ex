defmodule PB.Runtime.Scalar do
  @moduledoc false

  import Bitwise

  alias PB.Runtime.Codec
  alias PB.Runtime.Errors
  alias PB.Schema.Features
  alias PB.Wire

  @int32_min -0x80000000
  @int32_max 0x7FFFFFFF
  @uint32_max 0xFFFFFFFF
  @int64_min -0x8000000000000000
  @int64_max 0x7FFFFFFFFFFFFFFF
  @uint64_max 0xFFFFFFFFFFFFFFFF

  @doc """
  The `{min, max}` range of values a protobuf integer field type holds.
  """
  @spec integer_range(atom) :: {integer, integer}
  def integer_range(type) when type in [:TYPE_INT32, :TYPE_SINT32, :TYPE_SFIXED32],
    do: {@int32_min, @int32_max}

  def integer_range(type) when type in [:TYPE_UINT32, :TYPE_FIXED32], do: {0, @uint32_max}

  def integer_range(type) when type in [:TYPE_INT64, :TYPE_SINT64, :TYPE_SFIXED64],
    do: {@int64_min, @int64_max}

  def integer_range(type) when type in [:TYPE_UINT64, :TYPE_FIXED64], do: {0, @uint64_max}

  def has_presence?(field), do: Features.has_presence?(field)
  def has_presence?(field, _syntax), do: has_presence?(field)

  def implicit_presence?(field), do: Features.implicit_presence?(field)
  def implicit_presence?(field, _syntax), do: implicit_presence?(field)

  def required?(field), do: Features.required?(field)

  def normalize_encode_value(field, nil, path), do: default_value(field, path)
  def normalize_encode_value(_field, value, _path), do: {:ok, value}

  def default_value(field, path \\ [])

  def default_value(%{default: default}, _path), do: {:ok, default}

  def default_value(field, path) do
    case field.type do
      :TYPE_DOUBLE ->
        {:ok, 0.0}

      :TYPE_FLOAT ->
        {:ok, 0.0}

      :TYPE_BOOL ->
        {:ok, false}

      :TYPE_STRING ->
        {:ok, ""}

      :TYPE_BYTES ->
        {:ok, ""}

      :TYPE_MESSAGE ->
        case field[:adapter] do
          nil ->
            {:ok, %{}}

          adapter ->
            Codec.adapter_from_proto(adapter, field.type_name, %{}, path)
        end

      :TYPE_ENUM ->
        {:ok, default_enum(field)}

      _numeric ->
        {:ok, 0}
    end
  end

  def default_value?(field, value) do
    case field.type do
      :TYPE_DOUBLE -> zero_float_default?(value)
      :TYPE_FLOAT -> zero_float_default?(value)
      :TYPE_BOOL -> value == false
      :TYPE_STRING -> value == ""
      :TYPE_BYTES -> value == ""
      :TYPE_ENUM -> default_enum?(field, value)
      :TYPE_MESSAGE -> false
      _numeric -> value == 0
    end
  end

  defp zero_float_default?(value) when is_integer(value), do: value == 0
  defp zero_float_default?(value), do: value === 0.0

  def validate_encode(field, value, path) do
    with {:ok, value} <- normalize_encode_value(field, value, path) do
      validate_normalized_encode(field, value, path)
    end
  end

  defp validate_normalized_encode(field, value, path) do
    case field.type do
      :TYPE_STRING ->
        validate_string(field, value, path)

      :TYPE_BYTES ->
        if is_binary(value), do: :ok, else: invalid_value(path, :binary, value)

      :TYPE_BOOL ->
        if value in [true, false], do: :ok, else: invalid_value(path, :boolean, value)

      :TYPE_DOUBLE ->
        validate_float(value, path)

      :TYPE_FLOAT ->
        validate_float(value, path)

      :TYPE_ENUM ->
        validate_enum(field, value, path)

      integer_type ->
        {min, max} = integer_range(integer_type)
        validate_integer(value, path, min, max)
    end
  end

  def encode(field, value, path) do
    with {:ok, value} <- normalize_encode_value(field, value, path),
         :ok <- validate_normalized_encode(field, value, path) do
      do_encode(field, value, path)
    end
  end

  def decode(field, raw) do
    case field.type do
      :TYPE_DOUBLE ->
        {:ok, Wire.decode_float64(raw)}

      :TYPE_FLOAT ->
        {:ok, Wire.decode_float32(raw)}

      :TYPE_INT64 ->
        {:ok, Wire.signed64(raw)}

      :TYPE_UINT64 ->
        {:ok, raw}

      :TYPE_INT32 ->
        {:ok, Wire.signed32(raw)}

      :TYPE_UINT32 ->
        {:ok, Wire.uint32(raw)}

      :TYPE_FIXED64 ->
        {:ok, Wire.fixed64_u(raw)}

      :TYPE_FIXED32 ->
        {:ok, Wire.fixed32_u(raw)}

      :TYPE_BOOL ->
        {:ok, raw != 0}

      :TYPE_STRING ->
        decode_string(field, raw)

      :TYPE_BYTES ->
        {:ok, raw}

      :TYPE_ENUM ->
        decode_enum(field, raw)

      :TYPE_SFIXED32 ->
        {:ok, Wire.fixed32_s(raw)}

      :TYPE_SFIXED64 ->
        {:ok, Wire.fixed64_s(raw)}

      :TYPE_SINT32 ->
        {:ok, Wire.zigzag32(raw)}

      :TYPE_SINT64 ->
        {:ok, Wire.zigzag(raw)}
    end
  end

  defp default_enum(%{default: default}), do: default

  defp default_enum(%{enum: enum}), do: enum.default

  defp default_enum?(field, value) do
    default = default_enum(field)
    value == default or value == Map.get(field.enum.by_name, default)
  end

  defp decode_enum(field, raw) do
    signed = Wire.signed32(raw)

    case field.enum do
      %{features: %{enum_type: :CLOSED}} = enum ->
        case Map.fetch(enum.by_number, signed) do
          {:ok, name} -> {:ok, name}
          :error -> {:error, {:closed_enum_value, raw}}
        end

      enum ->
        {:ok, Map.get(enum.by_number, signed, signed)}
    end
  end

  defp validate_float(value, _path)
       when is_number(value) or value in [:nan, :infinity, :negative_infinity],
       do: :ok

  defp validate_float(value, path), do: invalid_value(path, :number, value)

  defp validate_string(field, value, path) when is_binary(value) do
    if Features.verify_utf8?(field) and not String.valid?(value) do
      invalid_value(path, :utf8_string, value)
    else
      :ok
    end
  end

  defp validate_string(_field, value, path), do: invalid_value(path, :string, value)

  defp decode_string(field, raw) do
    if Features.verify_utf8?(field) and not String.valid?(raw) do
      Wire.malformed(:invalid_utf8)
    else
      {:ok, raw}
    end
  end

  defp validate_integer(value, path, lo, hi) when is_integer(value) do
    if value >= lo and value <= hi,
      do: :ok,
      else: {:error, {:value_out_of_range, path, lo, hi, value}}
  end

  defp validate_integer(value, path, _lo, _hi), do: invalid_value(path, :integer, value)

  defp validate_enum(field, value, path) when is_atom(value) do
    if Map.has_key?(field.enum.by_name, value) do
      :ok
    else
      {:error, {:unknown_enum_value, path, field.type_name, value}}
    end
  end

  defp validate_enum(field, value, path) when is_integer(value) do
    with :ok <- validate_integer(value, path, @int32_min, @int32_max) do
      case field.enum do
        %{features: %{enum_type: :CLOSED}} = enum ->
          if Map.has_key?(enum.by_number, value),
            do: :ok,
            else: {:error, {:unknown_enum_value, path, field.type_name, value}}

        _enum ->
          :ok
      end
    end
  end

  defp validate_enum(_field, value, path), do: invalid_value(path, :enum, value)

  defp invalid_value(path, expected, value) do
    {:error, {:invalid_value, path, expected, Errors.type_of(value)}}
  end

  defp do_encode(field, value, _path) do
    case field.type do
      :TYPE_STRING ->
        {:ok, [Wire.encode_varint(byte_size(value)), value]}

      :TYPE_BYTES ->
        {:ok, [Wire.encode_varint(byte_size(value)), value]}

      :TYPE_DOUBLE ->
        {:ok, [Wire.encode_float64(value)]}

      :TYPE_FLOAT ->
        {:ok, [Wire.encode_float32(value)]}

      :TYPE_INT64 ->
        {:ok, [Wire.encode_varint(Wire.to_unsigned64(value))]}

      :TYPE_UINT64 ->
        {:ok, [Wire.encode_varint(value)]}

      :TYPE_INT32 ->
        {:ok, [Wire.encode_varint(Wire.to_unsigned64(value))]}

      :TYPE_UINT32 ->
        {:ok, [Wire.encode_varint(value)]}

      :TYPE_FIXED64 ->
        {:ok, [<<value::little-unsigned-64>>]}

      :TYPE_FIXED32 ->
        {:ok, [<<value::little-unsigned-32>>]}

      :TYPE_BOOL ->
        {:ok, [Wire.encode_varint(if(value, do: 1, else: 0))]}

      :TYPE_SFIXED32 ->
        {:ok, [<<value::little-signed-32>>]}

      :TYPE_SFIXED64 ->
        {:ok, [<<value::little-signed-64>>]}

      :TYPE_SINT32 ->
        {:ok, [Wire.encode_varint(bxor(value <<< 1, value >>> 31))]}

      :TYPE_SINT64 ->
        {:ok, [Wire.encode_varint(bxor(value <<< 1, value >>> 63))]}

      :TYPE_ENUM ->
        encode_enum(field, value)
    end
  end

  defp encode_enum(field, value) when is_atom(value) do
    {:ok, [Wire.encode_varint(Wire.to_unsigned64(field.enum.by_name[value]))]}
  end

  defp encode_enum(_field, value) when is_integer(value) do
    {:ok, [Wire.encode_varint(Wire.to_unsigned64(value))]}
  end
end

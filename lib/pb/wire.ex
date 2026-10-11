defmodule PB.Wire do
  @moduledoc false

  import Bitwise

  @max_field_number 0x1FFFFFFF

  # Nesting limit shared by every PB decoder: embedded messages in
  # PB.Runtime.Decoder.Scan, groups below, ProtoJSON and text format.
  @max_decode_depth 100

  # Nested groups recurse here at the wire layer before the decoder's depth check
  # ever runs, so adversarially nested start-group tags need their own guard.
  @max_group_depth @max_decode_depth

  def max_decode_depth, do: @max_decode_depth

  def wire_type(:TYPE_DOUBLE), do: 1
  def wire_type(:TYPE_FLOAT), do: 5
  def wire_type(:TYPE_INT64), do: 0
  def wire_type(:TYPE_UINT64), do: 0
  def wire_type(:TYPE_INT32), do: 0
  def wire_type(:TYPE_FIXED64), do: 1
  def wire_type(:TYPE_FIXED32), do: 5
  def wire_type(:TYPE_BOOL), do: 0
  def wire_type(:TYPE_STRING), do: 2
  def wire_type(:TYPE_MESSAGE), do: 2
  def wire_type(:TYPE_BYTES), do: 2
  def wire_type(:TYPE_UINT32), do: 0
  def wire_type(:TYPE_ENUM), do: 0
  def wire_type(:TYPE_SFIXED32), do: 5
  def wire_type(:TYPE_SFIXED64), do: 1
  def wire_type(:TYPE_SINT32), do: 0
  def wire_type(:TYPE_SINT64), do: 0

  def wire_type(:TYPE_GROUP), do: 3

  def packable_type?(t),
    do:
      t in [
        :TYPE_DOUBLE,
        :TYPE_FLOAT,
        :TYPE_INT64,
        :TYPE_UINT64,
        :TYPE_INT32,
        :TYPE_UINT32,
        :TYPE_FIXED64,
        :TYPE_FIXED32,
        :TYPE_SFIXED64,
        :TYPE_SFIXED32,
        :TYPE_BOOL,
        :TYPE_ENUM,
        :TYPE_SINT32,
        :TYPE_SINT64
      ]

  def validate_field_number(fnum) when fnum >= 1 and fnum <= @max_field_number, do: :ok
  def validate_field_number(_fnum), do: malformed(:invalid_field_number)

  def validate_wire_type(wtype) when wtype in 0..5, do: :ok
  def validate_wire_type(_wtype), do: malformed(:invalid_wire_type)

  def encode_tag(fnum, wtype), do: encode_varint(fnum <<< 3 ||| wtype)

  def encode_varint(v) when v >= 0 and v < 128, do: <<v::8>>

  def encode_varint(v) when v >= 128 do
    <<1::1, v::7, encode_varint(v >>> 7)::binary>>
  end

  def decode_varint(bin), do: decode_varint_acc(bin, 0, 0)

  def decode_tag(bin) do
    with {:ok, value, rest} <- decode_varint(bin),
         size = byte_size(bin) - byte_size(rest),
         <<raw::binary-size(^size), _::binary>> = bin,
         :ok <- validate_canonical_varint(raw, value) do
      {:ok, value, rest}
    end
  end

  defp decode_varint_acc(<<0::1, b::7, rest::binary>>, acc, shift) when shift < 63,
    do: {:ok, acc ||| b <<< shift, rest}

  defp decode_varint_acc(<<0::1, b::7, rest::binary>>, acc, 63) when b <= 1,
    do: {:ok, acc ||| b <<< 63, rest}

  defp decode_varint_acc(<<0::1, _b::7, _rest::binary>>, _acc, 63),
    do: malformed(:varint_overflow)

  defp decode_varint_acc(<<1::1, b::7, rest::binary>>, acc, shift) when shift < 63,
    do: decode_varint_acc(rest, acc ||| b <<< shift, shift + 7)

  defp decode_varint_acc(<<1::1, _b::7, _rest::binary>>, _acc, _shift),
    do: malformed(:varint_overflow)

  defp decode_varint_acc(<<>>, _acc, _shift), do: malformed(:truncated_varint)

  def read_wire(0, bin), do: decode_varint(bin)
  def read_wire(1, <<v::binary-size(8), r::binary>>), do: {:ok, v, r}
  def read_wire(1, _bin), do: malformed(:truncated_fixed64)

  def read_wire(2, bin) do
    with {:ok, len, rest} <- decode_varint(bin) do
      read_length_delimited(len, rest)
    end
  end

  def read_wire(3, _bin),
    do: malformed(:unsupported_group)

  def read_wire(4, _bin),
    do: malformed(:unsupported_group)

  def read_wire(5, <<v::binary-size(4), r::binary>>), do: {:ok, v, r}
  def read_wire(5, _bin), do: malformed(:truncated_fixed32)
  def read_wire(_wtype, _bin), do: malformed(:invalid_wire_type)

  defp validate_canonical_varint(raw, value) do
    if raw == encode_varint(value) do
      :ok
    else
      malformed(:noncanonical_varint)
    end
  end

  def read_unknown_field(field_number, wire_type, bin) do
    read_wire_raw(field_number, wire_type, bin)
  end

  def read_message_field(_field_number, :length_prefixed, bin) do
    with {:ok, raw_body, rest} <- read_wire_raw(2, bin),
         {:ok, body, <<>>} <- read_wire(2, raw_body) do
      {:ok, body, raw_body, rest}
    end
  end

  def read_message_field(field_number, :delimited, bin)
      when is_integer(field_number) and field_number > 0 do
    read_group_field(field_number, bin)
  end

  def encode_message_value(field_number, :delimited, body) do
    [body, encode_tag(field_number, 4)]
  end

  def encode_message_value(_field_number, :length_prefixed, body) do
    [encode_varint(IO.iodata_length(body)), body]
  end

  def read_wire_raw(wtype, bin), do: read_wire_raw(nil, wtype, bin)

  def read_wire_raw(_field_number, 0, bin) do
    with {:ok, _value, rest} <- decode_varint(bin) do
      size = byte_size(bin) - byte_size(rest)
      <<raw::binary-size(^size), _::binary>> = bin
      {:ok, raw, rest}
    end
  end

  def read_wire_raw(_field_number, 1, <<raw::binary-size(8), rest::binary>>),
    do: {:ok, raw, rest}

  def read_wire_raw(_field_number, 1, _bin), do: malformed(:truncated_fixed64)

  def read_wire_raw(_field_number, 2, bin) do
    with {:ok, len, rest_after_len} <- decode_varint(bin),
         {:ok, _value, rest} <- read_length_delimited(len, rest_after_len) do
      size = byte_size(bin) - byte_size(rest)
      <<raw::binary-size(^size), _::binary>> = bin
      {:ok, raw, rest}
    end
  end

  def read_wire_raw(field_number, 3, bin) when is_integer(field_number) do
    with {:ok, _body, raw, rest} <- read_group_field(field_number, bin) do
      {:ok, raw, rest}
    end
  end

  def read_wire_raw(_field_number, 3, _bin),
    do: malformed(:unsupported_group)

  def read_wire_raw(_field_number, 4, _bin),
    do: malformed(:unexpected_end_group)

  def read_wire_raw(_field_number, 5, <<raw::binary-size(4), rest::binary>>),
    do: {:ok, raw, rest}

  def read_wire_raw(_field_number, 5, _bin), do: malformed(:truncated_fixed32)
  def read_wire_raw(_field_number, _wtype, _bin), do: malformed(:invalid_wire_type)

  def skip_wire(0, bin) do
    with {:ok, _value, rest} <- decode_varint(bin), do: {:ok, rest}
  end

  def skip_wire(1, <<_::64, r::binary>>), do: {:ok, r}
  def skip_wire(1, _bin), do: malformed(:truncated_fixed64)

  def skip_wire(2, bin) do
    with {:ok, len, rest} <- decode_varint(bin),
         {:ok, _value, rest} <- read_length_delimited(len, rest) do
      {:ok, rest}
    end
  end

  def skip_wire(3, _bin),
    do: malformed(:unsupported_group)

  def skip_wire(4, _bin),
    do: malformed(:unsupported_group)

  def skip_wire(5, <<_::32, r::binary>>), do: {:ok, r}
  def skip_wire(5, _bin), do: malformed(:truncated_fixed32)
  def skip_wire(_wtype, _bin), do: malformed(:invalid_wire_type)

  defp read_group_field(field_number, bin), do: read_group_field(field_number, bin, 0)

  defp read_group_field(_field_number, _bin, depth) when depth >= @max_group_depth do
    malformed(:max_group_depth_exceeded)
  end

  defp read_group_field(field_number, bin, depth) do
    read_group_body(field_number, bin, [], depth)
  end

  defp read_group_body(_field_number, <<>>, _acc, _depth), do: malformed(:truncated_group)

  defp read_group_body(field_number, bin, acc, depth) do
    with {:ok, tag_val, rest_after_tag} <- decode_tag(bin),
         fnum = tag_val >>> 3,
         wtype = tag_val &&& 0x07,
         :ok <- validate_field_number(fnum),
         :ok <- validate_wire_type(wtype) do
      tag_size = byte_size(bin) - byte_size(rest_after_tag)
      <<tag_raw::binary-size(^tag_size), _::binary>> = bin

      cond do
        wtype == 4 and fnum == field_number ->
          body = IO.iodata_to_binary(Enum.reverse(acc))
          {:ok, body, IO.iodata_to_binary([body, tag_raw]), rest_after_tag}

        wtype == 4 ->
          malformed(:unexpected_end_group, %{
            expected_field_number: field_number,
            got_field_number: fnum
          })

        wtype == 3 ->
          with {:ok, _body, raw, rest} <- read_group_field(fnum, rest_after_tag, depth + 1) do
            read_group_body(field_number, rest, [raw, tag_raw | acc], depth)
          end

        true ->
          with {:ok, raw, rest} <- read_wire_raw(fnum, wtype, rest_after_tag) do
            read_group_body(field_number, rest, [raw, tag_raw | acc], depth)
          end
      end
    end
  end

  def read_length_delimited(len, rest) when len <= byte_size(rest) do
    <<value::binary-size(^len), rest::binary>> = rest
    {:ok, value, rest}
  end

  def read_length_delimited(_len, _rest), do: malformed(:truncated_length_delimited)

  def encode_float64(:infinity), do: <<0, 0, 0, 0, 0, 0, 240, 127>>
  def encode_float64(:negative_infinity), do: <<0, 0, 0, 0, 0, 0, 240, 255>>
  def encode_float64(:nan), do: <<0, 0, 0, 0, 0, 0, 248, 127>>
  def encode_float64(v), do: <<v::little-float-64>>

  def encode_float32(:infinity), do: <<0, 0, 128, 127>>
  def encode_float32(:negative_infinity), do: <<0, 0, 128, 255>>
  def encode_float32(:nan), do: <<0, 0, 192, 127>>
  def encode_float32(v), do: <<v::little-float-32>>

  def decode_float64(<<0, 0, 0, 0, 0, 0, 240, 127>>), do: :infinity
  def decode_float64(<<0, 0, 0, 0, 0, 0, 240, 255>>), do: :negative_infinity

  def decode_float64(<<_::binary-size(8)>> = raw) do
    <<i::little-unsigned-64>> = raw
    exp = i >>> 52 &&& 0x7FF
    frac = i &&& 0xFFFFFFFFFFFFF

    if exp == 0x7FF and frac != 0 do
      :nan
    else
      <<v::little-float-64>> = raw
      v
    end
  end

  def decode_float32(<<0, 0, 128, 127>>), do: :infinity
  def decode_float32(<<0, 0, 128, 255>>), do: :negative_infinity

  def decode_float32(<<_::binary-size(4)>> = raw) do
    <<i::little-unsigned-32>> = raw
    exp = i >>> 23 &&& 0xFF
    frac = i &&& 0x7FFFFF

    if exp == 0xFF and frac != 0 do
      :nan
    else
      <<v::little-float-32>> = raw
      v
    end
  end

  def signed32(raw) do
    <<v::signed-32>> = <<raw::32>>
    v
  end

  def signed64(raw) do
    <<v::signed-64>> = <<raw::64>>
    v
  end

  def fixed32_u(<<v::little-unsigned-32>>), do: v
  def fixed32_s(<<v::little-signed-32>>), do: v
  def fixed64_u(<<v::little-unsigned-64>>), do: v
  def fixed64_s(<<v::little-signed-64>>), do: v

  def uint32(raw), do: raw &&& 0xFFFFFFFF
  def to_unsigned64(v) when v >= 0, do: v
  def to_unsigned64(v), do: v &&& 0xFFFFFFFFFFFFFFFF
  def zigzag(raw), do: bxor(raw >>> 1, -(raw &&& 1))
  def zigzag32(raw), do: raw |> uint32() |> zigzag()

  def malformed(reason, details \\ %{}), do: {:error, {:malformed, reason, details}}
end

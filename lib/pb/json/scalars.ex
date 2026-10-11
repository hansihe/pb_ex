defmodule PB.JSON.Scalars do
  @moduledoc false

  # Pure value transforms used by Encoder, Decoder, and the WKT module.
  # No dispatch logic here — each function operates on already-classified
  # scalar values.

  alias PB.JSON.Errors
  alias PB.Runtime.Scalar
  alias PB.Schema.Features

  # IEEE 754 doubles represent every integer only up to 2^53. A JSON *number*
  # in float syntax beyond this magnitude has already lost precision by the time
  # OTP `:json` hands it to us, so 64-bit ints beyond the safe range must be sent
  # as JSON strings (the canonical ProtoJSON form).
  @max_safe_int 0x1FFFFFFFFFFFFF

  # IEEE 754 single-precision finite maximum (~ 3.4028235e38). Finite values
  # beyond this magnitude do not survive a TYPE_FLOAT round-trip and are
  # rejected per ProtoJSON.
  @float32_max 3.4028234663852886e38

  @null_value :"google.protobuf.NullValue"

  # ── Float encoding ───────────────────────────────────────────────────
  def encode_float(:nan), do: "NaN"
  def encode_float(:infinity), do: "Infinity"
  def encode_float(:negative_infinity), do: "-Infinity"
  def encode_float(v) when is_number(v), do: v

  def encode_float(v) do
    Errors.raise!(:invalid_value, "expected number", details: %{expected: :number, got: v})
  end

  # ── Float decoding ───────────────────────────────────────────────────
  def decode_float!(v, type) do
    parsed = parse_float!(v)

    cond do
      type == :TYPE_FLOAT and is_number(parsed) and abs(parsed) > @float32_max ->
        Errors.raise!(:value_out_of_range, parsed,
          details: %{type: type, max: @float32_max, value: parsed}
        )

      true ->
        parsed
    end
  end

  defp parse_float!("NaN"), do: :nan
  defp parse_float!("Infinity"), do: :infinity
  defp parse_float!("-Infinity"), do: :negative_infinity
  defp parse_float!(v) when is_number(v), do: v

  defp parse_float!(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> f
      _ -> Errors.raise!(:invalid_value, "invalid number", details: %{got: v})
    end
  end

  defp parse_float!(v) do
    Errors.raise!(:invalid_value, "expected number", details: %{expected: :number, got: v})
  end

  # ── Integer decoding ─────────────────────────────────────────────────
  def decode_int!(v, lo, hi) when is_integer(v), do: check_range!(v, lo, hi)

  def decode_int!(v, lo, hi) when is_float(v), do: int_from_float!(v, lo, hi)

  def decode_int!(v, lo, hi) when is_binary(v) do
    parse_int!(v, lo, hi)
  end

  def decode_int!(v, _lo, _hi) do
    Errors.raise!(:invalid_value, "expected integer", details: %{expected: :integer, got: v})
  end

  def parse_int!(v, lo, hi) do
    case Integer.parse(v) do
      {n, ""} ->
        check_range!(n, lo, hi)

      _ ->
        case Float.parse(v) do
          {f, ""} ->
            int_from_float!(f, lo, hi)

          _ ->
            Errors.raise!(:invalid_value, "invalid integer", details: %{got: v})
        end
    end
  end

  def check_range!(n, lo, hi) when n >= lo and n <= hi, do: n

  def check_range!(n, lo, hi) do
    Errors.raise!(:value_out_of_range, n, details: %{min: lo, max: hi, value: n})
  end

  # A JSON number for an integer field. Reject fractional values; report
  # out-of-range like the integer-literal path; and reject 64-bit values beyond
  # the 2^53 safe range, where the float can no longer carry the exact integer.
  defp int_from_float!(v, lo, hi) do
    int = trunc(v)

    cond do
      int * 1.0 != v ->
        Errors.raise!(:invalid_value, "non-integer numeric value", details: %{got: v})

      int < lo or int > hi ->
        check_range!(int, lo, hi)

      int < -@max_safe_int or int > @max_safe_int ->
        Errors.raise!(
          :invalid_value,
          "64-bit integer beyond the 2^53 safe range must be a JSON string to preserve precision",
          details: %{got: v}
        )

      true ->
        int
    end
  end

  # ── Base64 ───────────────────────────────────────────────────────────
  def decode_base64!(v) do
    cond do
      match = try_decode_b64(v, &Base.decode64/2) ->
        match

      match = try_decode_b64(v, &Base.url_decode64/2) ->
        match

      true ->
        Errors.raise!(:invalid_value, "invalid base64", details: %{expected: :base64, got: v})
    end
  end

  defp try_decode_b64(v, fun) do
    with :error <- fun.(v, padding: true),
         :error <- fun.(v, padding: false) do
      false
    else
      {:ok, b} -> b
    end
  end

  # ── Enum encoding ────────────────────────────────────────────────────
  def encode_enum(schema, field, value, opts) do
    cond do
      field.type_name == @null_value -> encode_null_value_enum!(field, value)
      opts.enums_as_ints -> enum_to_int(schema, field, value)
      is_atom(value) -> Atom.to_string(value)
      is_integer(value) -> enum_int_to_name(schema, field, value)
      true -> Errors.raise!(:invalid_enum_value, value, details: %{enum: field.type_name})
    end
  end

  def encode_null_value_enum!(_field, value) when value in [:NULL_VALUE, 0], do: nil

  def encode_null_value_enum!(field, value) do
    Errors.raise!(:invalid_enum_value, value, details: %{enum: field.type_name})
  end

  defp enum_to_int(schema, field, value) when is_integer(value) do
    case schema.enums[field.type_name] do
      %{by_number: by_number} = enum ->
        if Features.closed_enum?(enum) and not Map.has_key?(by_number, value) do
          Errors.raise!(:invalid_enum_value, value, details: %{enum: field.type_name})
        else
          value
        end

      _enum ->
        value
    end
  end

  defp enum_to_int(schema, field, value) when is_atom(value) do
    case schema.enums[field.type_name] do
      nil -> 0
      enum -> Map.get(enum.by_name, value, 0)
    end
  end

  defp enum_int_to_name(schema, field, value) do
    case schema.enums[field.type_name] do
      nil ->
        value

      enum ->
        case Map.get(enum.by_number, value) do
          nil ->
            if Features.closed_enum?(enum) do
              Errors.raise!(:invalid_enum_value, value, details: %{enum: field.type_name})
            else
              value
            end

          name ->
            Atom.to_string(name)
        end
    end
  end

  # ── Enum decoding ────────────────────────────────────────────────────
  # Returns the decoded value, the atom `:skip` (only for unknown enum
  # strings under `unknown_fields: :ignore`), or raises.
  def decode_enum(schema, field, value, _opts) when is_integer(value) do
    enum = schema.enums[field.type_name]

    cond do
      enum == nil ->
        value

      name = Map.get(enum.by_number, value) ->
        name

      Features.closed_enum?(enum) ->
        Errors.raise!(:invalid_enum_value, value, details: %{enum: field.type_name})

      true ->
        value
    end
  end

  def decode_enum(schema, field, value, opts) when is_binary(value) do
    case schema.enums[field.type_name] do
      nil ->
        unknown_enum_string(field, value, opts)

      enum ->
        # All known value names were already interned by compile/1, so
        # to_existing_atom rejects unknown names without polluting the atom table.
        atom =
          try do
            {:ok, String.to_existing_atom(value)}
          rescue
            ArgumentError -> :unknown
          end

        case atom do
          {:ok, name} ->
            case enum.by_name[name] do
              nil -> unknown_enum_string(field, value, opts)
              _ -> name
            end

          :unknown ->
            unknown_enum_string(field, value, opts)
        end
    end
  end

  def decode_enum(_schema, field, value, _opts) do
    Errors.raise!(:invalid_enum_value, value,
      details: %{expected: [:string, :integer], enum: field.type_name}
    )
  end

  # ProtoJSON `unknown_fields: :ignore`: an unknown enum string value is dropped
  # rather than erroring. Returns `:skip`; callers in the singular field
  # path leave the field absent, list/map paths filter the element out.
  defp unknown_enum_string(field, value, opts) do
    if opts.unknown_fields == :ignore do
      :skip
    else
      Errors.raise!(:invalid_enum_value, value, details: %{enum: field.type_name})
    end
  end

  # ── JSON key naming ──────────────────────────────────────────────────

  # protoc's snake_case -> lowerCamelCase: each '_' eats itself and
  # uppercases the next ASCII lowercase letter. Other characters pass
  # through unchanged.
  def camel_case(name) do
    name
    |> :erlang.binary_to_list()
    |> camel_chars(false)
    |> :erlang.list_to_binary()
  end

  defp camel_chars([], _upper), do: []
  defp camel_chars([?_ | rest], _upper), do: camel_chars(rest, true)

  defp camel_chars([c | rest], true) when c >= ?a and c <= ?z,
    do: [c - 32 | camel_chars(rest, false)]

  defp camel_chars([c | rest], _upper), do: [c | camel_chars(rest, false)]

  # ── JSON object key stringification ──────────────────────────────────
  def stringify_key(k) when is_binary(k), do: k
  def stringify_key(k) when is_atom(k), do: Atom.to_string(k)

  def stringify_key(k) do
    Errors.raise!(:malformed_json, "expected JSON object key",
      details: %{expected: [:string, :atom], got: k}
    )
  end

  # ── Map key parsing (decode) ─────────────────────────────────────────
  def parse_map_key(field, key) do
    case field.type do
      :TYPE_STRING ->
        key

      :TYPE_BOOL ->
        case key do
          "true" -> true
          "false" -> false
          _ -> Errors.raise!(:invalid_value, "invalid bool map key", details: %{got: key})
        end

      integer_type ->
        {min, max} = Scalar.integer_range(integer_type)
        parse_int!(key, min, max)
    end
  end

  # ── Map key stringification (encode) ─────────────────────────────────
  def map_key_to_string(k) when is_binary(k), do: k
  def map_key_to_string(true), do: "true"
  def map_key_to_string(false), do: "false"
  def map_key_to_string(k) when is_integer(k), do: Integer.to_string(k)
  def map_key_to_string(k) when is_atom(k), do: Atom.to_string(k)

  def map_key_to_string(k) do
    Errors.raise!(:invalid_value, "invalid JSON map key",
      details: %{expected: :scalar_map_key, got: k}
    )
  end
end

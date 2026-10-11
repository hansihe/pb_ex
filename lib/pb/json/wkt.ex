defmodule PB.JSON.WKT do
  @moduledoc false

  # Single source of truth for special-cased message names in ProtoJSON.
  # Encoder and Decoder both consult `lookup/1`; nothing else in the
  # pipeline hardcodes WKT names.
  #
  # Each entry describes one well-known type:
  #
  #   * `:enc` / `:dec` — encoder/decoder. Signature
  #     `(data_or_json, schema, opts, callbacks)`. `callbacks` is a
  #     `%{encode_message: fun, decode_message: fun}` bag used by Any to
  #     re-enter the top-level pipeline (avoids a hard cycle into
  #     Encoder/Decoder).
  #
  #   * `:any` — `:wrapped` means "wrap under a `"value"` field when
  #     embedded in an Any"; absent means "flat-merge with `@type`".
  #     Wrappers and the message-shaped WKTs all use `:wrapped`.
  #
  #   * `:null` — optional `{:bind, decoded}` if a JSON `null` on a
  #     singular field of this type should bind the decoded sentinel
  #     instead of leaving the field absent. Currently Value and
  #     NullValue.

  alias PB.JSON.{Errors, Scalars}
  alias PB.WellKnownTypes.{Any, Spec}

  @field_mask :"google.protobuf.FieldMask"
  @timestamp :"google.protobuf.Timestamp"
  @duration :"google.protobuf.Duration"
  @value :"google.protobuf.Value"
  @struct :"google.protobuf.Struct"
  @list_value :"google.protobuf.ListValue"
  @any :"google.protobuf.Any"
  @null_value :"google.protobuf.NullValue"

  # Canonical ProtoJSON accepts any type URL whose final path segment is the
  # fully-qualified message name (`type.googleapis.com/<fqn>` is the common
  # form, but the host is arbitrary and may carry extra path segments). The URL
  # must contain at least one `/`. The `@type` string is round-tripped verbatim
  # from/to the Any's `type_url` field; only the trailing `<fqn>` is parsed out
  # to locate the embedded message type, so payloads from other conformant
  # implementations resolve regardless of host.

  # Range/precision constants come from the shared proto-map spec so this
  # ProtoJSON backend and the native time adapter cannot drift.
  @unix_epoch_gregorian Spec.unix_epoch_gregorian()
  @nanos_max Spec.nanos_max()

  # ProtoJSON wrapper messages: each carries a single `value` field and is
  # serialised as that field's bare scalar. The encoder and decoder handle
  # them (`enc: :wrapper`) with the same scalar code as any other field.
  @wrapper_types [
    :"google.protobuf.DoubleValue",
    :"google.protobuf.FloatValue",
    :"google.protobuf.Int64Value",
    :"google.protobuf.UInt64Value",
    :"google.protobuf.Int32Value",
    :"google.protobuf.UInt32Value",
    :"google.protobuf.BoolValue",
    :"google.protobuf.StringValue",
    :"google.protobuf.BytesValue"
  ]

  wrapper_table = Map.new(@wrapper_types, &{&1, %{enc: :wrapper, dec: :wrapper, any: :wrapped}})

  @wkts %{
          @field_mask => %{enc: :field_mask, dec: :field_mask, any: :wrapped},
          @timestamp => %{enc: :timestamp, dec: :timestamp, any: :wrapped},
          @duration => %{enc: :duration, dec: :duration, any: :wrapped},
          @struct => %{enc: :struct, dec: :struct, any: :wrapped},
          @list_value => %{enc: :list_value, dec: :list_value, any: :wrapped},
          @value => %{
            enc: :value,
            dec: :value,
            any: :wrapped,
            null: {:bind, %{kind: {:null_value, :NULL_VALUE}}}
          },
          @any => %{enc: :any, dec: :any, any: :wrapped},
          @null_value => %{null: {:bind, :NULL_VALUE}}
        }
        |> Map.merge(wrapper_table)

  # ── Public projections ───────────────────────────────────────────────

  def lookup(name), do: Map.get(@wkts, name)

  def any_wrapped?(name), do: match?(%{any: :wrapped}, lookup(name))

  def null_binding(nil), do: nil
  def null_binding(name), do: get_in(@wkts, [name, :null])

  @doc """
  Run a WKT encoder. `entry` is the value returned by `lookup/1`.
  `callbacks` carries the back-edge into the main pipeline for Any.
  """
  def encode(entry, data, schema, opts, callbacks) do
    case entry.enc do
      :field_mask -> encode_field_mask(data)
      :timestamp -> encode_timestamp(data)
      :duration -> encode_duration(data)
      :value -> encode_value(data)
      :struct -> encode_struct(data)
      :list_value -> encode_list_value(data)
      :any -> encode_any(data, schema, opts, callbacks)
    end
  end

  def decode(entry, json, schema, opts, callbacks, depth) do
    case entry.dec do
      :field_mask -> decode_field_mask(json)
      :timestamp -> decode_timestamp(json)
      :duration -> decode_duration(json)
      :value -> decode_value(json, depth, callbacks)
      :struct -> decode_struct(json, depth, callbacks)
      :list_value -> decode_list_value(json, depth, callbacks)
      :any -> decode_any(json, schema, opts, callbacks)
    end
  end

  # ── FieldMask ────────────────────────────────────────────────────────

  defp encode_field_mask(%{paths: paths}) when is_list(paths),
    do: paths |> Enum.map_join(",", &snake_to_camel_path/1)

  defp encode_field_mask(%{paths: paths}) do
    Errors.raise!(:invalid_value, "expected FieldMask paths to be a list",
      details: %{expected: :list, got: paths}
    )
  end

  defp encode_field_mask(data) when is_map(data), do: ""

  defp encode_field_mask(data) do
    Errors.raise!(:invalid_value, "expected FieldMask message",
      details: %{expected: :map, got: data}
    )
  end

  defp decode_field_mask(""), do: %{paths: []}

  defp decode_field_mask(value) when is_binary(value) do
    paths = value |> String.split(",") |> Enum.map(&camel_to_snake_path/1)
    %{paths: paths}
  end

  defp decode_field_mask(value) do
    Errors.raise!(:invalid_value, "expected FieldMask string",
      details: %{expected: :string, got: value}
    )
  end

  defp snake_to_camel_path(path) when is_binary(path) do
    case snake_to_camel_chars(:binary.bin_to_list(path), false) do
      {:ok, chars} ->
        :binary.list_to_bin(chars)

      :error ->
        Errors.raise!(:invalid_value, "invalid FieldMask path", details: %{got: path})
    end
  end

  defp snake_to_camel_path(path) do
    Errors.raise!(:invalid_value, "invalid FieldMask path",
      details: %{expected: :string, got: path}
    )
  end

  # Walks a snake_case proto path and emits lowerCamelCase. `_<lowercase>`
  # is the only valid form of an underscore; uppercase letters in the
  # source are rejected (per ProtoJSON spec for `FieldMask`).
  defp snake_to_camel_chars([], true), do: :error
  defp snake_to_camel_chars([], false), do: {:ok, []}
  defp snake_to_camel_chars([?_ | _rest], true), do: :error
  defp snake_to_camel_chars([?_ | rest], false), do: snake_to_camel_chars(rest, true)

  defp snake_to_camel_chars([c | rest], true) when c >= ?a and c <= ?z do
    case snake_to_camel_chars(rest, false) do
      {:ok, tail} -> {:ok, [c - 32 | tail]}
      :error -> :error
    end
  end

  defp snake_to_camel_chars([_c | _rest], true), do: :error

  defp snake_to_camel_chars([c | rest], false)
       when (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9) or c == ?. do
    case snake_to_camel_chars(rest, false) do
      {:ok, tail} -> {:ok, [c | tail]}
      :error -> :error
    end
  end

  defp snake_to_camel_chars([_c | _rest], false), do: :error

  defp camel_to_snake_path(path) when is_binary(path) do
    case camel_to_snake_chars(:binary.bin_to_list(path)) do
      {:ok, chars} ->
        :binary.list_to_bin(chars)

      :error ->
        Errors.raise!(:invalid_value, "invalid FieldMask path", details: %{got: path})
    end
  end

  # Walks a lowerCamelCase JSON path and emits snake_case. Underscores
  # in the source are rejected (would not survive the snake->camel->snake
  # round-trip).
  defp camel_to_snake_chars([]), do: {:ok, []}
  defp camel_to_snake_chars([?_ | _rest]), do: :error

  defp camel_to_snake_chars([c | rest]) when c >= ?A and c <= ?Z do
    case camel_to_snake_chars(rest) do
      {:ok, tail} -> {:ok, [?_, c + 32 | tail]}
      :error -> :error
    end
  end

  defp camel_to_snake_chars([c | rest]) do
    case camel_to_snake_chars(rest) do
      {:ok, tail} -> {:ok, [c | tail]}
      :error -> :error
    end
  end

  # ── Duration ─────────────────────────────────────────────────────────

  defp encode_duration(%{} = data) do
    seconds = Map.get(data, :seconds, 0)
    nanos = Map.get(data, :nanos, 0)

    case Spec.validate_duration(seconds, nanos) do
      :ok ->
        sign = if seconds < 0 or nanos < 0, do: "-", else: ""
        sign <> Integer.to_string(abs(seconds)) <> format_fractional(abs(nanos)) <> "s"

      {:error, reason} ->
        raise_time_error!(reason, "Duration", seconds, nanos)
    end
  end

  defp encode_duration(data) do
    Errors.raise!(:invalid_value, "expected Duration message",
      details: %{expected: :map, got: data}
    )
  end

  defp decode_duration(input) when is_binary(input) do
    case parse_duration(input) do
      {:ok, seconds, nanos} ->
        case Spec.validate_duration(seconds, nanos) do
          :ok -> %{seconds: seconds, nanos: nanos}
          {:error, reason} -> raise_time_error!(reason, "Duration", seconds, nanos)
        end

      :error ->
        Errors.raise!(:invalid_value, "invalid Duration", details: %{got: input})
    end
  end

  defp decode_duration(value) do
    Errors.raise!(:invalid_value, "expected Duration string",
      details: %{expected: :string, got: value}
    )
  end

  defp parse_duration(input) do
    {sign, rest} =
      case input do
        "-" <> r -> {-1, r}
        r -> {1, r}
      end

    case String.split(rest, "s") do
      [body, ""] -> parse_duration_body(body, sign)
      _ -> :error
    end
  end

  defp parse_duration_body(body, sign) do
    case String.split(body, ".") do
      [secs] ->
        with {:ok, s} <- parse_unsigned(secs) do
          {:ok, sign * s, 0}
        end

      [secs, frac] when frac != "" ->
        with {:ok, s} <- parse_unsigned(secs),
             {:ok, n} <- parse_fractional_nanos(frac) do
          {:ok, sign * s, sign * n}
        end

      _ ->
        :error
    end
  end

  # ── Timestamp ────────────────────────────────────────────────────────

  defp encode_timestamp(%{} = data) do
    seconds = Map.get(data, :seconds, 0)
    nanos = Map.get(data, :nanos, 0)

    case Spec.validate_timestamp(seconds, nanos) do
      :ok ->
        {{y, mo, d}, {h, mi, se}} =
          :calendar.gregorian_seconds_to_datetime(seconds + @unix_epoch_gregorian)

        IO.iodata_to_binary([
          :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B", [y, mo, d, h, mi, se]),
          format_fractional(nanos),
          "Z"
        ])

      {:error, reason} ->
        raise_time_error!(reason, "Timestamp", seconds, nanos)
    end
  end

  defp encode_timestamp(data) do
    Errors.raise!(:invalid_value, "expected Timestamp message",
      details: %{expected: :map, got: data}
    )
  end

  defp decode_timestamp(input) when is_binary(input) do
    case parse_timestamp(input) do
      {:ok, seconds, nanos} ->
        case Spec.validate_timestamp(seconds, nanos) do
          :ok -> %{seconds: seconds, nanos: nanos}
          {:error, reason} -> raise_time_error!(reason, "Timestamp", seconds, nanos)
        end

      :error ->
        Errors.raise!(:invalid_value, "invalid Timestamp", details: %{got: input})
    end
  end

  defp decode_timestamp(value) do
    Errors.raise!(:invalid_value, "expected Timestamp string",
      details: %{expected: :string, got: value}
    )
  end

  # RFC 3339: `YYYY-MM-DDTHH:MM:SS[.fff..]<tz>` where tz is `Z` or `+/-HH:MM`.
  defp parse_timestamp(input) do
    with {:ok, y, rest} <- take_digits(input, 4),
         {:ok, ?-, rest} <- take_char(rest),
         {:ok, mo, rest} <- take_digits(rest, 2),
         {:ok, ?-, rest} <- take_char(rest),
         {:ok, d, rest} <- take_digits(rest, 2),
         {:ok, ?T, rest} <- take_char(rest),
         {:ok, h, rest} <- take_digits(rest, 2),
         {:ok, ?:, rest} <- take_char(rest),
         {:ok, mi, rest} <- take_digits(rest, 2),
         {:ok, ?:, rest} <- take_char(rest),
         {:ok, se, rest} <- take_digits(rest, 2),
         {:ok, nanos, rest} <- take_optional_fractional(rest),
         {:ok, offset_seconds} <- parse_timezone(rest),
         true <- :calendar.valid_date({y, mo, d}),
         # Allow second=60 to accept the leap-second form `23:59:60`. The
         # conformance suite expects it to normalise to `00:00:00` of the
         # next minute, which :calendar.datetime_to_gregorian_seconds/1
         # does implicitly. The proto then carries the smeared UTC instant.
         true <- h <= 23 and mi <= 59 and se <= 60 do
      local_unix = :calendar.datetime_to_gregorian_seconds({{y, mo, d}, {h, mi, se}})
      seconds = local_unix - @unix_epoch_gregorian - offset_seconds
      {:ok, seconds, nanos}
    else
      _ -> :error
    end
  end

  defp parse_timezone("Z"), do: {:ok, 0}

  defp parse_timezone(<<sign, rest::binary>>) when sign == ?+ or sign == ?- do
    with {:ok, h, rest} <- take_digits(rest, 2),
         {:ok, ?:, rest} <- take_char(rest),
         {:ok, mi, ""} <- take_digits(rest, 2),
         true <- h <= 23 and mi <= 59 do
      total = h * 3600 + mi * 60
      {:ok, if(sign == ?+, do: total, else: -total)}
    else
      _ -> :error
    end
  end

  defp parse_timezone(_), do: :error

  # ── Value / Struct / ListValue ───────────────────────────────────────

  # `google.protobuf.Value` carries a oneof `kind` whose members map to
  # JSON null, number, string, bool, object (Struct), and array
  # (ListValue). PB represents the message as `%{kind: {member,
  # inner}}`; an empty kind encodes as JSON null.
  defp encode_value(%{kind: {:null_value, v}}) when v in [:NULL_VALUE, 0, nil], do: nil

  defp encode_value(%{kind: {:null_value, v}}) do
    Errors.raise!(:invalid_enum_value, v, details: %{enum: :"google.protobuf.NullValue"})
  end

  defp encode_value(%{kind: {:bool_value, b}}) when is_boolean(b), do: b
  defp encode_value(%{kind: {:string_value, s}}) when is_binary(s), do: s
  defp encode_value(%{kind: {:number_value, n}}), do: encode_value_number(n)
  defp encode_value(%{kind: {:struct_value, s}}), do: encode_struct(s)
  defp encode_value(%{kind: {:list_value, lv}}), do: encode_list_value(lv)
  defp encode_value(%{kind: nil}), do: nil

  defp encode_value(%{} = data) when not is_struct(data) and map_size(data) == 0,
    do: nil

  defp encode_value(%{kind: {member, _}}) do
    Errors.raise!(:invalid_value, "invalid Value kind member",
      details: %{
        expected: [
          :null_value,
          :bool_value,
          :number_value,
          :string_value,
          :struct_value,
          :list_value
        ],
        got: member
      }
    )
  end

  defp encode_value(data) do
    Errors.raise!(:invalid_value, "expected Value message", details: %{expected: :map, got: data})
  end

  # Value.number_value is a TYPE_DOUBLE; per ProtoJSON, non-finite
  # numbers in a Value are an error on the JSON-output side (JSON has no
  # NaN/Inf).
  defp encode_value_number(v) when v in [:nan, :infinity, :negative_infinity] do
    Errors.raise!(:invalid_value, "Value cannot represent non-finite number", details: %{got: v})
  end

  defp encode_value_number(v) when is_number(v), do: v

  defp encode_value_number(v) do
    Errors.raise!(:invalid_value, "expected number", details: %{expected: :number, got: v})
  end

  defp decode_value(nil, _depth, _callbacks), do: %{kind: {:null_value, :NULL_VALUE}}
  defp decode_value(true, _depth, _callbacks), do: %{kind: {:bool_value, true}}
  defp decode_value(false, _depth, _callbacks), do: %{kind: {:bool_value, false}}
  defp decode_value(n, _depth, _callbacks) when is_number(n), do: %{kind: {:number_value, n}}
  defp decode_value(s, _depth, _callbacks) when is_binary(s), do: %{kind: {:string_value, s}}

  defp decode_value(list, depth, callbacks) when is_list(list) do
    %{kind: {:list_value, decode_list_value(list, callbacks.descend.(depth), callbacks)}}
  end

  defp decode_value(map, depth, callbacks) when is_map(map) do
    %{kind: {:struct_value, decode_struct(map, callbacks.descend.(depth), callbacks)}}
  end

  # `google.protobuf.Struct` is `map<string, Value>` serialised as a JSON
  # object. Empty Struct encodes to `{}`.
  defp encode_struct(%{fields: nil}), do: %{}

  defp encode_struct(%{fields: fields}) when is_map(fields) and not is_struct(fields) do
    Map.new(fields, fn {k, v} -> {struct_key!(k), encode_value(v)} end)
  end

  defp encode_struct(%{fields: fields}) do
    Errors.raise!(:invalid_value, "expected Struct fields to be a map",
      details: %{expected: :map, got: fields}
    )
  end

  defp encode_struct(%{} = data) when not is_struct(data), do: %{}

  defp encode_struct(data) do
    Errors.raise!(:invalid_value, "expected Struct message",
      details: %{expected: :map, got: data}
    )
  end

  defp struct_key!(k) when is_binary(k), do: k

  defp struct_key!(k) do
    Errors.raise!(:invalid_value, "Struct keys must be strings",
      details: %{expected: :string, got: k}
    )
  end

  defp decode_struct(json, depth, callbacks) when is_map(json) do
    fields =
      Map.new(json, fn {k, v} ->
        {Scalars.stringify_key(k), decode_value(v, depth, callbacks)}
      end)

    %{fields: fields}
  end

  defp decode_struct(value, _depth, _callbacks) do
    Errors.raise!(:invalid_value, "expected JSON object for Struct",
      details: %{expected: :object, got: value}
    )
  end

  # `google.protobuf.ListValue` is `repeated Value` serialised as a JSON
  # array.
  defp encode_list_value(%{values: nil}), do: []

  defp encode_list_value(%{values: values}) when is_list(values),
    do: Enum.map(values, &encode_value/1)

  defp encode_list_value(%{values: values}) do
    Errors.raise!(:invalid_value, "expected ListValue values to be a list",
      details: %{expected: :list, got: values}
    )
  end

  defp encode_list_value(%{} = data) when not is_struct(data), do: []

  defp encode_list_value(data) do
    Errors.raise!(:invalid_value, "expected ListValue message",
      details: %{expected: :map, got: data}
    )
  end

  defp decode_list_value(list, depth, callbacks) when is_list(list) do
    %{values: Enum.map(list, &decode_value(&1, depth, callbacks))}
  end

  defp decode_list_value(value, _depth, _callbacks) do
    Errors.raise!(:invalid_value, "expected JSON array for ListValue",
      details: %{expected: :array, got: value}
    )
  end

  # ── Any ──────────────────────────────────────────────────────────────

  # PB stores `google.protobuf.Any` as `%{type_url: binary, value:
  # bytes}`. JSON form: `{"@type": "type.googleapis.com/<fqn>", ...inner}`
  # -- flat-merged for regular messages, value-wrapped (`{"@type": "...",
  # "value": <inner_json>}`) when the embedded message uses a custom JSON
  # mapping (other WKTs and nested Any). An Any with no `type_url`
  # round-trips as the empty JSON object `{}` regardless of the value
  # bytes -- there is no well-formed JSON Any representation that carries
  # a payload without a type, so the bytes are intentionally dropped on
  # this path.
  defp encode_any(data, schema, opts, callbacks) when is_map(data) and not is_struct(data) do
    type_url = Map.get(data, :type_url, "")
    value_bytes = Map.get(data, :value, "")

    cond do
      type_url == "" ->
        %{}

      not is_binary(type_url) ->
        Errors.raise!(:invalid_value, "Any type_url must be a string",
          details: %{expected: :string, got: type_url}
        )

      not is_binary(value_bytes) ->
        Errors.raise!(:invalid_value, "Any value must be a binary",
          details: %{expected: :binary, got: value_bytes}
        )

      true ->
        fqn = parse_any_type_url!(type_url)
        decoded = decode_any_inner_bytes!(schema, fqn, value_bytes)
        inner_json = callbacks.encode_message.(fqn, decoded, schema, opts)

        if any_wrapped?(fqn) do
          %{"@type" => type_url, "value" => inner_json}
        else
          if is_map(inner_json) and not is_struct(inner_json) do
            Map.put(inner_json, "@type", type_url)
          else
            Errors.raise!(
              :invalid_value,
              "Any inner message did not produce a JSON object",
              details: %{expected: :object, got: inner_json}
            )
          end
        end
    end
  end

  defp encode_any(data, _schema, _opts, _callbacks) do
    Errors.raise!(:invalid_value, "expected Any message", details: %{expected: :map, got: data})
  end

  defp decode_any(json, _schema, _opts, _callbacks) when is_map(json) and map_size(json) == 0,
    do: %{type_url: "", value: ""}

  defp decode_any(json, schema, opts, callbacks) when is_map(json) and not is_struct(json) do
    {type_url, rest} = extract_type_url!(json)
    fqn = parse_any_type_url!(type_url)

    inner_term =
      if any_wrapped?(fqn) do
        case Map.fetch(rest, "value") do
          {:ok, raw} ->
            extras = Map.delete(rest, "value")

            if map_size(extras) > 0 and not Keyword.get(opts, :ignore_unknown, false) do
              [extra_key | _] = Map.keys(extras)

              Errors.raise!(:unknown_field, extra_key,
                path: [extra_key],
                details: %{protobuf_message: @any, type_url: type_url}
              )
            end

            raw

          :error ->
            Errors.raise!(
              :invalid_value,
              "Any of well-known type #{inspect(fqn)} requires a 'value' field",
              details: %{type_url: type_url}
            )
        end
      else
        rest
      end

    inner_decoded = callbacks.decode_message.(fqn, inner_term, schema, opts)
    bytes = encode_any_inner_bytes!(inner_decoded, schema, fqn)

    %{type_url: type_url, value: bytes}
  end

  defp decode_any(json, _schema, _opts, _callbacks) do
    Errors.raise!(:invalid_value, "expected JSON object for Any",
      details: %{expected: :object, got: json}
    )
  end

  defp extract_type_url!(json) do
    {tagged, rest} =
      Enum.split_with(json, fn {k, _v} -> Scalars.stringify_key(k) == "@type" end)

    case tagged do
      [{_k, url}] when is_binary(url) ->
        {url, Map.new(rest, fn {k, v} -> {Scalars.stringify_key(k), v} end)}

      [{_k, url}] ->
        Errors.raise!(:invalid_value, "Any @type must be a string",
          details: %{expected: :string, got: url}
        )

      [] ->
        Errors.raise!(:invalid_value, "Any JSON object missing @type field", details: %{})

      _ ->
        Errors.raise!(:invalid_value, "Any JSON object has multiple @type fields", details: %{})
    end
  end

  # The fully-qualified type name is the final `/`-separated segment; the host
  # and any leading path segments are ignored (canonical ProtoJSON). The URL
  # must contain at least one `/` and a non-empty trailing segment.
  defp parse_any_type_url!(url) when is_binary(url) do
    case Any.split_type_url(url) do
      {:ok, _prefix, fqn} -> any_fqn!(fqn)
      :error -> invalid_any_type_url!(url)
    end
  end

  defp invalid_any_type_url!(url) do
    Errors.raise!(
      :invalid_value,
      "Any type_url must contain '/' with the message type as the final path segment",
      details: %{got: url}
    )
  end

  defp any_fqn!(suffix) do
    try do
      String.to_existing_atom(suffix)
    rescue
      ArgumentError ->
        Errors.raise!(:unknown_message, suffix, details: %{type_url_suffix: suffix})
    end
  end

  # The JSON pipelines work on canonical proto-maps, so the packed message is
  # converted through the schema's native representation in both directions.
  defp decode_any_inner_bytes!(schema, fqn, bytes) do
    case Any.unpack(bytes, schema, fqn) do
      {:ok, fields} -> fields
      {:error, error} -> raise error
    end
  end

  defp encode_any_inner_bytes!(fields, schema, fqn) do
    case Any.pack(fields, schema, fqn) do
      {:ok, bytes} -> bytes
      {:error, error} -> raise error
    end
  end

  # Maps a `PB.WellKnownTypes.Spec` validation error to the ProtoJSON error
  # surface. `label` is "Timestamp" or "Duration". Range failures are
  # `:value_out_of_range` (carrying the offending field's value + bounds);
  # everything else is `:invalid_value`.
  defp raise_time_error!({:non_integer, :seconds}, label, seconds, _nanos) do
    Errors.raise!(:invalid_value, "#{label} seconds must be an integer", details: %{got: seconds})
  end

  defp raise_time_error!({:non_integer, :nanos}, label, _seconds, nanos) do
    Errors.raise!(:invalid_value, "#{label} nanos must be an integer", details: %{got: nanos})
  end

  defp raise_time_error!({:seconds_out_of_range, min, max}, _label, seconds, _nanos) do
    Errors.raise!(:value_out_of_range, seconds, details: %{min: min, max: max, value: seconds})
  end

  defp raise_time_error!({:nanos_out_of_range, min, max}, _label, _seconds, nanos) do
    Errors.raise!(:value_out_of_range, nanos, details: %{min: min, max: max, value: nanos})
  end

  defp raise_time_error!({:sign_mismatch, seconds, nanos}, label, _seconds, _nanos) do
    Errors.raise!(:invalid_value, "#{label} nanos sign must match seconds",
      details: %{seconds: seconds, nanos: nanos}
    )
  end

  # ── Decimal-seconds shared helpers ───────────────────────────────────

  # Emits "", ".fff", ".ffffff", or ".fffffffff" depending on whether
  # `nanos` has only-millisecond, only-microsecond, or full nanosecond
  # precision.
  defp format_fractional(0), do: ""

  defp format_fractional(nanos) when nanos > 0 and nanos <= @nanos_max do
    digits = String.pad_leading(Integer.to_string(nanos), 9, "0")

    cond do
      binary_part(digits, 3, 6) == "000000" -> "." <> binary_part(digits, 0, 3)
      binary_part(digits, 6, 3) == "000" -> "." <> binary_part(digits, 0, 6)
      true -> "." <> digits
    end
  end

  defp parse_fractional_nanos(frac) when byte_size(frac) >= 1 and byte_size(frac) <= 9 do
    if frac =~ ~r/\A[0-9]+\z/ do
      padded = frac <> String.duplicate("0", 9 - byte_size(frac))
      {:ok, String.to_integer(padded)}
    else
      :error
    end
  end

  defp parse_fractional_nanos(_), do: :error

  defp parse_unsigned(""), do: :error

  defp parse_unsigned(s) do
    if s =~ ~r/\A[0-9]+\z/, do: {:ok, String.to_integer(s)}, else: :error
  end

  defp take_digits(input, n) when byte_size(input) >= n do
    <<head::binary-size(^n), rest::binary>> = input

    case parse_unsigned(head) do
      {:ok, v} -> {:ok, v, rest}
      :error -> :error
    end
  end

  defp take_digits(_input, _n), do: :error

  defp take_optional_fractional("." <> rest) do
    {frac, tail} = take_digits_run(rest, [])

    case parse_fractional_nanos(frac) do
      {:ok, nanos} -> {:ok, nanos, tail}
      :error -> :error
    end
  end

  defp take_optional_fractional(rest), do: {:ok, 0, rest}

  defp take_digits_run(<<c, rest::binary>>, acc) when c >= ?0 and c <= ?9,
    do: take_digits_run(rest, [c | acc])

  defp take_digits_run(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp take_char(<<c, rest::binary>>), do: {:ok, c, rest}
  defp take_char(_), do: :error
end

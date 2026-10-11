defmodule PB.TextFormat do
  @moduledoc """
  Protobuf text format for PB.

  Text format is the human-readable syntax used for configuration files, test
  fixtures, `.textproto`/`.txtpb` files and debugging output. `decode/4` parses
  it into the same value `PB.decode/3` would produce from the equivalent wire
  bytes, and `encode/4` prints a value as text. Both honor the schema's
  configured projections.

  ## Decoding

      PB.TextFormat.decode(~S'''
      name: "Ada"   # comments run to the end of the line
      phones { number: "555-0100" type: MOBILE }
      scores: [90, 85]
      ''', schema, :"example.Person")

  Parsing follows the protobuf C++ implementation, which is what the
  conformance suite checks and what most text format in the wild is written
  against. That includes its leniencies: `<...>` as well as `{...}` around
  messages, an optional `,` or `;` after each field, an optional `:` before a
  message value, `[a, b]` lists for repeated fields, adjacent string literals
  concatenated, `t`/`True`/`f`/`False` and `0`/`1` for booleans, an `f`
  suffix on floats, and hex or octal integers. Out-of-range float literals
  become infinity or zero rather than errors.

  Extensions are written with their full name in brackets, `[pkg.ext]: 1`, and
  decode under `:__extensions__` as they do from the wire. A group field (or an
  editions delimited field shaped like one) also answers to its message type's
  name, so `Data { ... }` sets the field `data`. Fields named after one of the
  message's reserved names are skipped.

  Inside a `google.protobuf.Any`, the expanded form
  `[type.googleapis.com/pkg.Message] { ... }` sets `type_url` and packs the
  message into `value`, honoring the packed type's projections. As in C++, the
  URL prefix must be `type.googleapis.com/` or `type.googleprod.com/`.

  PB is stricter than C++ in two places. A non-repeated field given twice is
  always rejected (C++ lets an implicit-presence field repeat after a default
  value). Unicode escapes may not encode surrogates, even as a valid pair, as
  the conformance suite requires.

  ## Encoding

  `encode/4` validates the value exactly as `PB.encode/4` does and prints what
  the wire would carry, in the layout the C++ printer uses:

      optional_int32: 5
      optional_string: "héllo"
      optional_nested_message {
        a: 1
      }
      repeated_int32: 1
      repeated_int32: 2
      map_string_string {
        key: "a"
        value: "b"
      }

  Fields print in field-number order and map entries sorted by key, so the
  same value always prints the same text. Group-like fields print their type
  name, extensions `[full.name]`, and a `google.protobuf.Any` whose type
  resolves prints expanded as `[type.googleapis.com/pkg.Message] { ... }`.
  Floats print the shortest text that reads back as the same value (`0.1`, not
  `0.10000000149011612`, for a `float` field).

  Two choices differ from the C++ defaults for readability: `string` values
  keep their UTF-8 characters rather than escaping every non-ASCII byte, and
  empty messages print as `name {}`. Bytes outside printable ASCII print as
  `\\xNN` escapes.

  Unknown fields print by number (`5: 123`), as in C++. PB's parser only reads
  field numbers back with `allow_field_numbers: true`, and then only for fields
  the schema knows, so pass `print_unknown_fields: false` for output that must
  decode again.

  The output parses back to the same value with `decode/4` and with the C++
  parser. Text format output is not byte-for-byte identical across protobuf
  implementations, so compare decoded values rather than text.

  ## Errors

  Text that is not well-formed returns a `PB.DecodeError` with
  `kind: :malformed_text` and the 1-based `:line` and `:column` in `:details`.
  So does a value that does not fit its field's syntax, such as a scalar field
  without a colon or a list for a non-repeated field. A non-repeated field
  given twice returns `kind: :duplicate_field`, also with a position. Values
  that are well-formed but invalid for the field (out of range, unknown enum
  value, invalid UTF-8 in a `string`) return a `PB.ValueError` locating the
  field by `:path`, as `PB.JSON` does.

  Message nesting is limited to a depth of 100, matching the wire and JSON
  decoders.

  Encoding returns the errors `PB.encode/4` would, with
  `operation: :text_encode`.

  ## Options

  Decode (`decode/4`) accepts:

    * `:ignore_unknown` — when `true`, fields the message does not define are
      skipped instead of returning
      `{:error, %PB.ValueError{kind: :unknown_field}}`. Defaults to `false`.
    * `:allow_field_numbers` — when `true`, a field may be named by its number
      (`3: "x"`), as the C++ parser's `AllowFieldNumber` permits. A number
      naming an extension sets that extension, and a reserved number is
      skipped. Without it a number is treated as an unknown field name.
      Defaults to `false`.

  Encode (`encode/4`, `encode_iodata/4`) accepts:

    * `:single_line` — when `true`, prints everything on one line with fields
      separated by a space: `a: 1 b { c: 2 }`. Defaults to `false`.
    * `:short_repeated` — when `true`, prints repeated numeric, boolean and
      enum fields as one list, `values: [1, 2, 3]`, instead of one line per
      element. Defaults to `false`.
    * `:print_unknown_fields` — when `false`, leaves unknown fields out.
      Defaults to `true`.

  An unknown option key, an option meant for the other direction, or a
  non-boolean value returns `{:error, %PB.OptionError{}}`.
  """

  alias PB.DecodeError
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.{Frontend, Options}
  alias PB.TextFormat.{Decoder, Encoder, Layout, Lexer, Parser}

  @type opts :: [
          ignore_unknown: boolean,
          allow_field_numbers: boolean,
          single_line: boolean,
          short_repeated: boolean,
          print_unknown_fields: boolean
        ]

  @decode_opts [:ignore_unknown, :allow_field_numbers]
  @encode_opts [:single_line, :short_repeated, :print_unknown_fields]
  @operation :text_decode
  @encode_operation :text_encode

  @doc """
  Decodes text format into the value `PB.decode/3` would produce.

  Returns `{:ok, value}` or `{:error, error}` (see `PB.Error`).
  """
  @spec decode(binary, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, term} | {:error, PB.Error.t()}
  def decode(text, schema, message_name, opts \\ []) when is_binary(text) do
    with {:ok, opts} <- validate_opts(opts, @decode_opts, @operation, message_name) do
      schema = PB.__compiled__(schema)

      with {:ok, msg} <- fetch_message(schema, message_name, @operation),
           {:ok, fields} <- parse(text, message_name),
           {:ok, proto_map} <- run_decoder(text, fields, schema, message_name, opts) do
        proto_map
        |> Frontend.from_proto(message_name, msg, schema)
        |> RuntimeErrors.normalize_result(@operation, message_name)
      end
    end
  end

  @doc """
  Decodes text format into the value `PB.decode/3` would produce, raising
  `PB.Error` on failure.

  This is the bang variant of `decode/4`.
  """
  @spec decode!(binary, PB.schema_source(), PB.message_name(), opts) :: term
  def decode!(text, schema, message_name, opts \\ []) when is_binary(text) do
    case decode(text, schema, message_name, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc """
  Encodes `data` as text format. Returns `{:ok, binary}` or `{:error, error}`
  (see `PB.Error`).
  """
  @spec encode(term, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, binary} | {:error, PB.Error.t()}
  def encode(data, schema, message_name, opts \\ []) do
    with {:ok, iodata} <- encode_iodata(data, schema, message_name, opts) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  @doc """
  Encodes `data` as text format, raising `PB.Error` on failure.

  This is the bang variant of `encode/4`.
  """
  @spec encode!(term, PB.schema_source(), PB.message_name(), opts) :: binary
  def encode!(data, schema, message_name, opts \\ []) do
    case encode(data, schema, message_name, opts) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  @doc """
  Encodes `data` as text format iodata. Returns `{:ok, iodata}` or
  `{:error, error}` (see `PB.Error`).
  """
  @spec encode_iodata(term, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, iodata} | {:error, PB.Error.t()}
  def encode_iodata(data, schema, message_name, opts \\ []) do
    with {:ok, opts} <- validate_opts(opts, @encode_opts, @encode_operation, message_name) do
      schema = PB.__compiled__(schema)

      # Encoding and decoding applies `PB.encode/4`'s validation and yields the
      # canonical value the wire would carry, which is what gets printed.
      with {:ok, msg} <- fetch_message(schema, message_name, @encode_operation),
           {:ok, bytes} <- encode_operation(PB.encode(data, schema, message_name)),
           {:ok, canonical} <- encode_operation(PB.decode(bytes, schema, message_name)),
           {:ok, fields} <-
             canonical
             |> Frontend.to_proto(message_name, msg, schema)
             |> RuntimeErrors.normalize_result(@encode_operation, message_name) do
        entries = Encoder.entries(message_name, fields, schema, opts)
        {:ok, Layout.render(entries, Keyword.get(opts, :single_line, false))}
      end
    end
  end

  @doc """
  Encodes `data` as text format iodata, raising `PB.Error` on failure.

  This is the bang variant of `encode_iodata/4`.
  """
  @spec encode_iodata!(term, PB.schema_source(), PB.message_name(), opts) :: iodata
  def encode_iodata!(data, schema, message_name, opts \\ []) do
    case encode_iodata(data, schema, message_name, opts) do
      {:ok, iodata} -> iodata
      {:error, error} -> raise error
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp fetch_message(schema, message_name, operation) do
    case schema.messages[message_name] do
      nil ->
        {:error,
         RuntimeErrors.to_error({:unknown_message, message_name}, operation, message_name)}

      msg ->
        {:ok, msg}
    end
  end

  defp encode_operation({:ok, _value} = ok), do: ok
  defp encode_operation({:error, error}), do: {:error, %{error | operation: @encode_operation}}

  defp parse(text, message_name) do
    case Parser.parse(text) do
      {:ok, fields} ->
        {:ok, fields}

      {:error, %{message: message, offset: offset}} ->
        {:error, malformed(text, message, offset, [], message_name)}
    end
  end

  defp run_decoder(text, fields, schema, message_name, opts) do
    case Decoder.run(fields, schema, message_name, opts) do
      {:ok, proto_map} ->
        {:ok, proto_map}

      {:error, {:malformed_text, message, offset, path}} ->
        {:error, malformed(text, message, offset, path, message_name)}

      {:error, {:duplicate_field, _name, offset, path}} ->
        {line, column} = Lexer.position(text, offset)

        {:error,
         %DecodeError{
           kind: :duplicate_field,
           format: :text,
           operation: @operation,
           message_name: message_name,
           path: path,
           reason: "non-repeated field is specified more than once",
           details: %{line: line, column: column}
         }}

      {:error, reason} ->
        {:error, RuntimeErrors.to_error(reason, @operation, message_name)}
    end
  end

  defp malformed(text, message, offset, path, message_name) do
    {line, column} = Lexer.position(text, offset)

    %DecodeError{
      kind: :malformed_text,
      format: :text,
      operation: @operation,
      message_name: message_name,
      path: path,
      reason: message,
      details: %{line: line, column: column}
    }
  end

  defp validate_opts(opts, allowed, operation, message_name) do
    opts
    |> Options.validate_booleans(allowed)
    |> RuntimeErrors.normalize_result(operation, message_name)
  end
end

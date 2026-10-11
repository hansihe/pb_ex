defmodule PB.TextFormat do
  @moduledoc """
  Protobuf text format decoder for PB.

  `decode/4` parses text format — the human-readable syntax used for
  configuration files, test fixtures and `.textproto`/`.txtpb` files — into the
  same value `PB.decode/3` would produce from the equivalent wire bytes,
  honoring the schema's configured projections.

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

  PB is stricter than C++ in two places. A non-repeated field given twice is
  always rejected (C++ lets an implicit-presence field repeat after a default
  value). Unicode escapes may not encode surrogates, even as a valid pair, as
  the conformance suite requires.

  ## Not yet supported

  Extension fields (`[pkg.ext]`), expanded `google.protobuf.Any` values
  (`[type.googleapis.com/pkg.Message] { ... }`), reserved field names, and the
  type-name spelling of group fields are rejected for now. There is no text
  format encoder yet.

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

  ## Options

    * `:ignore_unknown` — when `true`, fields the message does not define are
      skipped instead of returning
      `{:error, %PB.ValueError{kind: :unknown_field}}`. Defaults to `false`.

  An unknown option key or a non-boolean value returns
  `{:error, %PB.OptionError{}}`.
  """

  alias PB.DecodeError
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.{Frontend, Options}
  alias PB.TextFormat.{Decoder, Lexer, Parser}

  @type opts :: [ignore_unknown: boolean]

  @decode_opts [:ignore_unknown]
  @operation :text_decode

  @doc """
  Decodes text format into the value `PB.decode/3` would produce.

  Returns `{:ok, value}` or `{:error, error}` (see `PB.Error`).
  """
  @spec decode(binary, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, term} | {:error, PB.Error.t()}
  def decode(text, schema, message_name, opts \\ []) when is_binary(text) do
    with {:ok, opts} <- validate_opts(opts, message_name) do
      schema = PB.__compiled__(schema)

      case schema.messages[message_name] do
        nil ->
          {:error,
           RuntimeErrors.to_error({:unknown_message, message_name}, @operation, message_name)}

        msg ->
          with {:ok, fields} <- parse(text, message_name),
               {:ok, proto_map} <- run_decoder(text, fields, schema, message_name, opts) do
            proto_map
            |> Frontend.from_proto(message_name, msg, schema)
            |> RuntimeErrors.normalize_result(@operation, message_name)
          end
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

  # ── Internals ────────────────────────────────────────────────────────

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

  defp validate_opts(opts, message_name) do
    opts
    |> Options.validate_booleans(@decode_opts)
    |> RuntimeErrors.normalize_result(@operation, message_name)
  end
end

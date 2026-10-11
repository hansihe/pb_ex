defmodule PB.JSON do
  @moduledoc """
  ProtoJSON encoder/decoder for PB.

  The headline API works directly with **JSON binary strings**: `encode/4`
  returns a JSON-encoded binary, `decode/4` parses a JSON-encoded binary.
  Parsing and serialisation are performed with OTP's built-in `:json` module
  (OTP 27+), with two ProtoJSON-required customisations baked in:

    * JSON `null` decodes as Elixir `nil` (and Elixir `nil` is encoded as the
      JSON `null` literal) — OTP's default mapping uses the atom `:null`,
      which PB does not.
    * Duplicate JSON object keys are rejected as `kind: :malformed_json`
      errors — OTP's default decoder silently keeps the last occurrence,
      masking ProtoJSON `FieldNameDuplicate` violations.
    * Decode enforces a fixed recursion-depth limit of 100, matching the wire
      codec's guard for recursive input. JSON container nesting, message
      nesting, and `Value`/`Struct`/`ListValue` nesting beyond that return
      `kind: :malformed_json`.

  A secondary surface exposes the underlying term-in/term-out pipeline.
  `to_term/4` returns a JSON-compatible Elixir term (maps, lists, strings,
  numbers, booleans, `nil`) and `from_term/4` accepts one. Use these when
  composing with another JSON library or when asserting on the JSON shape
  directly.

  Like the wire codec, these honor the schema's configured projections: the
  decoded/accepted message shape follows the schema's native representation
  (adapters, struct/unwrap), so under a projection the value may be a struct, a
  tuple, or a bare scalar rather than a plain map.

  ## Supported

  All scalar types, enums (by name or integer), repeated fields, maps, oneofs,
  proto2 and proto3 (including proto3 `optional`).

  Wrapper messages (`google.protobuf.Int32Value`, `StringValue`, `BoolValue`,
  `BytesValue`, etc.) are serialised as their bare scalar value per ProtoJSON.
  `google.protobuf.FieldMask` is serialised as a single comma-separated string
  with each path converted between snake_case (proto) and lowerCamelCase (JSON).
  `google.protobuf.Duration` is serialised as a decimal-seconds string ending
  in `"s"`. `google.protobuf.Timestamp` is serialised as an RFC 3339 / ISO 8601
  string in UTC ending in `"Z"`. `google.protobuf.Value`, `Struct`, and
  `ListValue` round-trip as bare JSON values (null/number/bool/string),
  objects, and arrays respectively. `google.protobuf.Any` serialises as an
  object with a `@type` URL plus the embedded message — flat-merged when the
  embedded message uses the default JSON object form, or under a `value`
  field when the embedded message itself has a custom JSON mapping (other
  WKTs, including nested `Any`). The `@type` URL may use any host: its last
  path segment names the embedded message, as canonical ProtoJSON specifies.
  The embedded message honors the schema's projections like any other.

  ## Options

    * `:emit_defaults` — when `true`, fields without presence that have their
      default value are emitted instead of omitted. Defaults to `false`.
    * `:use_proto_names` — when `true`, the encoder emits field names as
      written in the `.proto` file (snake_case) rather than lowerCamelCase.
      Parsers always accept both spellings. Defaults to `false`.
    * `:enums_as_ints` — when `true`, enums are encoded as their numeric value
      instead of the enum-value name. Defaults to `false`.
    * `:ignore_unknown` — when `true`, unknown JSON keys are skipped during
      decoding. Defaults to `false` (`decode/4` returns
      `{:error, %PB.ValueError{kind: :unknown_field}}`).

  Encode (`encode/4`, `to_term/4`) accepts `:emit_defaults`, `:use_proto_names`,
  and `:enums_as_ints`; decode (`decode/4`, `from_term/4`) accepts
  `:ignore_unknown`. Like the core codec, the option set is validated per
  direction: an unknown key (including a typo such as `emit_default:`), an
  option meant for the other direction, or a non-boolean value returns
  `{:error, %PB.OptionError{}}` rather than being silently ignored.
  """

  alias PB
  alias PB.{DecodeError, ValueError}
  alias PB.JSON.{Decoder, Depth, Encoder, Errors}
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.{Frontend, Options}

  @type opts :: [
          emit_defaults: boolean,
          use_proto_names: boolean,
          enums_as_ints: boolean,
          ignore_unknown: boolean
        ]

  # Encode and decode accept disjoint option sets, mirroring the core codec
  # (where decode rejects encode-only options and vice versa). Validating per
  # direction turns silent typos like `emit_default:` into an explicit
  # `PB.OptionError` instead of a no-op.
  @encode_opts [:emit_defaults, :use_proto_names, :enums_as_ints]
  @decode_opts [:ignore_unknown]

  # ── String-shaped public API ─────────────────────────────────────────

  @doc """
  Encodes `data` (the same shape produced by `PB.decode/4`) as a JSON
  binary string. Returns `{:ok, binary}` or `{:error, error}` (see `PB.Error`).
  """
  @spec encode(term, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, binary} | {:error, PB.Error.t()}
  def encode(data, schema, message_name, opts \\ []) do
    with {:ok, iodata} <- encode_iodata(data, schema, message_name, opts) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  @doc """
  Encodes `data` as a JSON binary string, raising `PB.Error` on failure.

  This is the bang variant of `encode/4`.
  """
  @spec encode!(term, PB.schema_source(), PB.message_name(), opts) ::
          binary
  def encode!(data, schema, message_name, opts \\ []) do
    case encode(data, schema, message_name, opts) do
      {:ok, binary} -> binary
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  @doc """
  Encodes `data` as JSON iodata. Returns `{:ok, iodata}` or
  `{:error, error}` (see `PB.Error`).
  """
  @spec encode_iodata(term, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, iodata} | {:error, PB.Error.t()}
  def encode_iodata(data, schema, message_name, opts \\ []) do
    with {:ok, term} <- to_term(data, schema, message_name, opts) do
      try do
        {:ok, :json.encode(term, &encode_value/2)}
      rescue
        exception ->
          {:error,
           %ValueError{
             operation: :json_encode,
             kind: :invalid_value,
             message_name: message_name,
             reason: Exception.message(exception)
           }}
      catch
        kind, reason ->
          {:error,
           %ValueError{
             operation: :json_encode,
             kind: :invalid_value,
             message_name: message_name,
             reason: inspect({kind, reason})
           }}
      end
    end
  end

  @doc """
  Encodes `data` as JSON iodata, raising `PB.Error` on failure.

  This is the bang variant of `encode_iodata/4`.
  """
  @spec encode_iodata!(term, PB.schema_source(), PB.message_name(), opts) ::
          iodata
  def encode_iodata!(data, schema, message_name, opts \\ []) do
    case encode_iodata(data, schema, message_name, opts) do
      {:ok, iodata} -> iodata
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  @doc """
  Decodes a JSON binary string into the map shape used by `PB.encode/3`.
  Returns `{:ok, map}` or `{:error, error}` (see `PB.Error`).

  Two ProtoJSON-required behaviours are baked in: JSON `null` is mapped to
  Elixir `nil`, and duplicate JSON object keys are rejected as
  `kind: :malformed_json` errors.
  """
  @spec decode(binary, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, term} | {:error, PB.Error.t()}
  def decode(json, schema, message_name, opts \\ []) when is_binary(json) do
    with {:ok, term} <- parse_json(json, message_name) do
      from_term(term, schema, message_name, opts)
    end
  end

  @doc """
  Decodes a JSON binary string into the map shape used by `PB.encode/3`,
  raising `PB.Error` on failure.

  This is the bang variant of `decode/4`.
  """
  @spec decode!(binary, PB.schema_source(), PB.message_name(), opts) ::
          term
  def decode!(json, schema, message_name, opts \\ []) when is_binary(json) do
    case decode(json, schema, message_name, opts) do
      {:ok, map} -> map
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  # ── Term-shaped public API ───────────────────────────────────────────

  @doc """
  Encodes `data` into a JSON-compatible Elixir term (maps, lists, strings,
  numbers, booleans, `nil`). Returns `{:ok, term}` or
  `{:error, error}` (see `PB.Error`).

  Use this when composing with a different JSON library or when asserting on
  the JSON shape directly.
  """
  @spec to_term(term, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, term} | {:error, PB.Error.t()}
  def to_term(data, schema, message_name, opts \\ []) do
    with {:ok, opts} <- validate_opts(opts, @encode_opts, :json_encode, message_name) do
      do_to_term(data, PB.__compiled__(schema), message_name, opts)
    end
  end

  defp do_to_term(data, schema, message_name, opts) do
    case schema.messages[message_name] do
      nil ->
        Errors.unknown_message(:json_encode, message_name)

      msg ->
        # Mirror of decode: convert the native representation back to the proto-map
        # (running the schema's adapters / representation), then the Encoder works
        # purely on proto-map. Identity pass when no projections are configured.
        with {:ok, proto_map} <-
               data
               |> Frontend.to_proto(message_name, msg, schema)
               |> RuntimeErrors.normalize_result(:json_encode, message_name) do
          Encoder.run(proto_map, schema, message_name, opts)
        end
    end
  end

  @doc """
  Encodes `data` into a JSON-compatible Elixir term, raising `PB.Error`
  on failure.

  This is the bang variant of `to_term/4`.
  """
  @spec to_term!(term, PB.schema_source(), PB.message_name(), opts) ::
          term
  def to_term!(data, schema, message_name, opts \\ []) do
    case to_term(data, schema, message_name, opts) do
      {:ok, term} -> term
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  @doc """
  Decodes a parsed JSON term into the map shape used by `PB.encode/3`.
  Returns `{:ok, map}` or `{:error, error}` (see `PB.Error`).
  """
  @spec from_term(term, PB.schema_source(), PB.message_name(), opts) ::
          {:ok, term} | {:error, PB.Error.t()}
  def from_term(json_term, schema, message_name, opts \\ []) do
    with {:ok, opts} <- validate_opts(opts, @decode_opts, :json_decode, message_name) do
      do_from_term(json_term, PB.__compiled__(schema), message_name, opts)
    end
  end

  defp do_from_term(json_term, schema, message_name, opts) do
    case schema.messages[message_name] do
      nil ->
        Errors.unknown_message(:json_decode, message_name)

      msg ->
        # The Decoder produces the canonical proto-map; the Frontend then applies
        # the schema's configured native representation (adapters / struct /
        # unwrap), so ProtoJSON honors projections exactly as the wire codec
        # does. On a schema with no projections this is an identity pass.
        with {:ok, proto_map} <- Decoder.run(json_term, schema, message_name, opts) do
          proto_map
          |> Frontend.from_proto(message_name, msg, schema)
          |> RuntimeErrors.normalize_result(:json_decode, message_name)
        end
    end
  end

  @doc """
  Decodes a parsed JSON term into the map shape used by `PB.encode/3`,
  raising `PB.Error` on failure.

  This is the bang variant of `from_term/4`.
  """
  @spec from_term!(term, PB.schema_source(), PB.message_name(), opts) ::
          term
  def from_term!(json_term, schema, message_name, opts \\ []) do
    case from_term(json_term, schema, message_name, opts) do
      {:ok, map} -> map
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  # Validate the option keyword against the direction's allowed set, producing
  # a `PB.OptionError` (via the shared runtime vocabulary) on a bad shape,
  # unknown key, or non-boolean value. On success the keyword passes through
  # unchanged — the encode/decode pipelines read it with bracket access.
  defp validate_opts(opts, allowed, operation, message_name) do
    opts
    |> Options.validate_booleans(allowed)
    |> RuntimeErrors.normalize_result(operation, message_name)
  end

  # OTP's default value encoder serialises `nil` as the string `"nil"`.
  # PB uses `nil` as JSON's `null`, so we trap it here.
  defp encode_value(nil, _encode), do: "null"
  defp encode_value(value, encode), do: :json.encode_value(value, encode)

  # JSON parse customisations:
  #   * map JSON `null` to Elixir `nil` (rather than OTP's default atom
  #     `:null`) so the term layer can treat null uniformly;
  #   * reject exact-duplicate object keys (OTP's default decoder silently
  #     dedupes, masking ProtoJSON `FieldNameDuplicate` violations);
  #   * reject JSON container nesting past PB's fixed decode-depth limit.
  defp parse_json(json, message_name) do
    decoders = %{
      null: nil,
      array_start: &array_start/1,
      array_push: &array_push/2,
      array_finish: &array_finish/2,
      object_start: &object_start/1,
      object_push: &object_push/3,
      object_finish: &object_finish/2
    }

    {decoded, _acc, ""} = :json.decode(json, {:json_root, 0}, decoders)
    {:ok, decoded}
  rescue
    exception ->
      {:error,
       %DecodeError{
         operation: :json_decode,
         kind: :malformed_json,
         format: :json,
         message_name: message_name,
         reason: Exception.message(exception)
       }}
  catch
    :throw, :max_decode_depth_exceeded ->
      {:error,
       %DecodeError{
         operation: :json_decode,
         kind: :malformed_json,
         format: :json,
         message_name: message_name,
         reason: :max_decode_depth_exceeded
       }}

    :throw, {:duplicate_key, key} ->
      {:error,
       %DecodeError{
         operation: :json_decode,
         kind: :malformed_json,
         format: :json,
         message_name: message_name,
         reason: "duplicate JSON object key #{inspect(key)}"
       }}

    kind, reason ->
      {:error,
       %DecodeError{
         operation: :json_decode,
         kind: :malformed_json,
         format: :json,
         message_name: message_name,
         reason: inspect({kind, reason})
       }}
  end

  # The object accumulator keeps `{depth, proplist, seen}` so duplicate-key
  # detection is an O(1) map membership test per key rather than List.keymember?'s
  # O(n) scan — the latter makes decoding an n-key object (e.g. a large
  # `map<string,V>`) O(n²). object_finish collapses it back to the map OTP's
  # default decoder would produce.
  defp array_start(old_acc), do: {:json_array, parse_descend!(old_acc), []}

  defp array_push(value, {:json_array, depth, values}), do: {:json_array, depth, [value | values]}

  defp array_finish({:json_array, _depth, values}, old_acc), do: {Enum.reverse(values), old_acc}

  defp object_start(old_acc), do: {:json_object, parse_descend!(old_acc), [], %{}}

  defp object_push(key, value, {:json_object, depth, proplist, seen}) do
    if Map.has_key?(seen, key) do
      throw({:duplicate_key, key})
    else
      {:json_object, depth, [{key, value} | proplist], Map.put(seen, key, true)}
    end
  end

  defp object_finish({:json_object, _depth, proplist, _seen}, old_acc),
    do: {:maps.from_list(proplist), old_acc}

  defp parse_descend!(acc) do
    case Depth.descend(parse_depth(acc)) do
      {:ok, depth} -> depth
      :error -> throw(:max_decode_depth_exceeded)
    end
  end

  defp parse_depth({:json_root, depth}), do: depth
  defp parse_depth({:json_array, depth, _values}), do: depth
  defp parse_depth({:json_object, depth, _proplist, _seen}), do: depth
end

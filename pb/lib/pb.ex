defmodule PB do
  @moduledoc """
  Data-driven protobuf toolkit for Elixir.
  Runtime usage needs no code generation or build step. A schema is a plain
  Elixir data structure produced by `compile/1`.

  For stable schemas, see `PB.Schema` to embed a compiled schema in a module
  at Elixir compile time while keeping the runtime schema-map API available.

  ## Usage

      # Generate a descriptor set from your .proto files:
      #   protoc --descriptor_set_out=schema.pb your.proto

      {:ok, descriptor_set} = PB.decode_descriptor_set(File.read!("schema.pb"))
      schema = PB.compile(descriptor_set)

      {:ok, binary} = PB.encode(%{name: "hello"}, schema, :"my.package.MyMessage")
      {:ok, decoded} = PB.decode(binary, schema, :"my.package.MyMessage")

  ## Other formats

  This module handles the protobuf wire format. The same schema, projections,
  and value shapes work with the other formats:

    * `PB.JSON` — ProtoJSON, the canonical protobuf JSON mapping.
    * `PB.TextFormat` — protobuf text format, as used by `.textproto` files
      and debugging output.

  Validation against protovalidate rules lives in `PB.Validate`.

  ## Schema

  Message names, enum names, service names, and extension names are
  fully-qualified atoms (e.g. `:"my.package.MyMessage"`).

  The map returned by `compile/1` is an internal representation. Its structure
  is not part of the public API and may change without notice. To enumerate or
  look up messages, enums, services, and extensions, use the introspection
  helpers in `PB.Schema` (`list_messages/1`, `fetch_message/2`,
  `message!/2`, etc.), which return stable `%PB.Schema.Info{}` structs.

  ## Services

  Service definitions from `.proto` files are extracted by `compile/1` and
  exposed through `PB.Schema.list_services/1`, `fetch_service/2`, and
  `service!/2`, including method input/output types and streaming flags.

  ## Reserved map keys

  PB stores non-protobuf metadata under dunder atom keys that cannot collide
  with real `.proto` field names. These atoms are the stable contract for both
  encode input and decode output:

    * `:__unknown_fields__` — preserved unknown wire fields, as a list of
      `%PB.UnknownField{}` structs.
    * `:__extensions__` — known extension field values, keyed by fully-qualified
      extension name.
    * `:__message_name__` — optional message-name metadata produced by
      `decode/3,4` when `message_names: :root` is set. When supplied on input to
      encode or validation APIs, it must match the message being processed.

  ## Types

  Maps, oneofs, packed repeated fields, and all scalar types (including
  sint32/sint64 zigzag, sfixed, float/double with NaN/infinity) are supported.
  """

  @typedoc """
  Prepared compiled PB schema, as returned by `compile/2`.

  The internal structure is not part of the public API and may change without
  notice. Use the `PB.Schema` introspection helpers (`list_messages/1`,
  `fetch_message/2`, …) to inspect a schema rather than reading the map
  directly.
  """
  @type schema :: map()

  @typedoc """
  Schema source accepted by public encode/decode/normalize/validate, JSON, and
  text format APIs.

  Either a compiled schema map or a module that `use PB.Schema`. Module
  values are resolved by calling `__pb_schema__/0`.
  """
  @type schema_source :: schema | module()

  @typedoc "Fully-qualified protobuf message name (an atom, e.g. `:\"my.pkg.Person\"`)."
  @type message_name :: atom()

  @typedoc "Fully-qualified protobuf enum name (an atom)."
  @type enum_name :: atom()

  @typedoc "Fully-qualified protobuf service name (an atom)."
  @type service_name :: atom()

  @typedoc "Fully-qualified protobuf extension field name (an atom)."
  @type extension_name :: atom()

  @typedoc "Field name atom as it appears in PB message maps."
  @type field_name :: atom()

  @typedoc "Protobuf field number."
  @type field_number :: pos_integer()

  @typedoc "Resolved field cardinality surfaced by schema introspection."
  @type cardinality :: :singular | :repeated | :map

  @typedoc "Resolved protobuf presence semantics surfaced by schema introspection."
  @type presence :: :implicit | :explicit | :required | :oneof | :none

  @typedoc """
  Compile-time projection entries for the `:projections` option.

  Each entry pairs a fully-qualified message name with a keyword list of
  projection options. Within an entry, `:adapter` is mutually exclusive with
  the structural options `:struct`, `:unwrap`, `:preserved_unknown_fields`,
  `:extensions`, and `:oneofs`.
  """
  @type projection_entry :: {PB.message_name(), projection_opts}

  @typedoc "Projection options accepted within a `:projections` entry."
  @type projection_opts :: [
          {:adapter, PB.Adapter.t()}
          | {:struct, module}
          | {:unwrap, true | atom}
          | {:preserved_unknown_fields, :drop | :reject | {:field, atom}}
          | {:extensions, :reject | {:field, atom}}
          | {:oneofs, [{atom(), [{:representation, :identity}]}]}
        ]

  @typedoc "Decoded protobuf descriptor set (output of `decode_descriptor_set/1`, input to `compile/1`)."
  @type descriptor_set :: map

  @typedoc "Structured runtime encode/decode error."
  @type error :: PB.Error.t()

  @doc false
  @spec __compiled__(schema_source) :: schema
  def __compiled__(schema) when is_map(schema), do: schema

  def __compiled__(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__pb_schema__, 0) do
      module.__pb_schema__()
    else
      raise ArgumentError,
            "expected a PB schema map or a module that `use PB.Schema`, got: " <>
              inspect(module)
    end
  end

  def __compiled__(other) do
    raise ArgumentError,
          "expected a PB schema map or a module that `use PB.Schema`, got: " <>
            inspect(other)
  end

  @doc """
  Decodes a binary `FileDescriptorSet` (as produced by `protoc --descriptor_set_out`)
  and returns a decoded descriptor set suitable for `compile/1`.

  Uses PB's bundled main schema, which knows about the well-known types, the CEL
  `cel.expr` descriptors, and the `buf.validate` extensions. Extensions defined
  in those protos (notably `buf.validate.field`, `buf.validate.message`,
  `buf.validate.oneof`) are therefore materialized into the decoded options
  under the `:__extensions__` map key rather than dropped to unknown-field
  bytes.
  """
  @spec decode_descriptor_set(binary) :: {:ok, descriptor_set} | {:error, error}
  def decode_descriptor_set(binary) do
    __decode_descriptor_set_with_schema__(binary, PB.Schema.Main.schema())
  end

  @doc """
  Decodes a binary `FileDescriptorSet`, returning the decoded descriptor set or
  raising `PB.Error`.

  This is the bang variant of `decode_descriptor_set/1`.
  """
  @spec decode_descriptor_set!(binary) :: descriptor_set
  def decode_descriptor_set!(binary) do
    __decode_descriptor_set_with_schema__!(binary, PB.Schema.Main.schema())
  end

  @doc false
  @spec __decode_descriptor_set_with_schema__(binary, schema_source) ::
          {:ok, descriptor_set} | {:error, error}
  def __decode_descriptor_set_with_schema__(binary, schema) do
    decode(binary, __compiled__(schema), :"google.protobuf.FileDescriptorSet")
  end

  @doc false
  @spec __decode_descriptor_set_with_schema__!(binary, schema_source) :: descriptor_set
  def __decode_descriptor_set_with_schema__!(binary, schema) do
    decode!(binary, __compiled__(schema), :"google.protobuf.FileDescriptorSet")
  end

  @doc """
  Compiles a decoded descriptor set (from `decode_descriptor_set/1`) into a schema
  that can be used with `encode/3` and `decode/3`.

  Compilation has explicit phases: descriptor compilation produces a draft
  schema, validation annotation and projection compilation consume descriptor
  options, finalization removes those options, and one final preparation pass
  writes runtime metadata. Runtime encode/decode require the prepared schema
  shape returned by this function.

  **Important:** The descriptor set is treated as trusted input. Field names, type
  names, and package names are converted to atoms, which are never garbage collected.
  Do not pass untrusted or user-controlled descriptor sets to this function, as it
  could exhaust the BEAM atom table.

  ## Options

    * `:projections` — list of `{fqn, opts}` entries. Each entry attaches a
      message-level projection to a fully-qualified protobuf message name.
      Within an entry, `opts` is a keyword list with one of:

        * `adapter: %PB.Adapter{}` — app/proto conversion spec (mutually
          exclusive with the keys below).
        * `struct: Module` — project the message to an Elixir struct.
        * `unwrap: field_name | true` — project the message to its single
          field's value.
        * `preserved_unknown_fields: :drop | :reject | {:field, atom}` —
          controls how preserved unknown wire fields are handled in struct or
          unwrap representations.
        * `extensions: :reject | {:field, atom}` — controls how known
          extensions are handled in struct representations.
        * `oneofs: [{oneof_name, [representation: :identity]}, ...]` — declares
          identity-projected oneofs on the message.

      Structural projections may also be declared in proto source via the
      `elixir.pb.v1` custom options, and that is the preferred place when you
      own the schema. Reserve compile-time `:projections` for adapters (which
      cannot be expressed in proto source) and for overriding schemas you do
      not own. Compile-time `:projections` entries conflict if they disagree
      with proto-source options for the same target.

    * `:plugins` — list of `PB.Schema.Plugin` modules, or `{module, opts}`
      tuples, that compile their own data into the schema, in order, once it
      is otherwise complete.

  ## Errors

  Raises `PB.OptionError` for options or `:projections` entries that are not
  well-formed, and `PB.SchemaError` when the schema is invalid: a projection
  that does not fit the message it targets (a struct missing fields, `unwrap`
  on a message without exactly one field, an unknown message), conflicting
  projections, or an invalid `elixir.pb.v1` option in the proto source.
  """
  @spec compile(descriptor_set) :: schema
  @spec compile(descriptor_set, keyword) :: schema
  def compile(descriptor_set, opts \\ []) do
    opts = compile_opts!(opts)
    plugins = PB.Schema.Plugin.__entries__!(opts.plugins)

    descriptor_set
    # Compile descriptors into a draft schema with semantic field facts
    # resolved, including presence, cardinality, encoding, maps, oneofs,
    # extensions, and effective features.
    |> PB.Schema.Compiler.compile()
    # Annotate that draft with protovalidate metadata while descriptor
    # options are still available.
    |> PB.Validate.Compiler.annotate()
    # Compile all public term projections into the same draft schema shape
    # regardless of whether they came from proto options or caller overrides.
    |> PB.Schema.Projections.apply(opts.projections)
    # Prepare exactly once at the end so runtime encode/decode receive
    # indexes, tags, enum refs, adapter refs, and other hot-path metadata as
    # part of the schema contract.
    |> PB.Schema.Prepare.prepare()
    # Precompute the merged standard-rule schema once (only when predefined CEL
    # rules are present) so validation does not rebuild it per CEL op. Runs after
    # prepare so the cached value is itself a prepared schema.
    |> PB.Validate.Schema.attach_standard_rule_schema()
    # Plugins compile their own data into the final, prepared schema.
    |> PB.Schema.Plugin.__run__(plugins)
  end

  @doc """
  Encodes `data` as a protobuf message, returning `{:ok, binary}`.

  For zero-copy paths that can consume iodata directly, use `encode_iodata/4`.

  For canonical messages, `data` is a map with atom keys matching field names.
  Repeated fields use lists, map fields use Elixir maps, oneofs use
  `{field_name, value}` tuples wrapped under the oneof name key, and known
  extension fields may be supplied under the `:__extensions__` map key keyed by
  fully-qualified extension name.

  For represented messages, `data` uses the configured public term shape:
  structs, identity oneofs, or unwrapped single-field values. For adapted root
  or nested messages, `data` is the adapter's app value. PB projects these
  public terms to the protobuf field shape at each message boundary before wire
  encoding.

  Field presence is controlled by map keys, and a field set to `nil` is unset,
  the same as a missing key, for every kind of field: scalars of either
  presence, messages, repeated and map fields, extensions, and oneofs (no
  selected variant). The exception is a message field whose type has an
  adapter: `nil` goes to the adapter, which may read it as a value (a
  `google.protobuf.Value` field holding JSON `null`). Implicit-presence fields
  set to their default are elided. Preserved unknown wire
  fields may be supplied under the `:__unknown_fields__` map key and are
  emitted after known fields.

  ## Options

    * `:unknown_fields` — controls how unknown map keys are handled. The default
      is `:error`, returning `{:error, %PB.ValueError{kind: :unknown_field}}`.
      Pass `:ignore` to preserve the old behavior of silently dropping unknown
      fields.

  Returns `{:error, error}` where `error` is a `PB.Error.t()` for unknown messages, invalid input
  values, invalid options, and adapter failures. Errors include the operation,
  root message name, kind, field path, reason, and details.
  """
  @spec encode(term, schema_source, PB.message_name()) ::
          {:ok, binary} | {:error, error}
  @spec encode(term, schema_source, PB.message_name(), keyword) ::
          {:ok, binary} | {:error, error}
  def encode(data, schema, message_name, opts \\ []) do
    case PB.Runtime.Encoder.encode(__compiled__(schema), message_name, data, opts) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Encodes `data` as a protobuf message, returning a binary or raising
  `PB.Error`.

  This is the bang variant of `encode/4`.
  """
  @spec encode!(term, schema_source, PB.message_name()) :: binary
  @spec encode!(term, schema_source, PB.message_name(), keyword) :: binary
  def encode!(data, schema, message_name, opts \\ []) do
    PB.Runtime.Encoder.encode!(__compiled__(schema), message_name, data, opts)
    |> IO.iodata_to_binary()
  end

  @doc """
  Encodes `data` as a protobuf message, returning `{:ok, iodata}`.

  Same semantics as `encode/4` but skips the final `IO.iodata_to_binary/1`.
  Useful for callers that pass the result directly to a socket, file, or
  framing layer that already accepts iodata.
  """
  @spec encode_iodata(term, schema_source, PB.message_name()) ::
          {:ok, iodata} | {:error, error}
  @spec encode_iodata(term, schema_source, PB.message_name(), keyword) ::
          {:ok, iodata} | {:error, error}
  def encode_iodata(data, schema, message_name, opts \\ []) do
    PB.Runtime.Encoder.encode(__compiled__(schema), message_name, data, opts)
  end

  @doc """
  Encodes `data` as a protobuf message, returning iodata or raising
  `PB.Error`.

  This is the bang variant of `encode_iodata/4`.
  """
  @spec encode_iodata!(term, schema_source, PB.message_name()) :: iodata
  @spec encode_iodata!(term, schema_source, PB.message_name(), keyword) ::
          iodata
  def encode_iodata!(data, schema, message_name, opts \\ []) do
    PB.Runtime.Encoder.encode!(__compiled__(schema), message_name, data, opts)
  end

  @doc """
  Normalizes `data` as a protobuf message, returning the canonical decoded value.

  Normalization validates and encodes `data` with the same rules as `encode/4`,
  then decodes the bytes with the same rules as `decode/4`. This produces the
  data shape PB would return after a protobuf round-trip: implicit scalar
  defaults are elided unless `defaults: true` is passed, nested message values
  are recursively normalized, enum values are canonicalized, and scalar range
  checks are enforced.

  ## Options

    * `:unknown_fields` — forwarded to the encode step. Defaults to `:error`.
    * `:defaults` — forwarded to the decode step. Defaults to `false`.

  Returns `{:error, error}` (a `PB.Error` struct) with `operation: :normalize` for invalid input,
  unknown messages or fields, invalid options, and adapter failures.
  """
  @spec normalize(term, schema_source, PB.message_name()) ::
          {:ok, term} | {:error, error}
  @spec normalize(term, schema_source, PB.message_name(), keyword) ::
          {:ok, term} | {:error, error}
  def normalize(data, schema, message_name, opts \\ []) do
    PB.Runtime.Normalizer.normalize(__compiled__(schema), message_name, data, opts)
  end

  @doc """
  Normalizes `data` as a protobuf message, returning the normalized value or
  raising `PB.Error`.

  This is the bang variant of `normalize/4`.
  """
  @spec normalize!(term, schema_source, PB.message_name()) :: term
  @spec normalize!(term, schema_source, PB.message_name(), keyword) :: term
  def normalize!(data, schema, message_name, opts \\ []) do
    PB.Runtime.Normalizer.normalize!(__compiled__(schema), message_name, data, opts)
  end

  @doc """
  Compares two decoded message terms with schema-aware protobuf field semantics.

  This compares declared fields through the compiled schema rather than relying
  on raw map equality. Explicit-presence fields must be present on both sides;
  implicit scalar, repeated, and map fields compare against their protobuf
  defaults when absent. Nested message fields are compared recursively and
  unknown fields compare by preserved wire bytes. Well-known types, including
  `google.protobuf.Any`, are treated as ordinary protobuf messages.

  Represented structs, identity oneofs, unwrapped messages, and adapted values
  are projected through the same single-message boundary used by encode.

  Both arguments are presumed to be valid terms for `message_name`. A `false`
  result therefore always means "valid messages that are not equal" — it never
  stands in for malformed input. If either side cannot be projected as
  `message_name` (adapter/struct/representation failure, at the root or a nested
  message), or `message_name` (or a nested `type_name`) is not present in
  `schema`, this raises a `PB.Error` struct (`PB.SchemaError` or
  `PB.ValueError`) with `operation: :message_equal`. Those are caller-contract
  failures rather than comparison results — the same class as passing an unknown
  `message_name` (`%PB.SchemaError{kind: :unknown_message}`).
  """
  @spec message_equal?(term, term, schema_source, PB.message_name()) ::
          boolean
  def message_equal?(left, right, schema, message_name) do
    schema = __compiled__(schema)

    case PB.Runtime.MessageEquality.equal?(schema, message_name, left, right) do
      {:ok, equal?} ->
        equal?

      {:error, reason} ->
        raise PB.Runtime.Errors.to_error(reason, :message_equal, message_name)
    end
  end

  @doc """
  Decodes a protobuf binary into an Elixir value.

  For canonical messages, returns `{:ok, map}` where the map has atom keys
  matching field names. Only fields present in the binary are included — proto3
  default values (zero, empty string, false) are omitted from the result.
  Repeated fields are lists, map fields are Elixir maps, and oneofs are
  `{field_name, value}` tuples under the oneof name key. For represented
  messages, decode returns the configured struct, identity oneof, or unwrapped
  value. For adapted root or nested messages, decode returns the adapter's app
  value.
  Unknown wire fields are preserved under the `:__unknown_fields__` map key.
  Known protobuf extension fields are decoded under the `:__extensions__` map
  key, keyed by fully-qualified extension name.

  ## Options

    * `:defaults` — when `true`, populates missing fields with their proto3
      default values (0, 0.0, false, "", [], %{} for maps). Singular message
      fields and oneofs are not populated. Defaults to `false`.
    * `:message_names` — controls whether decoded maps include message-name
      metadata under the `:__message_name__` map key. `nil` omits metadata and is
      the default. `:root` annotates only the root decoded message map. If the
      root message decodes to a represented struct, unwrapped value, or adapter
      value, no message-name metadata is added.

  Returns `{:error, error}` where `error` is a `PB.Error.t()` for unknown messages, malformed input,
  invalid input values, invalid options, and adapter failures. Errors include
  the operation, root message name, kind, field path, reason, and details.
  """
  @spec decode(binary, schema_source, PB.message_name()) ::
          {:ok, term} | {:error, error}
  @spec decode(binary, schema_source, PB.message_name(), keyword) ::
          {:ok, term} | {:error, error}
  def decode(binary, schema, message_name, opts \\ []) do
    PB.Runtime.Decoder.decode(__compiled__(schema), message_name, binary, opts)
  end

  @doc """
  Decodes a protobuf binary into an Elixir map, returning the map or raising
  `PB.Error`.

  This is the bang variant of `decode/4`.
  """
  @spec decode!(binary, schema_source, PB.message_name()) :: term
  @spec decode!(binary, schema_source, PB.message_name(), keyword) :: term
  def decode!(binary, schema, message_name, opts \\ []) do
    PB.Runtime.Decoder.decode!(__compiled__(schema), message_name, binary, opts)
  end

  defp compile_opts!(opts) do
    case PB.Runtime.Options.validate(opts, projections: {:list, []}, plugins: {:list, []}) do
      {:ok, opts} -> opts
      {:error, reason} -> raise PB.Runtime.Errors.to_error(reason, :compile)
    end
  end
end

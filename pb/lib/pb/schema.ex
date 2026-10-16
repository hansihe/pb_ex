defmodule PB.Schema do
  @moduledoc """
  Embeds a compiled PB schema into a module at compile time.

  This is the compile-time counterpart to the runtime flow of reading a
  descriptor set, calling `PB.decode_descriptor_set/1`, and then
  `PB.compile/1`. Runtime schema maps remain fully supported; use this
  module when a schema is stable enough to travel with the compiled BEAM code.

  ## Descriptor file

      defmodule MyApp.Schema do
        use PB.Schema, descriptor: "priv/proto/schema.binpb"
      end

  The descriptor file must be a binary `google.protobuf.FileDescriptorSet`, such
  as one produced by:

      protoc --descriptor_set_out=priv/proto/schema.binpb --include_imports your.proto

  Relative descriptor paths are resolved from the compiler working directory
  (the Mix project root during normal Mix compilation). The generated module is
  marked with `@external_resource`, so Mix recompiles it when the descriptor file
  changes.

  Add `:projections` to attach message-level adapters and structural term
  representations to the embedded schema:

      defmodule MyApp.Schema do
        use PB.Schema,
          descriptor: "priv/proto/schema.binpb",
          projections: [
            {:"google.protobuf.Timestamp", adapter: MyApp.Timestamp.adapter()},
            {:"my.app.User", struct: MyApp.User},
            {:"my.app.Wrapper", unwrap: :value, preserved_unknown_fields: :reject},
            {:"my.app.Event", oneofs: [data: [representation: :identity]]}
          ]
      end

  Structural projections can also be declared in proto source with the
  `elixir.pb.v1` custom options. Use compile-time `:projections` only when
  attaching adapters or compiling overrides for third-party schemas or
  generated descriptor sets you do not own.

  ## Descriptor set map

  For hand-authored schemas or tests, pass the decoded descriptor set map
  directly:

      defmodule MyApp.Schema do
        use PB.Schema,
          descriptor_set: %{
            file: [
              %{
                name: "greeter.proto",
                package: :greeter,
                syntax: :proto3,
                message_type: [
                  %{
                    name: :HelloRequest,
                    field: [
                      %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
                    ]
                  }
                ]
              }
            ]
          }
      end

  ## Generated API

  A schema module exposes:

    * `__pb_schema__/0` — callback returning the embedded compiled schema.
    * `schema/0` — public convenience alias for the callback.
    * `encode/2,3` and `encode!/2,3` — call `PB.encode/4` and `PB.encode!/4`.
    * `encode_iodata/2,3` and `encode_iodata!/2,3` — call `PB.encode_iodata/4`
      and `PB.encode_iodata!/4` for zero-copy iodata output.
    * `decode/2,3` and `decode!/2,3` — call `PB.decode/4` and `PB.decode!/4`.
    * `normalize/2,3` and `normalize!/2,3` — call `PB.normalize/4` and
      `PB.normalize!/4`.
    * `validate/2,3` and `validate!/2,3` — call `PB.Validate.validate/4` and
      `PB.Validate.validate!/4`.

  The top-level `PB`, `PB.Validate`, `PB.JSON`, and `PB.TextFormat` entry
  points accept the schema module directly in place of a compiled schema map.

  The schema is built once when the module is loaded and kept in
  `:persistent_term`, so a schema module cannot declare its own `@on_load`.

  ## Introspection

  This module also exposes lookup helpers that return public `PB.Schema.Info`
  structs — use these instead of reading the compiled-schema map directly:

    * `list_messages/1`, `fetch_message/2`, `message!/2`
    * `list_enums/1`, `fetch_enum/2`, `enum!/2`
    * `list_services/1`, `fetch_service/2`, `service!/2`
    * `list_extensions/1`, `fetch_extension/2`, `extension!/2`

  Every lookup accepts either a compiled schema map or a `use PB.Schema`
  module. The bang variants raise `PB.SchemaError` (with `kind: :unknown_*` and
  `operation: :introspect`) on miss; the `fetch_*` variants return
  `{:ok, info} | :error`. The returned Info structs are the public stable
  surface — the compiled-schema internals may change without notice.

  Fields and messages carry their declared options; `option/2` reads a custom
  option from one.
  """

  @callback __pb_schema__() :: PB.schema()

  @doc false
  defmacro __using__(opts) when is_list(opts) do
    validate_opts!(opts)

    schema_ast = schema_ast(opts)
    external_resource_ast = external_resource_ast(opts)

    quote do
      @behaviour PB.Schema
      unquote(external_resource_ast)

      @schema unquote(schema_ast)

      # A schema holding compiled regexes can't be a BEAM literal, so `@schema`
      # compiles to code that rebuilds it. Build it once, when the module is
      # loaded, and share it through `:persistent_term`.
      @on_load :__pb_schema_load__

      defp __pb_schema_load__ do
        :persistent_term.put({PB.Schema, __MODULE__}, @schema)
      end

      @impl PB.Schema
      @spec __pb_schema__() :: PB.schema()
      def __pb_schema__, do: :persistent_term.get({PB.Schema, __MODULE__})

      @doc "Returns the compiled PB schema embedded in this module."
      @spec schema() :: PB.schema()
      def schema, do: __pb_schema__()

      @doc "Encodes `data` as `message_name` using the schema embedded in this module."
      @spec encode(term, PB.message_name()) ::
              {:ok, binary} | {:error, PB.error()}
      @spec encode(term, PB.message_name(), keyword) ::
              {:ok, binary} | {:error, PB.error()}
      def encode(data, message_name, opts \\ []) do
        PB.encode(data, __pb_schema__(), message_name, opts)
      end

      @doc "Encodes `data` as `message_name` using the schema embedded in this module, raising on error."
      @spec encode!(term, PB.message_name()) :: binary
      @spec encode!(term, PB.message_name(), keyword) :: binary
      def encode!(data, message_name, opts \\ []) do
        PB.encode!(data, __pb_schema__(), message_name, opts)
      end

      @doc "Encodes `data` as `message_name` returning iodata; see `PB.encode_iodata/4`."
      @spec encode_iodata(term, PB.message_name()) ::
              {:ok, iodata} | {:error, PB.error()}
      @spec encode_iodata(term, PB.message_name(), keyword) ::
              {:ok, iodata} | {:error, PB.error()}
      def encode_iodata(data, message_name, opts \\ []) do
        PB.encode_iodata(data, __pb_schema__(), message_name, opts)
      end

      @doc "Encodes `data` as `message_name` returning iodata, raising on error."
      @spec encode_iodata!(term, PB.message_name()) :: iodata
      @spec encode_iodata!(term, PB.message_name(), keyword) :: iodata
      def encode_iodata!(data, message_name, opts \\ []) do
        PB.encode_iodata!(data, __pb_schema__(), message_name, opts)
      end

      @doc "Normalizes `data` as `message_name` using the schema embedded in this module."
      @spec normalize(term, PB.message_name()) ::
              {:ok, term} | {:error, PB.error()}
      @spec normalize(term, PB.message_name(), keyword) ::
              {:ok, term} | {:error, PB.error()}
      def normalize(data, message_name, opts \\ []) do
        PB.normalize(data, __pb_schema__(), message_name, opts)
      end

      @doc "Normalizes `data` as `message_name` using the schema embedded in this module, raising on error."
      @spec normalize!(term, PB.message_name()) :: term
      @spec normalize!(term, PB.message_name(), keyword) :: term
      def normalize!(data, message_name, opts \\ []) do
        PB.normalize!(data, __pb_schema__(), message_name, opts)
      end

      @doc "Decodes `binary` as `message_name` using the schema embedded in this module."
      @spec decode(binary, PB.message_name()) ::
              {:ok, term} | {:error, PB.error()}
      @spec decode(binary, PB.message_name(), keyword) ::
              {:ok, term} | {:error, PB.error()}
      def decode(binary, message_name, opts \\ []) do
        PB.decode(binary, __pb_schema__(), message_name, opts)
      end

      @doc "Decodes `binary` as `message_name` using the schema embedded in this module, raising on error."
      @spec decode!(binary, PB.message_name()) :: term
      @spec decode!(binary, PB.message_name(), keyword) :: term
      def decode!(binary, message_name, opts \\ []) do
        PB.decode!(binary, __pb_schema__(), message_name, opts)
      end

      @doc "Validates `data` as `message_name` using the schema embedded in this module."
      @spec validate(term, PB.message_name()) ::
              :ok | {:error, PB.Validate.Error.t()}
      @spec validate(term, PB.message_name(), keyword) ::
              :ok | {:error, PB.Validate.Error.t()}
      def validate(data, message_name, opts \\ []) do
        PB.Validate.validate(data, __pb_schema__(), message_name, opts)
      end

      @doc "Validates `data` as `message_name` using the schema embedded in this module, raising on rule failures."
      @spec validate!(term, PB.message_name()) :: :ok
      @spec validate!(term, PB.message_name(), keyword) :: :ok
      def validate!(data, message_name, opts \\ []) do
        PB.Validate.validate!(data, __pb_schema__(), message_name, opts)
      end
    end
  end

  defmacro __using__(_opts) do
    raise ArgumentError,
          "expected PB.Schema options to be a keyword list with exactly one of " <>
            ":descriptor or :descriptor_set"
  end

  @doc false
  @spec __compile_descriptor__!(Path.t()) :: PB.schema()
  @spec __compile_descriptor__!(Path.t(), keyword) :: PB.schema()
  def __compile_descriptor__!(path), do: __compile_descriptor__!(path, [])

  def __compile_descriptor__!(path, opts) when is_list(opts) do
    path
    |> __expand_descriptor_path__!()
    |> File.read!()
    |> PB.decode_descriptor_set!()
    |> PB.compile(opts)
  end

  @doc false
  @spec __compile_descriptor__!(Path.t(), PB.schema()) :: PB.schema()
  @spec __compile_descriptor__!(Path.t(), PB.schema(), keyword) :: PB.schema()
  def __compile_descriptor__!(path, schema) when is_map(schema) do
    __compile_descriptor__!(path, schema, [])
  end

  def __compile_descriptor__!(path, schema, opts) when is_map(schema) and is_list(opts) do
    binary =
      path
      |> __expand_descriptor_path__!()
      |> File.read!()

    binary
    |> PB.__decode_descriptor_set_with_schema__!(schema)
    |> PB.compile(opts)
  end

  @doc false
  @spec __compile_descriptor_set__!(PB.descriptor_set()) :: PB.schema()
  @spec __compile_descriptor_set__!(PB.descriptor_set(), keyword) :: PB.schema()
  def __compile_descriptor_set__!(descriptor_set, opts \\ [])

  def __compile_descriptor_set__!(descriptor_set, opts)
      when is_map(descriptor_set) and is_list(opts) do
    PB.compile(descriptor_set, opts)
  end

  def __compile_descriptor_set__!(descriptor_set, _opts) do
    raise ArgumentError,
          "expected :descriptor_set to be a decoded FileDescriptorSet map, got: " <>
            inspect(descriptor_set)
  end

  @doc false
  @spec __expand_descriptor_path__!(Path.t()) :: String.t()
  def __expand_descriptor_path__!(path) when is_binary(path) do
    Path.expand(path)
  end

  def __expand_descriptor_path__!(path) do
    raise ArgumentError,
          "expected :descriptor to be a FileDescriptorSet path string, got: " <> inspect(path)
  end

  # ── Introspection ──────────────────────────────────────────────────

  alias PB.Schema.Info

  @doc """
  Returns the fully-qualified names of every message in `schema_source`,
  sorted alphabetically.

  `schema_source` is either a compiled schema map or a module that
  `use PB.Schema`.
  """
  @spec list_messages(PB.schema_source()) :: [PB.message_name()]
  def list_messages(schema_source) do
    schema_source |> PB.__compiled__() |> Map.fetch!(:messages) |> Map.keys() |> Enum.sort()
  end

  @doc """
  Looks up a message by fully-qualified name, returning `{:ok,
  %PB.Schema.Info.Message{}}` or `:error`.
  """
  @spec fetch_message(PB.schema_source(), PB.message_name()) ::
          {:ok, Info.Message.t()} | :error
  def fetch_message(schema_source, name) when is_atom(name) do
    schema = PB.__compiled__(schema_source)

    case Map.fetch(schema.messages, name) do
      {:ok, message} -> {:ok, Info.build_message(name, message)}
      :error -> :error
    end
  end

  @doc """
  Looks up a message by fully-qualified name, raising `PB.SchemaError` with
  `kind: :unknown_message` if the message is not in the schema.
  """
  @spec message!(PB.schema_source(), PB.message_name()) ::
          Info.Message.t()
  def message!(schema_source, name) do
    case fetch_message(schema_source, name) do
      {:ok, info} -> info
      :error -> raise unknown(:unknown_message, name)
    end
  end

  @doc """
  Returns the fully-qualified names of every enum in `schema_source`, sorted
  alphabetically.
  """
  @spec list_enums(PB.schema_source()) :: [PB.enum_name()]
  def list_enums(schema_source) do
    schema_source |> PB.__compiled__() |> Map.fetch!(:enums) |> Map.keys() |> Enum.sort()
  end

  @doc """
  Looks up an enum by fully-qualified name, returning `{:ok,
  %PB.Schema.Info.Enum{}}` or `:error`.
  """
  @spec fetch_enum(PB.schema_source(), PB.enum_name()) ::
          {:ok, Info.Enum.t()} | :error
  def fetch_enum(schema_source, name) when is_atom(name) do
    schema = PB.__compiled__(schema_source)

    case Map.fetch(schema.enums, name) do
      {:ok, enum} -> {:ok, Info.build_enum(name, enum)}
      :error -> :error
    end
  end

  @doc """
  Looks up an enum by fully-qualified name, raising `PB.SchemaError` with
  `kind: :unknown_enum` if the enum is not in the schema.
  """
  @spec enum!(PB.schema_source(), PB.enum_name()) :: Info.Enum.t()
  def enum!(schema_source, name) do
    case fetch_enum(schema_source, name) do
      {:ok, info} -> info
      :error -> raise unknown(:unknown_enum, name)
    end
  end

  @doc """
  Returns the fully-qualified names of every service in `schema_source`,
  sorted alphabetically.
  """
  @spec list_services(PB.schema_source()) :: [PB.service_name()]
  def list_services(schema_source) do
    schema_source |> PB.__compiled__() |> Map.fetch!(:services) |> Map.keys() |> Enum.sort()
  end

  @doc """
  Looks up a service by fully-qualified name, returning `{:ok,
  %PB.Schema.Info.Service{}}` or `:error`.
  """
  @spec fetch_service(PB.schema_source(), PB.service_name()) ::
          {:ok, Info.Service.t()} | :error
  def fetch_service(schema_source, name) when is_atom(name) do
    schema = PB.__compiled__(schema_source)

    case Map.fetch(schema.services, name) do
      {:ok, service} -> {:ok, Info.build_service(name, service)}
      :error -> :error
    end
  end

  @doc """
  Looks up a service by fully-qualified name, raising `PB.SchemaError` with
  `kind: :unknown_service` if the service is not in the schema.
  """
  @spec service!(PB.schema_source(), PB.service_name()) ::
          Info.Service.t()
  def service!(schema_source, name) do
    case fetch_service(schema_source, name) do
      {:ok, info} -> info
      :error -> raise unknown(:unknown_service, name)
    end
  end

  @doc """
  Returns the fully-qualified names of every extension in `schema_source`,
  sorted alphabetically.
  """
  @spec list_extensions(PB.schema_source()) :: [PB.extension_name()]
  def list_extensions(schema_source) do
    schema_source
    |> PB.__compiled__()
    |> Map.fetch!(:extensions_by_name)
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Looks up an extension by fully-qualified name, returning `{:ok,
  %PB.Schema.Info.Field{}}` or `:error`.
  """
  @spec fetch_extension(PB.schema_source(), PB.extension_name()) ::
          {:ok, Info.Field.t()} | :error
  def fetch_extension(schema_source, name) when is_atom(name) do
    schema = PB.__compiled__(schema_source)

    case Map.fetch(schema.extensions_by_name, name) do
      {:ok, field} -> {:ok, Info.build_extension(name, field)}
      :error -> :error
    end
  end

  @doc """
  Looks up an extension by fully-qualified name, raising `PB.SchemaError` with
  `kind: :unknown_extension` if the extension is not in the schema.
  """
  @spec extension!(PB.schema_source(), PB.extension_name()) ::
          Info.Field.t()
  def extension!(schema_source, name) do
    case fetch_extension(schema_source, name) do
      {:ok, info} -> info
      :error -> raise unknown(:unknown_extension, name)
    end
  end

  @doc """
  Returns the value of the custom option `extension_name` declared on a field
  or message, or `nil` if it isn't set.

      PB.Schema.option(field, :"acme.v1.sensitive")
      #=> true

  Standard options are plain keys of `options`, such as
  `field.options[:deprecated]`.
  """
  @spec option(Info.Field.t() | Info.Message.t(), PB.extension_name()) :: term()
  def option(%struct{options: options}, extension_name)
      when struct in [Info.Field, Info.Message] and is_atom(extension_name) do
    options |> Map.get(:__extensions__, %{}) |> Map.get(extension_name)
  end

  defp unknown(:unknown_enum = kind, name) do
    %PB.SchemaError{operation: :introspect, kind: kind, type_name: name}
  end

  defp unknown(kind, name) do
    %PB.SchemaError{operation: :introspect, kind: kind, name: name}
  end

  defp validate_opts!(opts) do
    # `:with_schema` is intentionally undocumented and internal-only. It lets the
    # descriptor-set bootstrap decode a descriptor with an explicitly supplied
    # schema instead of the built-in one (see `__compile_descriptor__!/3` and
    # `PB.__decode_descriptor_set_with_schema__!/2`). It is only valid alongside
    # `:descriptor` and should not be surfaced in the public moduledoc.
    unknown =
      Keyword.keys(opts) --
        [:descriptor, :descriptor_set, :projections, :with_schema]

    if unknown != [] do
      raise ArgumentError, "unknown PB.Schema option(s): #{inspect(unknown)}"
    end

    case {Keyword.has_key?(opts, :descriptor), Keyword.has_key?(opts, :descriptor_set)} do
      {true, false} -> :ok
      {false, true} -> :ok
      _ -> raise ArgumentError, "expected exactly one of :descriptor or :descriptor_set"
    end

    if Keyword.has_key?(opts, :with_schema) and not Keyword.has_key?(opts, :descriptor) do
      raise ArgumentError, ":with_schema is only valid alongside :descriptor"
    end
  end

  defp schema_ast(opts) do
    compile_opts = [projections: Keyword.get(opts, :projections, [])]

    source_ast =
      cond do
        Keyword.has_key?(opts, :descriptor) ->
          descriptor = Keyword.fetch!(opts, :descriptor)

          case Keyword.fetch(opts, :with_schema) do
            {:ok, schema_expr} ->
              quote do
                PB.Schema.__compile_descriptor__!(
                  unquote(descriptor),
                  unquote(schema_expr),
                  unquote(compile_opts)
                )
              end

            :error ->
              quote do
                PB.Schema.__compile_descriptor__!(unquote(descriptor), unquote(compile_opts))
              end
          end

        Keyword.has_key?(opts, :descriptor_set) ->
          descriptor_set = Keyword.fetch!(opts, :descriptor_set)

          quote do
            PB.Schema.__compile_descriptor_set__!(
              unquote(descriptor_set),
              unquote(compile_opts)
            )
          end
      end

    source_ast
  end

  defp external_resource_ast(opts) do
    if Keyword.has_key?(opts, :descriptor) do
      descriptor = Keyword.fetch!(opts, :descriptor)

      quote do
        @external_resource PB.Schema.__expand_descriptor_path__!(unquote(descriptor))
      end
    else
      quote do
      end
    end
  end
end

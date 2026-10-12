defmodule PB.Schema.Info.Field do
  @moduledoc "Public projection of a compiled protobuf field or extension."

  @enforce_keys [:name, :number, :type, :cardinality, :presence]
  defstruct [
    :name,
    :number,
    :type,
    :cardinality,
    :presence,
    :oneof,
    :json_name,
    :default,
    :extendee
  ]

  @type scalar ::
          :double
          | :float
          | :int32
          | :int64
          | :uint32
          | :uint64
          | :sint32
          | :sint64
          | :fixed32
          | :fixed64
          | :sfixed32
          | :sfixed64
          | :bool
          | :string
          | :bytes

  @type type ::
          {:scalar, scalar()}
          | {:message, PB.message_name()}
          | {:enum, PB.enum_name()}
          | {:map, type(), type()}

  @type t :: %__MODULE__{
          name: PB.field_name() | PB.extension_name(),
          number: PB.field_number(),
          type: type(),
          cardinality: PB.cardinality(),
          presence: PB.presence(),
          oneof: PB.field_name() | nil,
          json_name: String.t() | nil,
          default: term() | :none,
          extendee: PB.message_name() | nil
        }
end

defmodule PB.Schema.Info.Oneof do
  @moduledoc "Public projection of a compiled oneof declaration."

  @enforce_keys [:name, :fields]
  defstruct [:name, :fields]

  @type t :: %__MODULE__{
          name: PB.field_name(),
          fields: [PB.field_name()]
        }
end

defmodule PB.Schema.Info.ExtensionRange do
  @moduledoc "Public projection of a single extension range declaration."

  @enforce_keys [:start, :end]
  defstruct [:start, :end]

  @type t :: %__MODULE__{start: integer(), end: integer()}
end

defmodule PB.Schema.Info.Message do
  @moduledoc "Public projection of a compiled protobuf message."

  @enforce_keys [:name, :fields, :oneofs, :map_entry?, :syntax]
  defstruct [
    :name,
    :package,
    :fields,
    :oneofs,
    :map_entry?,
    :syntax,
    :edition,
    :extensions,
    :extension_ranges,
    :projection
  ]

  @type t :: %__MODULE__{
          name: PB.message_name(),
          package: atom() | nil,
          fields: [PB.Schema.Info.Field.t()],
          oneofs: [PB.Schema.Info.Oneof.t()],
          map_entry?: boolean(),
          syntax: atom(),
          edition: atom() | nil,
          extensions: [PB.Schema.Info.Field.t()],
          extension_ranges: [PB.Schema.Info.ExtensionRange.t()],
          projection: PB.Schema.Projection.t() | nil
        }
end

defmodule PB.Schema.Info.EnumValue do
  @moduledoc "Public projection of a single enum value."

  @enforce_keys [:name, :number]
  defstruct [:name, :number]

  @type t :: %__MODULE__{name: atom(), number: integer()}
end

defmodule PB.Schema.Info.Enum do
  @moduledoc "Public projection of a compiled protobuf enum."

  @enforce_keys [:name, :values]
  defstruct [:name, :package, :values]

  @type t :: %__MODULE__{
          name: PB.enum_name(),
          package: atom() | nil,
          values: [PB.Schema.Info.EnumValue.t()]
        }
end

defmodule PB.Schema.Info.Method do
  @moduledoc "Public projection of a single service method."

  @enforce_keys [:name, :input_type, :output_type, :client_streaming, :server_streaming]
  defstruct [:name, :input_type, :output_type, :client_streaming, :server_streaming]

  @type t :: %__MODULE__{
          name: atom(),
          input_type: PB.message_name(),
          output_type: PB.message_name(),
          client_streaming: boolean(),
          server_streaming: boolean()
        }
end

defmodule PB.Schema.Info.Service do
  @moduledoc "Public projection of a compiled protobuf service."

  @enforce_keys [:name, :methods]
  defstruct [:name, :package, :methods]

  @type t :: %__MODULE__{
          name: PB.service_name(),
          package: atom() | nil,
          methods: [PB.Schema.Info.Method.t()]
        }
end

defmodule PB.Schema.Info do
  @moduledoc """
  Public introspection structs returned by `PB.Schema.fetch_message/2` and
  friends.

  These structs are a stable, intentionally narrow projection of the internal
  compiled schema. Callers should branch off the public structs rather than
  reading `schema.messages` directly: the internal compiled representation may
  grow new fields or change shape as the runtime evolves.

  ## Packages

  `package` on `Message`, `Enum` and `Service` is the proto package of the
  file declaring the type, or `nil` for a file without one. Nested types share
  their file's package, so `a.b.Outer.Inner` declared in package `a.b` has
  `package: :"a.b"`.

  ## Field types

  `%PB.Schema.Info.Field{}.type` is a tagged tuple:

    * `{:scalar, scalar}` where `scalar` is one of `:double`, `:float`,
      `:int32`, `:int64`, `:uint32`, `:uint64`, `:sint32`, `:sint64`,
      `:fixed32`, `:fixed64`, `:sfixed32`, `:sfixed64`, `:bool`, `:string`,
      `:bytes`.
    * `{:message, message_name}` — a message reference.
    * `{:enum, enum_name}` — an enum reference.
    * `{:map, key_type, value_type}` — only emitted when
      `field.cardinality == :map`; `key_type` and `value_type` are themselves
      tagged tuples following the same shape.
  """

  alias PB.Schema.Info.{
    Enum,
    EnumValue,
    ExtensionRange,
    Field,
    Message,
    Method,
    Oneof,
    Service
  }

  @scalar_by_proto %{
    TYPE_DOUBLE: :double,
    TYPE_FLOAT: :float,
    TYPE_INT64: :int64,
    TYPE_UINT64: :uint64,
    TYPE_INT32: :int32,
    TYPE_FIXED64: :fixed64,
    TYPE_FIXED32: :fixed32,
    TYPE_BOOL: :bool,
    TYPE_STRING: :string,
    TYPE_BYTES: :bytes,
    TYPE_UINT32: :uint32,
    TYPE_SFIXED32: :sfixed32,
    TYPE_SFIXED64: :sfixed64,
    TYPE_SINT32: :sint32,
    TYPE_SINT64: :sint64
  }

  @doc false
  @spec build_message(PB.message_name(), map()) :: Message.t()
  def build_message(name, message) do
    fields =
      message.fields_by_number
      |> Map.values()
      |> Elixir.Enum.sort_by(& &1.number)
      |> Elixir.Enum.map(&build_field(&1, message))

    oneofs =
      message.oneofs
      |> Elixir.Enum.sort_by(fn {index, _} -> index end)
      |> Elixir.Enum.map(fn {_index, %{name: oname, fields: ofields}} ->
        %Oneof{name: oname, fields: ofields}
      end)

    extensions =
      message.extensions_by_name
      |> Map.values()
      |> Elixir.Enum.sort_by(& &1.number)
      |> Elixir.Enum.map(&build_field(&1, message))

    extension_ranges =
      message
      |> Map.get(:extension_ranges, [])
      |> Elixir.Enum.map(fn %{start: s, end: e} -> %ExtensionRange{start: s, end: e} end)

    %Message{
      name: name,
      package: Map.get(message, :package),
      fields: fields,
      oneofs: oneofs,
      map_entry?: Map.get(message, :map_entry, false),
      syntax: Map.get(message, :syntax),
      edition: Map.get(message, :edition),
      extensions: extensions,
      extension_ranges: extension_ranges,
      projection: Map.get(message, :projection)
    }
  end

  @doc false
  @spec build_extension(PB.extension_name(), map()) :: Field.t()
  def build_extension(_name, field), do: build_field(field, nil)

  @doc false
  @spec build_enum(PB.enum_name(), map()) :: Enum.t()
  def build_enum(name, enum) do
    # Project from `by_name`, not `by_number`: enum aliases (multiple names
    # mapping to the same number) collapse in `by_number` but are preserved in
    # `by_name`. Ordering is (number, name) so aliases appear adjacent.
    values =
      enum.by_name
      |> Elixir.Enum.map(fn {vname, number} -> %EnumValue{name: vname, number: number} end)
      |> Elixir.Enum.sort_by(fn %EnumValue{number: n, name: vname} -> {n, vname} end)

    %Enum{name: name, package: Map.get(enum, :package), values: values}
  end

  @doc false
  @spec build_service(PB.service_name(), map()) :: Service.t()
  def build_service(name, service) do
    methods =
      service.methods
      |> Elixir.Enum.sort_by(fn {method_name, _} -> method_name end)
      |> Elixir.Enum.map(fn {method_name, method} ->
        %Method{
          name: method_name,
          input_type: method.input_type,
          output_type: method.output_type,
          client_streaming: method.client_streaming,
          server_streaming: method.server_streaming
        }
      end)

    %Service{name: name, package: Map.get(service, :package), methods: methods}
  end

  defp build_field(field, message) do
    oneof_name =
      case Map.get(field, :oneof_index) do
        nil ->
          nil

        index when is_map(message) ->
          case Map.fetch(message.oneofs, index) do
            {:ok, %{name: oname}} -> oname
            :error -> nil
          end

        _ ->
          nil
      end

    %Field{
      name: field.name,
      number: field.number,
      type: field_type(field),
      cardinality: field.cardinality,
      presence: field.presence,
      oneof: oneof_name,
      json_name: Map.get(field, :json_name),
      default: Map.get(field, :default, :none),
      extendee: Map.get(field, :extendee)
    }
  end

  defp field_type(%{cardinality: :map, map_key: key, map_value: value}) do
    {:map, scalar_or_ref(key), scalar_or_ref(value)}
  end

  defp field_type(field), do: scalar_or_ref(field)

  defp scalar_or_ref(%{type: :TYPE_MESSAGE, type_name: name}), do: {:message, name}
  defp scalar_or_ref(%{type: :TYPE_ENUM, type_name: name}), do: {:enum, name}

  defp scalar_or_ref(%{type: type}) do
    case Map.fetch(@scalar_by_proto, type) do
      {:ok, scalar} -> {:scalar, scalar}
      :error -> raise ArgumentError, "unknown protobuf field type: #{inspect(type)}"
    end
  end
end

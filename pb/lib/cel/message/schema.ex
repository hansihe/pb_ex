defmodule CEL.Message.Schema do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Behaviour for CEL checker message reflection.
  @moduledoc false

  # TODO(CEL): This behaviour exposes both primitive lookups and convenience
  # operations derived from those lookups. Tighten it around a smaller
  # reflection interface shared by checker and runtime message access.
  @type provider :: term()
  @type schema :: term()
  @type field_ref ::
          %{required(:message) => atom(), required(:field) => atom()}
          | %{required(:message) => atom(), required(:extension) => atom()}

  # What checking a message literal needs to know about one of its fields:
  # whether it is singular, repeated, a map or in a oneof (and which), whether it
  # holds an enum, and the full name of the message it holds, if any.
  @type literal_field :: %{
          required(:cardinality) => :singular | :repeated | :map | :oneof,
          required(:oneof_name) => atom() | nil,
          required(:enum?) => boolean(),
          required(:message_type) => String.t() | nil
        }

  @callback normalize(term()) :: provider()
  @callback known_message?(provider(), atom() | String.t()) :: boolean()
  @callback known_enum?(provider(), atom() | String.t()) :: boolean()
  @callback resolve_message(provider(), atom() | String.t()) :: {:ok, atom()} | :error
  @callback resolve_enum(provider(), atom() | String.t()) :: {:ok, atom()} | :error
  @callback enum_value(provider(), String.t()) ::
              {:ok,
               %{
                 required(:enum) => atom(),
                 required(:value) => atom(),
                 required(:number) => integer()
               }}
              | :unknown_enum
              | :unknown_value
  @callback enum_number(provider(), atom(), String.t()) :: {:ok, integer()} | :error
  @callback field(provider(), atom() | String.t(), atom() | String.t()) ::
              {:ok,
               %{
                 required(:message) => atom(),
                 required(:field) => atom(),
                 required(:info) => map()
               }}
              | :unknown_message
              | :unknown_field
  @callback extension(provider(), atom() | String.t(), atom() | String.t()) ::
              {:ok,
               %{
                 required(:message) => atom(),
                 required(:extension) => atom(),
                 required(:info) => map()
               }}
              | :unknown_message
              | :unknown_extension
  # `field/3` and `extension/3` return a field's `:info` for the provider's
  # own use; CEL reads it only through the provider.
  @callback field_type(provider(), map()) :: {:ok, CEL.ProtoType.t()} | {:error, String.t()}
  @callback literal_field(provider(), atom(), map()) :: literal_field()
  @callback required_fields(provider(), atom()) :: [atom()]
end

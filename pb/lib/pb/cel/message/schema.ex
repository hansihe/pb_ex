defmodule PB.CEL.Message.Schema do
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

  @callback normalize(term()) :: provider()
  @callback known_message?(provider(), atom() | String.t()) :: boolean()
  @callback known_enum?(provider(), atom() | String.t()) :: boolean()
  @callback fetch_message(provider(), atom() | String.t()) :: {:ok, map()} | :error
  @callback fetch_enum(provider(), atom() | String.t()) :: {:ok, map()} | :error
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
  @callback field_info_ref(provider(), field_ref()) :: {:ok, map()} | :error
  @callback field_type(provider(), map()) :: {:ok, PB.CEL.ProtoType.t()} | {:error, String.t()}
end

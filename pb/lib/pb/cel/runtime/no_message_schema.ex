defmodule PB.CEL.Runtime.NoMessageSchema do
  @moduledoc false

  # Default `PB.CEL.Message.Schema` used when no schema-reflection provider is
  # injected. The CEL subsystem does not bind to PB's compiled-schema
  # representation; a host that checks/evaluates against a protobuf schema
  # injects `PB.Validate.CEL.MessageSchema` via `PB.CEL.Env`'s `:message_schema`.
  #
  # With no provider there are no known message/enum/field types — schema-less
  # CEL (pure values, no message/enum references) still checks and evaluates.
  # Supplying a schema without a provider to interpret it is an error: `normalize/1`
  # rejects a non-nil schema so the gap surfaces immediately instead of silently
  # reporting every type as unknown.

  @behaviour PB.CEL.Message.Schema

  @impl true
  def normalize(nil), do: nil

  def normalize(schema) do
    raise ArgumentError,
          "a CEL schema was provided without a :message_schema provider to interpret it; " <>
            "pass message_schema: PB.Validate.CEL.MessageSchema (or another " <>
            "PB.CEL.Message.Schema implementation). Got: #{inspect(schema)}"
  end

  @impl true
  def known_message?(_provider, _name), do: false

  @impl true
  def known_enum?(_provider, _name), do: false

  @impl true
  def fetch_message(_provider, _name), do: :error

  @impl true
  def fetch_enum(_provider, _name), do: :error

  @impl true
  def resolve_message(_provider, _name), do: :error

  @impl true
  def resolve_enum(_provider, _name), do: :error

  @impl true
  def enum_value(_provider, _name), do: :unknown_enum

  @impl true
  def field(_provider, _message, _field), do: :unknown_message

  @impl true
  def extension(_provider, _message, _extension), do: :unknown_message

  @impl true
  def field_info_ref(_provider, _field_ref), do: :error

  @impl true
  def field_type(_provider, _field), do: {:error, "no schema provider configured"}
end

defmodule PB.CEL.MessageSchema do
  @moduledoc false

  # Lookups in PB's compiled schema (`%{messages:, enums:, services:}` and
  # `PB.Schema.Compiled` structs) for the protobuf binding, by PB's atom names
  # or by text. Text becomes a name only through `String.to_existing_atom/1`:
  # a name that is not an existing atom cannot be in an atom-keyed schema.

  @type schema :: PB.schema() | nil
  @type message_ref :: PB.Schema.Compiled.message_name()
  @type enum_ref :: PB.Schema.Compiled.enum_name()

  # A `use PB.Schema` module's schema is read when it is needed, a
  # `:persistent_term` lookup, so a provider holding the module stays small.
  @spec schema(PB.schema() | module | nil) :: schema
  def schema(nil), do: nil
  def schema(module) when is_atom(module), do: module.__pb_schema__()
  def schema(%{messages: _messages, enums: _enums} = schema), do: schema

  @spec fetch_message(schema, atom | String.t()) ::
          {:ok, PB.Schema.Compiled.message()} | :error
  def fetch_message(schema, name) do
    with {:ok, message} <- resolve_message(schema, name) do
      Map.fetch(schema.messages, message)
    end
  end

  @spec resolve_message(schema, atom | String.t()) :: {:ok, message_ref} | :error
  def resolve_message(nil, _name), do: :error

  def resolve_message(%{messages: messages}, name) when is_atom(name) do
    if Map.has_key?(messages, name), do: {:ok, name}, else: :error
  end

  def resolve_message(schema, name) when is_binary(name) do
    with {:ok, atom} <- existing_atom(strip_leading_dot(name)), do: resolve_message(schema, atom)
  end

  @spec resolve_enum(schema, atom | String.t()) :: {:ok, enum_ref} | :error
  def resolve_enum(nil, _name), do: :error

  def resolve_enum(%{enums: enums}, name) when is_atom(name) do
    if Map.has_key?(enums, name), do: {:ok, name}, else: :error
  end

  def resolve_enum(schema, name) when is_binary(name) do
    with {:ok, atom} <- existing_atom(strip_leading_dot(name)), do: resolve_enum(schema, atom)
  end

  @spec existing_atom(String.t()) :: {:ok, atom} | :error
  def existing_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp strip_leading_dot("." <> name), do: name
  defp strip_leading_dot(name), do: name
end

defmodule CEL.TypeProvider.Empty do
  @moduledoc false

  # The provider of an environment built without `:types`: it knows no message
  # or enum types, so an expression can use only CEL's own types. A message
  # value bound directly still compares by its payload.

  @behaviour CEL.TypeProvider

  @impl true
  def find_type(_state, _name), do: :error

  @impl true
  def find_field(_state, _message, _field), do: :error

  @impl true
  def enum_value(_state, _enum, _value), do: :error

  @impl true
  def new_message(_state, message, _fields), do: {:error, {:unknown_message, message}}

  @impl true
  def from_native(_state, name, _value), do: {:error, {:unknown_type, name}}

  # Unreachable: with no message types there are no fields to read.
  @impl true
  def get_field(_state, _payload, field), do: {:error, {:unknown_field, field.name}}

  @impl true
  def has_field?(_state, _payload, _field), do: false

  @impl true
  def equal?(_state, _message, left, right), do: left == right
end

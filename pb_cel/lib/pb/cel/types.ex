defmodule PB.CEL.Types do
  @moduledoc false

  # The `CEL.TypeProvider` for a PB schema, as `PB.CEL.types/1` returns it.
  # Its state is a `use PB.Schema` module, whose schema each call reads, or a
  # compiled schema. Names are PB's atoms; text from an expression becomes one
  # only through `String.to_existing_atom/1`, in `PB.CEL.MessageSchema`.

  @behaviour CEL.TypeProvider

  alias CEL.Value
  alias PB.CEL.MessageRuntime
  alias PB.CEL.MessageSchema, as: Schema
  alias PB.CEL.Schema.Field

  @min_int32 -2_147_483_648
  @max_int32 2_147_483_647

  @impl true
  def find_type(state, name) do
    %{messages: messages, enums: enums} = Schema.schema(state)

    with {:ok, atom} <- Schema.existing_atom(name) do
      cond do
        is_map_key(messages, atom) -> {:ok, :message, atom}
        is_map_key(enums, atom) -> {:ok, :enum, atom}
        true -> :error
      end
    end
  end

  # Extensions are keyed by their full names, which a declared field's name
  # never is.
  @impl true
  def find_field(state, message, name) do
    schema = Schema.schema(state)

    with {:ok, msg} <- Map.fetch(schema.messages, message),
         {:ok, atom} <- Schema.existing_atom(name) do
      case Map.fetch(msg.fields_by_name, atom) do
        {:ok, info} ->
          cel_field(schema, msg, name, info, {:field, message, atom})

        :error ->
          with {:ok, info} <- Map.fetch(msg.extensions_by_name, atom) do
            cel_field(schema, msg, name, info, {:extension, message, atom})
          end
      end
    end
  end

  @impl true
  def enum_value(state, enum, name) do
    with {:ok, %{by_name: by_name}} <- Map.fetch(Schema.schema(state).enums, enum),
         {:ok, value} <- Schema.existing_atom(name) do
      Map.fetch(by_name, value)
    end
  end

  @impl true
  def required_fields(state, message) do
    %{fields_by_name: fields} = Map.fetch!(Schema.schema(state).messages, message)
    for {name, %{presence: :required}} <- fields, do: Atom.to_string(name)
  end

  @impl true
  def new_message(state, message, fields),
    do: MessageRuntime.new_message(Schema.schema(state), message, fields)

  # An enum binds as PB decodes an enum field: a value's name as an atom, or
  # its number.
  @impl true
  def from_native(state, name, value) do
    schema = Schema.schema(state)

    case Map.fetch(schema.enums, name) do
      {:ok, enum} -> enum_from_native(name, enum, value)
      :error -> MessageRuntime.from_decoded(schema, name, value)
    end
  end

  @impl true
  def get_field(state, payload, %CEL.Field{ref: ref}),
    do: MessageRuntime.get_field(Schema.schema(state), ref, payload)

  @impl true
  def has_field?(state, payload, %CEL.Field{ref: ref}),
    do: MessageRuntime.has_field?(Schema.schema(state), ref, payload)

  @impl true
  def equal?(state, message, left, right),
    do: MessageRuntime.equal?(Schema.schema(state), message, left, right)

  @impl true
  def unpack_any(state, type_url, value),
    do: MessageRuntime.unpack_any(Schema.schema(state), type_url, value)

  defp cel_field(schema, msg, name, info, ref) do
    case Field.cel_type(schema, info) do
      {:ok, type} ->
        oneof = oneof(msg, info)
        {:ok, %CEL.Field{name: name, type: type, kind: info.cardinality, oneof: oneof, ref: ref}}

      {:error, _reason} ->
        :error
    end
  end

  defp oneof(msg, %{presence: :oneof, oneof_index: index}) do
    case msg.oneofs[index] do
      %{name: name} -> name
      _other -> nil
    end
  end

  defp oneof(_msg, _info), do: nil

  defp enum_from_native(name, %{by_name: by_name}, value)
       when is_atom(value) and value not in [nil, true, false] do
    case Map.fetch(by_name, value) do
      {:ok, number} ->
        {:ok, Value.enum(name, number)}

      :error ->
        value = inspect(Atom.to_string(value))
        {:error, "unknown enum value #{value} for #{inspect(Atom.to_string(name))}"}
    end
  end

  defp enum_from_native(name, _enum, value)
       when is_integer(value) and value >= @min_int32 and value <= @max_int32,
       do: {:ok, Value.enum(name, value)}

  defp enum_from_native(_name, _enum, value) when is_integer(value),
    do: {:error, "enum value is out of int32 range"}

  defp enum_from_native(name, _enum, value),
    do: {:error, "cannot convert #{inspect(value)} to #{Atom.to_string(name)}"}
end

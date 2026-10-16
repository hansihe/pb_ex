defmodule PB.CEL.MessageSchema do
  @moduledoc false

  # Protobuf-backed implementation of the `PB.CEL.Message.Schema` behaviour.
  #
  # Schema reflection over PB's compiled-schema representation
  # (`%{messages:, enums:, services:}` + `PB.Schema.Compiled` field structs): the
  # checker and evaluator resolve message/enum/field names and types through this
  # provider. It is part of the protobuf binding (`lib/pb_cel`) so the CEL
  # subsystem carries no concrete protobuf provider; callers inject it via
  # `PB.CEL.Env`'s `:message_schema`. CEL's own default is the no-op
  # `PB.CEL.Runtime.NoMessageSchema`.

  alias PB.CEL.Schema.Field
  alias PB.CEL.ProtoType

  @behaviour PB.CEL.Message.Schema

  @type schema :: PB.schema() | nil
  @type message_ref :: PB.Schema.Compiled.message_name()
  @type enum_ref :: PB.Schema.Compiled.enum_name()
  @type field_ref ::
          %{
            required(:message) => message_ref(),
            required(:field) => PB.Schema.Compiled.field_name()
          }
          | %{
              required(:message) => message_ref(),
              required(:extension) => PB.Schema.Compiled.extension_name()
            }

  @spec normalize(PB.schema() | module | nil) :: schema
  def normalize(nil), do: nil

  def normalize(%{messages: messages, enums: enums, services: services} = schema)
      when is_map(messages) and is_map(enums) and is_map(services),
      do: schema

  def normalize(module) when is_atom(module) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :schema, 0) ->
        normalize(module.schema())

      function_exported?(module, :__pb_schema__, 0) ->
        normalize(module.__pb_schema__())

      true ->
        raise ArgumentError,
              "expected PB schema map or schema module, got: #{inspect(module)}"
    end
  end

  @spec known_message?(schema, atom | String.t()) :: boolean
  def known_message?(schema, name), do: match?({:ok, _message}, resolve_message(schema, name))

  @spec known_enum?(schema, atom | String.t()) :: boolean
  def known_enum?(schema, name), do: match?({:ok, _enum}, resolve_enum(schema, name))

  @spec fetch_message(schema, atom | String.t()) ::
          {:ok, PB.Schema.Compiled.message()} | :error
  def fetch_message(schema, name) do
    with {:ok, message} <- resolve_message(schema, name),
         {:ok, info} <- fetch_message_info(schema, message) do
      {:ok, info}
    else
      :error -> :error
    end
  end

  @spec fetch_enum(schema, atom | String.t()) :: {:ok, PB.Schema.Compiled.enum()} | :error
  def fetch_enum(schema, name) do
    with {:ok, enum} <- resolve_enum(schema, name),
         {:ok, info} <- fetch_enum_info(schema, enum) do
      {:ok, info}
    else
      :error -> :error
    end
  end

  @spec resolve_message(schema, atom | String.t()) :: {:ok, message_ref} | :error
  def resolve_message(nil, _name), do: :error

  def resolve_message(%{messages: messages}, name) when is_atom(name) do
    if Map.has_key?(messages, name), do: {:ok, name}, else: :error
  end

  def resolve_message(%{messages: messages}, name) when is_binary(name) do
    name = strip_leading_dot(name)

    case existing_atom(name) do
      {:ok, atom} -> resolve_message(%{messages: messages}, atom)
      :error -> :error
    end
  end

  @spec resolve_enum(schema, atom | String.t()) :: {:ok, enum_ref} | :error
  def resolve_enum(nil, _name), do: :error

  def resolve_enum(%{enums: enums}, name) when is_atom(name) do
    if Map.has_key?(enums, name), do: {:ok, name}, else: :error
  end

  def resolve_enum(%{enums: enums}, name) when is_binary(name) do
    name = strip_leading_dot(name)

    case existing_atom(name) do
      {:ok, atom} -> resolve_enum(%{enums: enums}, atom)
      :error -> :error
    end
  end

  @spec enum_value(schema, String.t()) ::
          {:ok,
           %{
             required(:enum) => atom(),
             required(:value) => atom(),
             required(:number) => integer()
           }}
          | :unknown_enum
          | :unknown_value
  def enum_value(schema, name) when is_binary(name) do
    name = strip_leading_dot(name)

    with {:ok, enum_name, value_name} <- split_enum_value_name(name),
         {:ok, enum} <- resolve_enum(schema, enum_name),
         {:ok, info} <- fetch_enum_info(schema, enum),
         {:ok, value} <- existing_atom(value_name),
         {:ok, number} <- fetch_enum_number(info, value) do
      {:ok, %{enum: enum, value: value, number: number}}
    else
      :unknown_value -> :unknown_value
      :error -> :unknown_enum
    end
  end

  @spec field(schema, atom | String.t(), atom | String.t()) ::
          {:ok,
           %{
             required(:message) => message_ref(),
             required(:field) => PB.Schema.Compiled.field_name(),
             required(:info) => PB.Schema.Compiled.field()
           }}
          | :unknown_message
          | :unknown_field
  def field(schema, message_name, field_name) do
    with {:ok, message} <- resolve_message(schema, message_name),
         {:ok, msg} <- fetch_message_info(schema, message),
         {:ok, field, info} <- resolve_field(msg, field_name) do
      {:ok, %{message: message, field: field, info: info}}
    else
      :error -> :unknown_message
      :unknown_field -> :unknown_field
    end
  end

  @spec extension(schema, atom | String.t(), atom | String.t()) ::
          {:ok,
           %{
             required(:message) => message_ref(),
             required(:extension) => PB.Schema.Compiled.extension_name(),
             required(:info) => PB.Schema.Compiled.field()
           }}
          | :unknown_message
          | :unknown_extension
  def extension(schema, message_name, extension_name) do
    case resolve_message(schema, message_name) do
      {:ok, message} ->
        with {:ok, msg} <- fetch_message_info(schema, message),
             {:ok, extension} <- existing_atom(strip_leading_dot(to_string(extension_name))),
             {:ok, info} <- Map.fetch(msg.extensions_by_name, extension) do
          {:ok, %{message: message, extension: extension, info: info}}
        else
          _other -> :unknown_extension
        end

      :error ->
        :unknown_message
    end
  end

  @spec field_info_ref(schema, field_ref()) :: {:ok, PB.Schema.Compiled.field()} | :error
  def field_info_ref(nil, %{message: message, field: field})
      when is_atom(message) and is_atom(field),
      do: :error

  def field_info_ref(schema, %{message: message, field: field})
      when is_atom(message) and is_atom(field) do
    with {:ok, msg} <- fetch_message_info(schema, message) do
      Map.fetch(msg.fields_by_name, field)
    end
  end

  def field_info_ref(nil, %{message: message, extension: extension})
      when is_atom(message) and is_atom(extension),
      do: :error

  def field_info_ref(schema, %{message: message, extension: extension})
      when is_atom(message) and is_atom(extension) do
    with {:ok, msg} <- fetch_message_info(schema, message) do
      Map.fetch(msg.extensions_by_name, extension)
    end
  end

  @spec field_type(schema, PB.Schema.Compiled.field()) ::
          {:ok, ProtoType.t()} | {:error, String.t()}
  def field_type(schema, field), do: Field.cel_type(schema, field)

  defp fetch_message_info(%{messages: messages}, message), do: Map.fetch(messages, message)
  defp fetch_enum_info(%{enums: enums}, enum), do: Map.fetch(enums, enum)

  defp fetch_enum_number(%{by_name: by_name}, value) do
    case Map.fetch(by_name, value) do
      {:ok, number} -> {:ok, number}
      :error -> :unknown_value
    end
  end

  defp resolve_field(%{fields_by_name: fields}, field) when is_atom(field) do
    case Map.fetch(fields, field) do
      {:ok, info} -> {:ok, field, info}
      :error -> :unknown_field
    end
  end

  defp resolve_field(%{fields_by_name: fields}, field) when is_binary(field) do
    case existing_atom(field) do
      {:ok, atom} ->
        resolve_field(%{fields_by_name: fields}, atom)

      :error ->
        :unknown_field
    end
  end

  defp strip_leading_dot("." <> name), do: name
  defp strip_leading_dot(name), do: name

  defp split_enum_value_name(name) do
    case String.split(name, ".", trim: true) do
      [_only] ->
        :error

      parts ->
        {value, enum_parts} = List.pop_at(parts, -1)
        {:ok, Enum.join(enum_parts, "."), value}
    end
  end

  defp existing_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end

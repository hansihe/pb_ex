defmodule PB.Validate.CELExtensions.Rules do
  @moduledoc false

  alias PB.Validate.CEL.FieldReader
  alias PB.Validate.CEL.MessageSchema, as: Schema

  @type result :: {:ok, PB.CEL.Value.t()} | {:error, String.t()}

  @spec get_field([PB.CEL.Value.t()], PB.schema()) :: result
  def get_field([{:message, message, fields}, {:string, field}], schema) do
    with {:ok, msg} <- Schema.fetch_message(schema, message),
         {:ok, field_name, info} <- fetch_field(msg, field),
         {:ok, value} <- FieldReader.read(schema, msg, fields, field_name, info) do
      {:ok, value}
    else
      :error -> {:error, "no such field #{inspect(field)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def get_field(_values, _schema), do: {:error, "no such overload"}

  @spec unique([PB.CEL.Value.t()], PB.schema()) :: result
  def unique([{:list, values}], schema) do
    {:ok, PB.CEL.Value.bool(unique_values?(values, schema))}
  end

  def unique(_values, _schema), do: {:error, "no such overload"}

  defp fetch_field(%{fields_by_name: fields}, field) do
    Enum.find_value(fields, :error, fn {name, info} ->
      if Atom.to_string(name) == field, do: {:ok, name, info}
    end)
  end

  defp unique_values?([], _schema), do: true

  defp unique_values?([value | rest], schema),
    do: unique_value?(value, rest, schema) and unique_values?(rest, schema)

  defp unique_value?(value, rest, schema) do
    Enum.all?(rest, fn candidate ->
      not PB.CEL.Runtime.Core.equal?(value, candidate, schema)
    end)
  end
end

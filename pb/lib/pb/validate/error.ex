defmodule PB.Validate.Error do
  @moduledoc """
  Structured validation failure.

  Non-bang validation returns `{:error, %PB.Validate.Error{}}`. Bang
  validation raises the same struct as an exception. The `violations` list uses
  `PB.Validate.Violation`, which is richer than the canonical protobuf wire
  shape.
  """

  alias PB.Validate.Violation

  @type t :: %__MODULE__{
          operation: :validate,
          message_name: PB.message_name() | nil,
          violations: [Violation.t()]
        }

  defexception operation: :validate, message_name: nil, violations: []

  @impl Exception
  def message(%__MODULE__{message_name: message_name, violations: violations}) do
    prefix = message_prefix(message_name)

    case violations do
      [] ->
        prefix

      [violation] ->
        "#{prefix}: #{format_violation(violation)}"

      _violations ->
        "#{prefix} with #{length(violations)} violations: " <>
          (violations
           |> Enum.take(3)
           |> Enum.map_join("; ", &format_violation/1))
    end
  end

  defp message_prefix(nil), do: "validation failed"
  defp message_prefix(message_name), do: "validation failed for #{inspect(message_name)}"

  defp format_violation(%Violation{} = violation) do
    [violation.rule_id, violation.message, format_field(violation.field)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp format_violation(violation) when is_map(violation) do
    [violation[:rule_id], violation[:message], format_field(violation[:field])]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp format_field(nil), do: nil

  defp format_field(%{elements: elements}) do
    path =
      elements
      |> Enum.map(&Map.get(&1, :field_name))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(".")

    if path == "", do: nil, else: "(#{path})"
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end

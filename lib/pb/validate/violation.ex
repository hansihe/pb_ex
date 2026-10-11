defmodule PB.Validate.Violation do
  @moduledoc """
  Rich application-facing protovalidate violation.

  This struct may contain more diagnostic information than the canonical
  `buf.validate.Violation` wire shape. Use `PB.Validate.to_proto_violations/1`
  when an exact protobuf result is needed.
  """

  alias PB.Validate.Path

  @typedoc """
  A path to a field or rule, as `buf.validate.FieldPath`: a map with
  `:elements`, each describing one step.
  """
  @type field_path :: %{required(:elements) => [map()]}

  @type t :: %__MODULE__{
          rule_id: String.t(),
          field: field_path | nil,
          rule: field_path | nil,
          proto_rule: field_path | nil,
          message: String.t() | nil,
          source: String.t() | nil,
          for_key: boolean | nil
        }

  @enforce_keys [:rule_id]
  defstruct [
    :rule_id,
    :field,
    :rule,
    :proto_rule,
    :message,
    :source,
    :for_key
  ]

  @doc false
  @spec to_proto(t | map) :: map
  def to_proto(%__MODULE__{} = violation) do
    %{}
    |> maybe_put(:rule_id, violation.rule_id)
    |> maybe_put(:field, Path.canonical_field_path(violation.field))
    |> maybe_put(:rule, violation.proto_rule)
    |> maybe_put(:message, violation.message)
    |> maybe_put(:for_key, violation.for_key)
  end

  def to_proto(violation) when is_map(violation) do
    violation
    |> Map.drop([:__struct__, :source, :proto_rule])
    |> canonical_rule(violation)
  end

  defp canonical_rule(proto, %{proto_rule: proto_rule}) do
    proto
    |> Map.delete(:rule)
    |> maybe_put(:rule, proto_rule)
  end

  defp canonical_rule(proto, _violation), do: proto

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule PB.Validate.Compiler.Context do
  @moduledoc false

  # Threading context for `PB.Validate.Compiler`.
  #
  # Standard (predefined) rule compilation type-checks against a schema that has
  # buf.validate, descriptor.proto, and the well-known types merged in. Building
  # that merged schema is expensive, so the context builds it once for the whole
  # annotation pass instead of rebuilding it per field/rule, and carries it next
  # to the user's own schema as an explicit input.

  alias PB.Validate.Schema, as: ValidateSchema

  @extensions :__extensions__
  @field_rules :"buf.validate.field"

  @enforce_keys [:user_schema]
  defstruct [:user_schema, :rule_schema]

  @type t :: %__MODULE__{user_schema: PB.schema(), rule_schema: PB.schema() | nil}

  @doc """
  Builds a context for `schema`.

  The merged standard-rule schema is precomputed only when the draft schema
  carries standard (typed) `buf.validate.field` rules, so encode/decode-only and
  structural-only schemas pay nothing. `PB.Schema.Main` itself compiles through
  `PB.compile/2`, so the precompute is also skipped until `Main` is loaded — its
  own draft never carries standard rules, so this only matters as a guard.
  """
  @spec new(PB.schema()) :: t()
  def new(schema) when is_map(schema) do
    rule_schema =
      if Code.ensure_loaded?(PB.Schema.Main) and draft_uses_standard_rules?(schema) do
        ValidateSchema.standard_rule_schema(schema)
      end

    %__MODULE__{user_schema: schema, rule_schema: rule_schema}
  end

  @doc """
  Returns the merged standard-rule schema.

  Uses the value precomputed by `new/1` when present and recomputes it otherwise,
  so the field compilers stay correct even if the draft detector did not flag the
  schema.
  """
  @spec rule_schema(t()) :: PB.schema()
  def rule_schema(%__MODULE__{rule_schema: nil, user_schema: user_schema}),
    do: ValidateSchema.standard_rule_schema(user_schema)

  def rule_schema(%__MODULE__{rule_schema: rule_schema}), do: rule_schema

  @doc false
  @spec fetch_message(PB.schema(), atom()) :: {:ok, map()} | :error
  def fetch_message(schema, message_name) do
    case Map.fetch(schema.messages, message_name) do
      {:ok, %{kind: :message} = message} -> {:ok, message}
      _other -> :error
    end
  end

  @doc false
  @spec fetch_field(map(), atom()) :: {:ok, map()} | :error
  def fetch_field(%{fields_by_name: fields}, name), do: Map.fetch(fields, name)

  @doc false
  @spec fetch_enum(PB.schema(), map()) :: {:ok, map()} | :error
  def fetch_enum(%{enums: enums}, %{type: :TYPE_ENUM, type_name: type_name}),
    do: Map.fetch(enums, type_name)

  def fetch_enum(_schema, _field), do: :error

  # Standard-rule compilation (predefined CEL, native ops, repeated/map nesting)
  # runs only for fields whose buf.validate.field rules carry a typed rule family
  # (`%{type: {family, value}}`). Detecting that on the draft lets new/1 build the
  # merged schema exactly when those paths will need it.
  defp draft_uses_standard_rules?(schema) do
    schema
    |> Map.get(:messages, %{})
    |> Map.values()
    |> Enum.any?(&message_uses_standard_rules?/1)
  end

  defp message_uses_standard_rules?(%{fields_by_name: fields}) do
    Enum.any?(fields, fn {_name, field} -> field_uses_standard_rules?(field) end)
  end

  defp message_uses_standard_rules?(_message), do: false

  defp field_uses_standard_rules?(field) do
    field
    |> Map.get(:options, %{})
    |> Map.get(@extensions, %{})
    |> Map.get(@field_rules)
    |> case do
      %{type: {_family, value}} when is_map(value) -> true
      _other -> false
    end
  end
end

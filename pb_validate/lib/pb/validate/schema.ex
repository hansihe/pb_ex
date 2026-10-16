defmodule PB.Validate.Schema do
  @moduledoc false

  # Validation metadata stored in compiled PB schemas.
  #
  # `PB.Validate.compile/2` stores validation metadata under an entry's
  # `PB.Validate` key, as `PB.Schema.Plugin` lays out. Message, field, oneof, and
  # extension entries may all carry this key, and so does the schema itself
  # (see `attach_standard_rule_schema/1`).
  # The map is intentionally plain data so compiled schemas remain inspectable:
  #
  #   * `:cel` is a list of `%PB.Validate.Schema.CELOp{}` operations.
  #   * `:native` is a list of `%PB.Validate.Schema.NativeOp{}`
  #     operations for standard rules that are not expressed as CEL.
  #   * `:predefined` is `%PB.Validate.Schema.Predefined{}` on descriptor
  #     fields that define canonical protovalidate CEL rules.
  #   * `:repeated` is `%PB.Validate.Schema.RepeatedRules{}` for nested
  #     repeated item validation.
  #   * `:map` is `%PB.Validate.Schema.MapRules{}` for nested map key/value
  #     validation.
  #   * structural flags such as `:required`, `:ignore`, `:disabled`, and
  #     `:message_oneofs` are stored directly in the `PB.Validate` map.

  alias PB.Schema.Prepare
  alias PB.Validate.Compiler.Extensions
  alias PB.Validate.Path

  defmodule CELSource do
    @moduledoc false

    # Source form of a CEL validation rule before parsing and type-checking.

    @type t :: %__MODULE__{
            id: String.t(),
            message: String.t(),
            expression: String.t()
          }

    @enforce_keys [:id, :message, :expression]
    defstruct [:id, :message, :expression]
  end

  defmodule CELOp do
    @moduledoc false

    # Parsed and checked CEL validation operation in a compiled schema.
    #
    # `:vars` contains runtime bindings other than `"this"`. User CEL rules have
    # no extra bindings. Predefined rules bind `"rules"` to the containing rules
    # message and `"rule"` to the concrete rule field value.

    alias CEL.Checked

    @type kind :: :message_cel | :field_cel | :predefined
    @type field_path :: PB.Validate.Path.field_path()

    @type t :: %__MODULE__{
            kind: kind(),
            id: String.t(),
            message: String.t(),
            source: String.t(),
            checked: Checked.t(),
            vars: %{String.t() => term()},
            regexes: %{Checked.expr_id() => Regex.t()},
            rule_path: field_path() | nil,
            proto_rule_path: field_path() | nil
          }

    @enforce_keys [:kind, :id, :message, :source, :checked]
    defstruct [
      :kind,
      :id,
      :message,
      :source,
      :checked,
      vars: %{},
      regexes: %{},
      rule_path: nil,
      proto_rule_path: nil
    ]
  end

  defmodule Predefined do
    @moduledoc false

    # Canonical protovalidate CEL attached to a rule descriptor field.

    alias PB.Validate.Schema.CELSource

    @type t :: %__MODULE__{cel: [CELSource.t()]}

    defstruct cel: []
  end

  defmodule NativeOp do
    @moduledoc false

    # Compiled native validation operation.
    #
    # Native operations cover standard protovalidate rules that do not have a
    # canonical CEL expression in the bundled validate descriptors.
    #
    # `:values` is kind-specific and keeps the operation self-contained:
    # `:any_in` and `:any_not_in` store type URLs, while `:enum_defined_only`
    # stores accepted enum runtime representations, both numbers and atoms.

    @type kind :: :any_in | :any_not_in | :enum_defined_only
    @type field_path :: PB.Validate.Path.field_path()

    @type t :: %__MODULE__{
            kind: kind(),
            id: String.t(),
            message: String.t(),
            values: [term()],
            rule_path: field_path() | nil,
            proto_rule_path: field_path() | nil
          }

    @enforce_keys [:kind, :id, :message, :values]
    defstruct [:kind, :id, :message, values: [], rule_path: nil, proto_rule_path: nil]
  end

  defmodule RuleSet do
    @moduledoc false

    # Validation rules compiled for a field-like nested target.
    #
    # Used for repeated items, map keys, and map values. `:ignore` mirrors the
    # `buf.validate.FieldRules.ignore` setting for that nested target.

    alias PB.Validate.Schema.CELOp
    alias PB.Validate.Schema.NativeOp

    @type t :: %__MODULE__{
            cel: [CELOp.t()],
            native: [NativeOp.t()],
            ignore: atom() | nil
          }

    defstruct cel: [], native: [], ignore: nil
  end

  defmodule RepeatedRules do
    @moduledoc false

    # Nested validation rules for a repeated field.

    alias PB.Validate.Schema.RuleSet

    @type t :: %__MODULE__{items: RuleSet.t() | nil}

    defstruct items: nil
  end

  defmodule MapRules do
    @moduledoc false

    # Nested validation rules for a map field.

    alias PB.Validate.Schema.RuleSet

    @type t :: %__MODULE__{
            keys: RuleSet.t() | nil,
            values: RuleSet.t() | nil
          }

    defstruct keys: nil, values: nil
  end

  alias PB.Validate.Schema.CELOp
  alias PB.Validate.Schema.CELSource
  alias PB.Validate.Schema.MapRules
  alias PB.Validate.Schema.NativeOp
  alias PB.Validate.Schema.Predefined
  alias PB.Validate.Schema.RepeatedRules
  alias PB.Validate.Schema.RuleSet

  @type field_path :: CELOp.field_path()

  @doc false
  def cel_source(rule) when is_map(rule) do
    %CELSource{
      id: Map.get(rule, :id) || "",
      message: Map.get(rule, :message) || "",
      expression: Map.get(rule, :expression) || ""
    }
  end

  @doc false
  def predefined(rules) when is_list(rules) do
    %Predefined{cel: Enum.map(rules, &cel_source/1)}
  end

  @doc false
  def cel_op(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :vars, %{})

    struct!(CELOp, attrs)
  end

  @doc false
  def native_op(attrs) when is_map(attrs) do
    struct!(NativeOp, attrs)
  end

  @doc false
  def rule_set(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :cel, [])
    attrs = Map.put_new(attrs, :native, [])
    struct!(RuleSet, attrs)
  end

  @doc false
  def empty_rule_set?(nil), do: true

  def empty_rule_set?(%RuleSet{cel: cel, native: native, ignore: ignore}) do
    cel == [] and native == [] and is_nil(ignore)
  end

  @doc false
  def repeated_rules(attrs) when is_map(attrs), do: struct!(RepeatedRules, attrs)

  @doc false
  def map_rules(attrs) when is_map(attrs), do: struct!(MapRules, attrs)

  @doc false
  def empty_map_rules?(nil), do: true

  def empty_map_rules?(%MapRules{keys: keys, values: values}) do
    empty_rule_set?(keys) and empty_rule_set?(values)
  end

  @doc false
  def field_required_rule_path do
    Path.field_path([Path.rule_element(25, "required", :TYPE_BOOL)])
  end

  @doc false
  def field_cel_rule_path(index, prefix \\ []) when is_integer(index) and index >= 0 do
    Path.field_path(
      Enum.map(prefix, &Path.rule_field_element/1) ++
        [
          Path.rule_element(23, "cel", :TYPE_MESSAGE, {:index, index})
        ]
    )
  end

  @doc false
  def field_cel_expression_rule_path(index, prefix \\ []) when is_integer(index) and index >= 0 do
    Path.field_path(
      Enum.map(prefix, &Path.rule_field_element/1) ++
        [
          Path.rule_element(29, "cel_expression", :TYPE_STRING, {:index, index})
        ]
    )
  end

  @doc false
  def message_cel_rule_path(index) when is_integer(index) and index >= 0 do
    Path.field_path([Path.rule_element(3, "cel", :TYPE_MESSAGE, {:index, index})])
  end

  @doc false
  def message_cel_expression_rule_path(index) when is_integer(index) and index >= 0 do
    Path.field_path([Path.rule_element(5, "cel_expression", :TYPE_STRING, {:index, index})])
  end

  @doc false
  def rule_path(fields) when is_list(fields) do
    Path.field_path(Enum.map(fields, &Path.rule_field_element/1))
  end

  @doc """
  Returns `schema` with `PB.Validate`'s schema-level data, marking it as
  compiled for validation.

  The data holds the merged standard-rule schema (`with_standard_rule_schema/1`),
  a pure function of the compiled schema that merges all of `PB.Schema.Main` and
  re-runs `PB.Schema.Prepare.prepare/1` over the result. Predefined-rule CEL
  evaluation needs it on every op, so without precomputation `PB.Validate`
  rebuilds the whole schema per CEL op (scaling with schema size, not message
  size). It is only built when the schema has CEL ops that bind extra variables
  (only predefined rules do), so schemas without them pay nothing.

  Called once at the end of `PB.Validate.compile/2`, after the rules are
  compiled. Schema transforms drop this data with the rest of the plugin's data
  and compile the rules again.
  """
  @spec attach_standard_rule_schema(PB.schema()) :: PB.schema()
  def attach_standard_rule_schema(schema) when is_map(schema) do
    standard_rule_schema =
      if needs_standard_rule_schema?(schema), do: with_standard_rule_schema(schema)

    Map.put(schema, PB.Validate, %{standard_rule_schema: standard_rule_schema})
  end

  @doc """
  Whether `schema` was compiled with the `PB.Validate` plugin.
  """
  @spec compiled?(PB.schema()) :: boolean()
  def compiled?(schema), do: Map.has_key?(schema, PB.Validate)

  @doc """
  Returns the merged standard-rule schema for `schema`.

  Uses the value precomputed by `attach_standard_rule_schema/1` when present and
  computes it otherwise, as the rule compiler does before the value exists.
  """
  @spec standard_rule_schema(PB.schema()) :: PB.schema()
  def standard_rule_schema(schema) when is_map(schema) do
    case schema do
      %{PB.Validate => %{standard_rule_schema: %{} = prepared}} -> prepared
      _schema -> with_standard_rule_schema(schema)
    end
  end

  defp needs_standard_rule_schema?(schema) do
    schema
    |> Map.get(:messages, %{})
    |> Map.values()
    |> Enum.any?(&message_uses_standard_rules?/1)
  end

  defp message_uses_standard_rules?(message) do
    any_vars_op?(message_cel_ops(message)) or
      message
      |> Map.get(:fields_by_name, %{})
      |> Map.values()
      |> Enum.any?(&field_uses_standard_rules?/1)
  end

  defp field_uses_standard_rules?(field), do: field |> field_cel_ops() |> any_vars_op?()

  defp message_cel_ops(message), do: message |> Map.get(PB.Validate, %{}) |> Map.get(:cel, [])

  defp field_cel_ops(field) do
    validate = Map.get(field, PB.Validate, %{})

    Map.get(validate, :cel, []) ++
      rule_set_cel(repeated_items(validate)) ++
      rule_set_cel(map_rule_set(validate, :keys)) ++
      rule_set_cel(map_rule_set(validate, :values))
  end

  defp repeated_items(%{repeated: %RepeatedRules{items: items}}), do: items
  defp repeated_items(_validate), do: nil

  defp map_rule_set(%{map: %MapRules{} = map_rules}, key), do: Map.get(map_rules, key)
  defp map_rule_set(_validate, _key), do: nil

  defp rule_set_cel(%RuleSet{cel: cel}), do: cel
  defp rule_set_cel(_rule_set), do: []

  defp any_vars_op?(ops), do: Enum.any?(ops, fn op -> map_size(op.vars) > 0 end)

  # Merges PB.Schema.Main (buf.validate + descriptor.proto + well-known types)
  # into the user schema so predefined-rule CEL can type-check, then prepares the
  # result. The compiler builds this once per pass via `PB.Validate.Compiler.Context`
  # and `PB.Validate.compile/2` caches it on the schema (see
  # `attach_standard_rule_schema/1`), so this is no longer recomputed per rule.
  defp with_standard_rule_schema(schema) when is_map(schema) do
    main = PB.Schema.Main.schema()
    main = Map.put(main, :messages, standard_messages(main.messages))

    extensions_by_name =
      Map.merge(
        Map.fetch!(schema, :extensions_by_name),
        Map.fetch!(main, :extensions_by_name)
      )

    schema
    |> Map.put(:messages, merge_standard_messages(schema.messages, main.messages))
    |> Map.put(:enums, Map.merge(schema.enums, main.enums))
    |> Map.put(:extensions_by_name, extensions_by_name)
    |> attach_extensions_to_messages(extensions_by_name)
    |> Prepare.prepare()
  end

  # PB.Schema.Main is compiled without plugins, so the canonical CEL of its
  # standard rule fields (`buf.validate.predefined` on, say, `StringRules.email`)
  # is read from their options here, as the compiler does for user fields.
  defp standard_messages(messages) do
    Map.new(messages, fn {fqn, message} ->
      fields_by_name =
        Map.new(message.fields_by_name, fn {name, field} ->
          {name, Extensions.add_predefined_definition(field)}
        end)

      {fqn, Map.put(message, :fields_by_name, fields_by_name)}
    end)
  end

  defp merge_standard_messages(messages, standard_messages) do
    Map.merge(messages, standard_messages, fn _name, message, standard_message ->
      standard_message
      |> Map.put(
        :extensions_by_name,
        Map.merge(
          Map.fetch!(standard_message, :extensions_by_name),
          Map.fetch!(message, :extensions_by_name)
        )
      )
    end)
  end

  defp attach_extensions_to_messages(schema, extensions_by_name) do
    messages =
      Enum.reduce(extensions_by_name, schema.messages, fn
        {_name, %{extendee: extendee} = extension}, messages ->
          if Map.has_key?(messages, extendee) do
            Map.update!(messages, extendee, &attach_extension_to_message(&1, extension))
          else
            messages
          end

        _other, messages ->
          messages
      end)

    Map.put(schema, :messages, messages)
  end

  defp attach_extension_to_message(message, extension) do
    extensions_by_name =
      message.extensions_by_name
      |> Map.put(extension.name, extension)

    message
    |> Map.put(:extensions_by_name, extensions_by_name)
  end
end

defmodule PB.Validate do
  @moduledoc """
  Runtime protovalidate validation.

  Validation accepts the same public message term shape as `PB.encode/4`.
  Canonical maps, represented structs, identity oneofs, unwrapped messages, and
  adapted values are projected one message layer at a time before field rules,
  message rules, and CEL expressions read protobuf fields.

  Validation rule failures return `{:error, %PB.Validate.Error{}}`. Unknown
  messages, message-name metadata mismatches, values that do not match the
  message shape, and projection failures return the `PB.Error` struct
  `PB.encode/4` would (`PB.SchemaError` or `PB.ValueError`, with
  `operation: :validate`); a CEL rule that fails to evaluate returns
  `CEL.Error`. Those are errors rather than protovalidate violations, so
  they are not `PB.Validate.Error`s.

  Schemas may be supplied either as a compiled schema map or as a module that
  `use PB.Schema`, and must be compiled with this module as a plugin, which
  compiles the protovalidate rules in the schema's descriptor options:

      schema = PB.compile(descriptor_set, plugins: [PB.Validate])

      defmodule MyApp.Schema do
        use PB.Schema, descriptor: "priv/proto/schema.binpb", plugins: [PB.Validate]
      end

  Compiling raises `PB.Validate.CompileError` for rules that are not valid for
  the schema, and `PB.SchemaError` for a schema whose rules can't be read, as
  its descriptor set lacks `buf/validate/validate.proto`.
  """

  @behaviour PB.Schema.Plugin

  alias CEL.Evaluator
  alias PB.CEL.Schema.Field
  alias PB.CEL.FieldReader
  alias PB.CEL.MessageRuntime, as: CELMessage
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.MessageView
  alias PB.Runtime.Scalar
  alias PB.Schema.Features
  alias PB.Validate.Context
  alias PB.Validate.Error
  alias PB.Validate.Path
  alias PB.Validate.Schema, as: ValidateSchema
  alias PB.Validate.Schema.RuleSet
  alias PB.Validate.Violation

  require Field

  @message_name_key :__message_name__

  @type result :: :ok | {:error, Error.t() | PB.Error.t() | CEL.Error.t()}
  @typep validation_result :: :ok | {:error, Error.t()}
  @typep message_context :: %{
           required(:schema) => PB.schema(),
           required(:message_name) => PB.message_name(),
           required(:message) => PB.Schema.Compiled.message(),
           required(:data) => map(),
           required(:path) => [PB.Error.path_element()],
           required(:runtime) => Context.t(),
           required(:fields) => %{
             optional(atom()) => %{
               required(:present?) => boolean(),
               required(:zero?) => boolean(),
               required(:message_oneof_set?) => boolean()
             }
           }
         }

  @doc """
  Compiles the protovalidate rules of a prepared `schema` into it.

  This is the `PB.Schema.Plugin` callback; pass `plugins: [PB.Validate]` to
  `PB.compile/2` or `use PB.Schema` rather than calling it. It takes no options.
  """
  @impl PB.Schema.Plugin
  @spec compile(PB.schema(), keyword) :: PB.schema()
  def compile(schema, opts) when is_map(schema) do
    if opts != [] do
      raise PB.OptionError,
        kind: :unknown_options,
        operation: :compile,
        options: Keyword.keys(opts)
    end

    schema
    |> PB.Validate.Compiler.annotate()
    |> ValidateSchema.attach_standard_rule_schema()
  end

  @doc """
  Returns the functions `use PB.Schema` adds to a schema module compiled with
  this plugin: `validate/2,3` and `validate!/2,3`, which call `validate/4` and
  `validate!/4` with the module's schema.
  """
  @impl PB.Schema.Plugin
  @spec schema_functions(keyword) :: Macro.t()
  def schema_functions(_opts) do
    quote do
      @doc "Validates `data` as `message_name` using the schema embedded in this module."
      @spec validate(term, PB.message_name()) ::
              :ok | {:error, PB.Validate.Error.t()}
      @spec validate(term, PB.message_name(), keyword) ::
              :ok | {:error, PB.Validate.Error.t()}
      def validate(data, message_name, opts \\ []) do
        PB.Validate.validate(data, __pb_schema__(), message_name, opts)
      end

      @doc "Validates `data` as `message_name` using the schema embedded in this module, raising on rule failures."
      @spec validate!(term, PB.message_name()) :: :ok
      @spec validate!(term, PB.message_name(), keyword) :: :ok
      def validate!(data, message_name, opts \\ []) do
        PB.Validate.validate!(data, __pb_schema__(), message_name, opts)
      end
    end
  end

  @doc """
  Validates `data` as `message_name` using `schema`.

  Rule failures return `{:error, %PB.Validate.Error{}}`. Option failures return
  `{:error, %PB.OptionError{}}`, and unknown messages or values that do not
  match the message shape the `PB.Error` struct `PB.encode/4` would. A CEL rule
  that fails to evaluate returns `{:error, %CEL.Error{}}`. Raises
  `ArgumentError` if `schema` was not compiled with `plugins: [PB.Validate]`.

  Accepted options:

    * `:context` - a keyword list or map of context values, currently only
      `:now` (as below).
    * `:now` - timestamp used for CEL `now`: unix nanoseconds, `DateTime`, or
      a CEL timestamp tuple `{:timestamp, unix_nanoseconds}`.
  """
  @spec validate(term(), PB.schema_source(), PB.message_name(), keyword) :: result
  def validate(data, schema, message_name, opts \\ []) do
    result =
      with {:ok, opts} <- normalize_opts(opts),
           {:ok, context} <- validation_context(opts) do
        schema = compiled!(schema)

        schema
        |> collect_violations(message_name, data, context)
        |> result()
      end

    RuntimeErrors.normalize_result(result, :validate, message_name)
  rescue
    # Rules are evaluated by raising on the first error; the API returns it.
    error in [PB.SchemaError, PB.ValueError, PB.AdapterError, CEL.Error] ->
      {:error, RuntimeErrors.to_error(error, :validate, message_name)}
  end

  @doc """
  Validates `data` as `message_name` using `schema`, raising on validation or
  option failure.

  See `validate/4` for accepted options.
  """
  @spec validate!(term(), PB.schema_source(), PB.message_name(), keyword) ::
          :ok
  def validate!(data, schema, message_name, opts \\ []) do
    case validate(data, schema, message_name, opts) do
      :ok ->
        :ok

      {:error, %{__exception__: true} = error} ->
        raise error
    end
  end

  @doc """
  Converts validation violations to the canonical `buf.validate.Violations`
  protobuf field shape.
  """
  @spec to_proto_violations(validation_result | Error.t() | [Violation.t() | map]) :: %{
          required(:violations) => [map()]
        }
  def to_proto_violations(:ok), do: %{violations: []}
  def to_proto_violations({:error, %Error{} = error}), do: to_proto_violations(error)

  def to_proto_violations(%Error{violations: violations}) do
    to_proto_violations(violations)
  end

  def to_proto_violations(violations) when is_list(violations) do
    %{violations: Enum.map(violations, &Violation.to_proto/1)}
  end

  defp compiled!(schema_source) do
    schema = PB.__compiled__(schema_source)

    if ValidateSchema.compiled?(schema) do
      schema
    else
      what =
        if is_atom(schema_source), do: "schema module #{inspect(schema_source)}", else: "schema"

      raise ArgumentError,
            "the PB #{what} was not compiled for validation; " <>
              "compile it with `plugins: [PB.Validate]`"
    end
  end

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- [:context, :now]

      cond do
        unknown != [] ->
          {:error, {:unknown_options, unknown}}

        Keyword.has_key?(opts, :context) and invalid_context?(Keyword.fetch!(opts, :context)) ->
          {:error, {:invalid_option, :context, Keyword.fetch!(opts, :context)}}

        Keyword.has_key?(opts, :now) and invalid_now?(Keyword.fetch!(opts, :now)) ->
          {:error, {:invalid_option, :now, Keyword.fetch!(opts, :now)}}

        true ->
          {:ok, opts}
      end
    else
      {:error, {:invalid_options, RuntimeErrors.type_of(opts)}}
    end
  end

  defp normalize_opts(opts), do: {:error, {:invalid_options, RuntimeErrors.type_of(opts)}}

  defp invalid_context?(nil), do: false
  defp invalid_context?(%Context{}), do: false
  defp invalid_context?(context) when is_list(context), do: not Keyword.keyword?(context)
  defp invalid_context?(context) when is_map(context), do: false
  defp invalid_context?(_context), do: true

  defp invalid_now?(ns) when is_integer(ns), do: false
  defp invalid_now?(%DateTime{}), do: false
  defp invalid_now?({:timestamp, ns}) when is_integer(ns), do: false
  defp invalid_now?(_value), do: true

  defp validation_context(opts) do
    {:ok, Context.from_options(opts)}
  rescue
    ArgumentError ->
      option = if Keyword.has_key?(opts, :context), do: :context, else: :now
      {:error, {:invalid_option, option, Keyword.get(opts, option)}}
  end

  defp collect_violations(schema, message_name, data, context) do
    case Map.fetch(schema.messages, message_name) do
      {:ok, %{kind: :message} = message} ->
        data = project_message!(schema, message_name, message, data, [])
        {message_name, validate_message(schema, message_name, message, data, [], context)}

      {:ok, _message} ->
        {message_name, []}

      :error ->
        raise PB.SchemaError,
          operation: :validate,
          message_name: message_name,
          kind: :unknown_message,
          name: message_name
    end
  end

  defp result({_message_name, []}), do: :ok

  defp result({message_name, violations}),
    do: {:error, %Error{message_name: message_name, violations: violations}}

  defp project_message!(schema, message_name, message, data, path) do
    path = Path.api_path(path)

    case MessageView.to_proto_fields(schema, message_name, message, data, path) do
      {:ok, data} ->
        data

      {:error, reason} ->
        raise PB.ValueError,
          operation: :validate,
          message_name: message_name,
          kind: :invalid_value,
          path: path,
          expected: :map,
          got: data,
          reason: reason
    end
  end

  defp validate_message(schema, message_name, message, data, path, context)
       when is_map(data) and not is_struct(data) do
    validate_message_name!(data, message_name, path)

    if get_in(message, [PB.Validate, :disabled]) == true do
      []
    else
      ctx = message_context(schema, message_name, message, data, path, context)

      field_violations =
        message
        |> sorted_fields()
        |> Enum.flat_map(fn field ->
          validate_field(ctx, field)
        end)

      oneof_violations =
        message
        |> sorted_oneofs()
        |> Enum.flat_map(fn oneof -> validate_oneof(ctx, oneof) end)

      message_oneof_violations = validate_message_oneofs(ctx)
      cel_violations = validate_message_cel(ctx)

      field_violations ++ oneof_violations ++ message_oneof_violations ++ cel_violations
    end
  end

  defp validate_message(
         _schema,
         _message_name,
         %{PB.Validate => %{disabled: true}},
         _data,
         _path,
         _context
       ),
       do: []

  defp validate_message(_schema, message_name, _message, data, path, _context) do
    raise PB.ValueError,
      operation: :validate,
      message_name: message_name,
      kind: :invalid_value,
      path: Path.api_path(path),
      expected: :map,
      got: data,
      reason: "expected a message map"
  end

  defp validate_message_name!(%{@message_name_key => expected}, expected, _path), do: :ok

  defp validate_message_name!(%{@message_name_key => actual}, expected, path) do
    raise PB.ValueError,
      operation: :validate,
      message_name: expected,
      kind: :message_name_mismatch,
      path: Path.api_path(path) ++ [@message_name_key],
      expected: expected,
      got: actual
  end

  defp validate_message_name!(_data, _expected, _path), do: :ok

  @spec message_context(
          PB.schema(),
          PB.message_name(),
          PB.Schema.Compiled.message(),
          map(),
          [PB.Error.path_element()],
          Context.t()
        ) ::
          message_context()
  defp message_context(schema, message_name, message, data, path, runtime_context) do
    ctx = %{
      schema: schema,
      message_name: message_name,
      message: message,
      data: data,
      path: path,
      runtime: runtime_context
    }

    Map.put(ctx, :fields, field_states(ctx))
  end

  defp field_states(ctx) do
    ctx.message
    |> sorted_fields()
    |> Map.new(fn field ->
      present? = FieldReader.present?(ctx.schema, ctx.message, ctx.data, field.name, field)
      zero? = zero_value?(ctx.schema, ctx.message, ctx.data, field, present?)

      message_oneof_set? =
        if Features.has_presence?(field) do
          present?
        else
          present? and not zero?
        end

      {field.name, %{present?: present?, zero?: zero?, message_oneof_set?: message_oneof_set?}}
    end)
  end

  defp field_state(ctx, field), do: Map.fetch!(ctx.fields, field.name)

  defp validate_field(ctx, field) do
    validate = Map.get(field, PB.Validate, %{})

    cond do
      validate[:ignore] == :IGNORE_ALWAYS ->
        []

      required_missing?(ctx, field) ->
        [
          violation(
            "required",
            Path.field_path(ctx.path, field),
            ValidateSchema.field_required_rule_path(),
            "value is required"
          )
        ]

      unset_message_oneof_field?(ctx, field) ->
        []

      skip_unset_explicit_field?(ctx, field) ->
        []

      ignore_zero_field?(ctx, field) ->
        []

      true ->
        validate_field_native(ctx, field) ++
          validate_field_cel(ctx, field) ++
          validate_repeated_items(ctx, field) ++
          validate_map_entries(ctx, field) ++
          validate_nested_field(ctx, field)
    end
  end

  defp validate_field_native(ctx, field) do
    ops = get_in(field, [PB.Validate, :native]) || []

    if ops == [] do
      []
    else
      case FieldReader.fetch(ctx.schema, ctx.message, ctx.data, field.name, field) do
        {:ok, raw_value} ->
          validate_native_ops(ops, raw_value, Path.field_path(ctx.path, field), nil)

        :error ->
          []
      end
    end
  end

  defp validate_field_cel(ctx, field) do
    ops = get_in(field, [PB.Validate, :cel]) || []

    if ops == [] do
      []
    else
      case FieldReader.read(ctx.schema, ctx.message, ctx.data, field.name, field) do
        {:ok, value} ->
          ops
          |> Enum.with_index()
          |> Enum.flat_map(fn {op, index} ->
            validate_cel_op(
              ctx.schema,
              op,
              value,
              Path.field_path(ctx.path, field),
              ValidateSchema.field_cel_rule_path(index),
              ctx.runtime
            )
          end)

        {:error, reason} ->
          raise_cel_value_error!(ctx.message_name, Path.api_path(ctx.path, field), reason)
      end
    end
  end

  defp validate_message_cel(ctx) do
    ops = get_in(ctx.schema.messages[ctx.message_name], [PB.Validate, :cel]) || []

    if ops == [] do
      []
    else
      case CELMessage.from_decoded(ctx.schema, ctx.message_name, ctx.data) do
        {:ok, value} ->
          violation_path = Path.current_message_field_path(ctx.path)

          ops
          |> Enum.with_index()
          |> Enum.flat_map(fn {op, index} ->
            validate_cel_op(
              ctx.schema,
              op,
              value,
              violation_path,
              ValidateSchema.message_cel_rule_path(index),
              ctx.runtime,
              proto_rule: nil
            )
          end)

        {:error, reason} ->
          raise_cel_value_error!(ctx.message_name, Path.api_path(ctx.path), reason)
      end
    end
  end

  defp validate_repeated_items(ctx, field) do
    case {repeated_item_rules(field), Map.fetch(ctx.data, field.name)} do
      {%RuleSet{} = rules, {:ok, values}} when is_list(values) ->
        item_field = repeated_item_field(field)

        values
        |> Enum.with_index()
        |> Enum.flat_map(fn {value, index} ->
          validate_rule_set(
            ctx.schema,
            rules,
            item_field,
            value,
            ctx.message_name,
            Path.field_path(ctx.path, field, {:index, index}),
            ctx.runtime
          )
        end)

      _other ->
        []
    end
  end

  defp validate_map_entries(ctx, %{cardinality: :map} = field) do
    case Map.fetch(ctx.data, field.name) do
      {:ok, values} when is_map(values) ->
        validate_map_keys(ctx, field, values) ++ validate_map_values(ctx, field, values)

      _other ->
        []
    end
  end

  defp validate_map_entries(_ctx, _field), do: []

  defp validate_map_keys(ctx, field, values) do
    case map_key_rules(field) do
      %RuleSet{} = rules ->
        Enum.flat_map(values, fn {key, _value} ->
          validate_rule_set(
            ctx.schema,
            rules,
            field.map_key,
            key,
            ctx.message_name,
            Path.field_path(ctx.path, field, Path.map_subscript(field.map_key, key)),
            ctx.runtime,
            for_key: true
          )
        end)

      _other ->
        []
    end
  end

  defp validate_map_values(ctx, field, values) do
    case map_value_rules(field) do
      %RuleSet{} = rules ->
        Enum.flat_map(values, fn {key, value} ->
          validate_rule_set(
            ctx.schema,
            rules,
            field.map_value,
            value,
            ctx.message_name,
            Path.field_path(ctx.path, field, Path.map_subscript(field.map_key, key)),
            ctx.runtime
          )
        end)

      _other ->
        []
    end
  end

  defp validate_rule_set(
         schema,
         %RuleSet{} = rules,
         field,
         raw_value,
         message_name,
         field_path,
         context,
         opts \\ []
       ) do
    cond do
      rules.ignore == :IGNORE_ALWAYS ->
        []

      rules.ignore == :IGNORE_IF_ZERO_VALUE and raw_zero_value?(schema, field, raw_value) ->
        []

      true ->
        for_key = Keyword.get(opts, :for_key)

        validate_native_ops(rules.native, raw_value, field_path, for_key) ++
          validate_rule_set_cel(
            schema,
            rules,
            field,
            raw_value,
            message_name,
            field_path,
            context,
            for_key
          )
    end
  end

  defp validate_rule_set_cel(
         _schema,
         %RuleSet{cel: []},
         _field,
         _raw_value,
         _message_name,
         _field_path,
         _context,
         _for_key
       ),
       do: []

  defp validate_rule_set_cel(
         schema,
         %RuleSet{} = rules,
         field,
         raw_value,
         message_name,
         field_path,
         context,
         for_key
       ) do
    case CELMessage.field_value(schema, field, raw_value) do
      {:ok, value} ->
        rules.cel
        |> Enum.with_index()
        |> Enum.flat_map(fn {op, index} ->
          validate_cel_op(
            schema,
            op,
            value,
            field_path,
            ValidateSchema.field_cel_rule_path(index),
            context,
            for_key: for_key
          )
        end)

      {:error, reason} ->
        raise_cel_value_error!(message_name, Path.api_path(field_path), reason)
    end
  end

  defp validate_cel_op(schema, op, value, field_path, fallback_rule_path, context, opts \\ []) do
    rule_path = Map.get(op, :rule_path) || fallback_rule_path
    proto_rule = Keyword.get(opts, :proto_rule, op_proto_rule_path(op, rule_path))
    for_key = Keyword.get(opts, :for_key)
    eval_schema = op_eval_schema(schema, op)
    vars = op_vars(op, value, context)

    case Evaluator.eval(op.checked, vars,
           types: PB.CEL.types(eval_schema),
           regexes: Map.get(op, :regexes, %{})
         ) do
      {:ok, {:bool, true}} ->
        []

      {:ok, {:bool, false}} ->
        [cel_violation(op, field_path, rule_path, proto_rule, blank_to_nil(op.message), for_key)]

      {:ok, {:string, ""}} ->
        []

      {:ok, {:string, message}} ->
        [
          cel_violation(
            op,
            field_path,
            rule_path,
            proto_rule,
            blank_to_nil(op.message) || message,
            for_key
          )
        ]

      {:ok, other} ->
        raise CEL.Error,
          phase: :eval,
          message: "validation rule #{inspect(op.id)} returned non-boolean #{inspect(other)}"

      {:error, error} ->
        raise error
    end
  end

  defp validate_native_ops([], _raw_value, _field_path, _for_key), do: []

  defp validate_native_ops(ops, raw_value, field_path, for_key) do
    Enum.flat_map(ops, fn op ->
      if native_op_valid?(op, raw_value) do
        []
      else
        [native_violation(op, field_path, for_key)]
      end
    end)
  end

  defp native_op_valid?(%{kind: :any_in, values: values}, raw_value) do
    any_type_url(raw_value) in values
  end

  defp native_op_valid?(%{kind: :any_not_in, values: values}, raw_value) do
    any_type_url(raw_value) not in values
  end

  defp native_op_valid?(%{kind: :enum_defined_only, values: values}, raw_value) do
    raw_value in values
  end

  defp native_op_valid?(%{kind: kind}, _raw_value) do
    raise PB.SchemaError,
      kind: :invalid_schema,
      type_name: kind,
      reason: :unknown_native_validation_op
  end

  defp any_type_url(%{type_url: type_url}) when is_binary(type_url), do: type_url
  defp any_type_url(%{"type_url" => type_url}) when is_binary(type_url), do: type_url
  defp any_type_url({:object, type_url, _value}) when is_binary(type_url), do: type_url

  defp any_type_url({:message, :"google.protobuf.Any", fields}) when is_map(fields) do
    any_type_url(fields)
  end

  defp any_type_url(fields) when is_map(fields), do: Map.get(fields, :type_url, "")
  defp any_type_url(_raw_value), do: ""

  defp op_vars(op, value, context) do
    context
    |> Context.vars()
    |> Map.merge(Map.get(op, :vars, %{}))
    |> Map.put("this", value)
  end

  defp op_eval_schema(schema, op) do
    if map_size(Map.get(op, :vars, %{})) == 0 do
      schema
    else
      ValidateSchema.standard_rule_schema(schema)
    end
  end

  defp op_proto_rule_path(op, default) do
    if Map.has_key?(op, :proto_rule_path) do
      Map.get(op, :proto_rule_path)
    else
      default
    end
  end

  defp validate_nested_field(ctx, %{type: type} = field)
       when Field.message_type?(type) do
    cond do
      field.cardinality == :map ->
        validate_nested_map_values(ctx, field)

      field.cardinality == :repeated ->
        validate_nested_repeated_messages(ctx, field)

      true ->
        validate_nested_singular_message(ctx, field)
    end
  end

  defp validate_nested_field(_ctx, _field), do: []

  defp validate_nested_singular_message(ctx, field) do
    case FieldReader.fetch(ctx.schema, ctx.message, ctx.data, field.name, field) do
      {:ok, nil} ->
        []

      {:ok, value} ->
        case fetch_message(ctx.schema, field.type_name) do
          {:ok, nested} ->
            item_path = Path.append_field(ctx.path, field)

            value =
              project_message!(
                ctx.schema,
                field.type_name,
                nested,
                value,
                item_path
              )

            validate_message(
              ctx.schema,
              field.type_name,
              nested,
              value,
              item_path,
              ctx.runtime
            )

          :error ->
            []
        end

      _other ->
        []
    end
  end

  defp validate_nested_repeated_messages(ctx, field) do
    case Map.fetch(ctx.data, field.name) do
      {:ok, values} when is_list(values) ->
        case fetch_message(ctx.schema, field.type_name) do
          {:ok, nested} ->
            item_rules = repeated_item_rules(field)
            item_field = repeated_item_field(field)

            values
            |> Enum.with_index()
            |> Enum.flat_map(fn
              {nil, _index} ->
                []

              {value, index} ->
                if nested_rule_set_ignored?(ctx.schema, item_rules, item_field, value) do
                  []
                else
                  item_path = Path.append_field(ctx.path, field, {:index, index})

                  value =
                    project_message!(
                      ctx.schema,
                      field.type_name,
                      nested,
                      value,
                      item_path
                    )

                  validate_message(
                    ctx.schema,
                    field.type_name,
                    nested,
                    value,
                    item_path,
                    ctx.runtime
                  )
                end
            end)

          :error ->
            []
        end

      _other ->
        []
    end
  end

  defp validate_nested_map_values(
         ctx,
         %{map_value: %{type: type} = value_field} = field
       )
       when Field.message_type?(type) do
    case Map.fetch(ctx.data, field.name) do
      {:ok, values} when is_map(values) ->
        case fetch_message(ctx.schema, value_field.type_name) do
          {:ok, nested} ->
            value_rules = map_value_rules(field)

            Enum.flat_map(values, fn
              {_key, nil} ->
                []

              {key, value} ->
                if nested_rule_set_ignored?(ctx.schema, value_rules, value_field, value) do
                  []
                else
                  item_path =
                    Path.append_field(ctx.path, field, Path.map_subscript(field.map_key, key))

                  value =
                    project_message!(
                      ctx.schema,
                      value_field.type_name,
                      nested,
                      value,
                      item_path
                    )

                  validate_message(
                    ctx.schema,
                    value_field.type_name,
                    nested,
                    value,
                    item_path,
                    ctx.runtime
                  )
                end
            end)

          :error ->
            []
        end

      _other ->
        []
    end
  end

  defp validate_nested_map_values(_ctx, _field), do: []

  defp nested_rule_set_ignored?(_schema, %RuleSet{ignore: :IGNORE_ALWAYS}, _field, _value),
    do: true

  defp nested_rule_set_ignored?(schema, %RuleSet{ignore: :IGNORE_IF_ZERO_VALUE}, field, value),
    do: raw_zero_value?(schema, field, value)

  defp nested_rule_set_ignored?(_schema, _rules, _field, _value), do: false

  defp repeated_item_field(field), do: Map.put(field, :cardinality, :singular)

  defp repeated_item_rules(%{PB.Validate => %{repeated: %{items: items}}}), do: items
  defp repeated_item_rules(_field), do: nil

  defp map_key_rules(%{PB.Validate => %{map: %{keys: keys}}}), do: keys
  defp map_key_rules(_field), do: nil

  defp map_value_rules(%{PB.Validate => %{map: %{values: values}}}), do: values
  defp map_value_rules(_field), do: nil

  defp raw_zero_value?(_schema, %{type: type}, value) when Field.message_type?(type) do
    value in [nil, %{}]
  end

  defp raw_zero_value?(_schema, field, value) do
    with {:ok, value} <- Scalar.normalize_encode_value(field, value, []),
         :ok <- Scalar.validate_encode(field, value, []) do
      Scalar.default_value?(field, value)
    else
      _error -> false
    end
  end

  defp fetch_message(schema, message_name) do
    case Map.fetch(schema.messages, message_name) do
      {:ok, %{kind: :message} = message} -> {:ok, message}
      _other -> :error
    end
  end

  defp validate_oneof(ctx, oneof) do
    if get_in(oneof, [PB.Validate, :required]) == true and not Map.has_key?(ctx.data, oneof.name) do
      path = ctx.path |> Path.append_oneof(oneof) |> Path.field_path()
      [violation("required", path, nil, "exactly one field is required in oneof")]
    else
      []
    end
  end

  defp validate_message_oneofs(ctx) do
    message_oneofs = get_in(ctx.message, [PB.Validate, :message_oneofs]) || []

    Enum.flat_map(message_oneofs, fn oneof ->
      present =
        Enum.filter(oneof.fields, fn name ->
          field = Map.fetch!(ctx.message.fields_by_name, name)
          field_state(ctx, field).message_oneof_set?
        end)

      cond do
        length(present) > 1 ->
          [
            violation(
              "message.oneof",
              Path.current_message_field_path(ctx.path),
              nil,
              "only one of #{message_oneof_fields(oneof.fields)} can be set"
            )
          ]

        oneof.required and present == [] ->
          [
            violation(
              "message.oneof",
              Path.current_message_field_path(ctx.path),
              nil,
              "one of #{message_oneof_fields(oneof.fields)} must be set"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp unset_message_oneof_field?(ctx, field) do
    ctx.message
    |> get_in([PB.Validate, :message_oneofs])
    |> List.wrap()
    |> Enum.any?(fn oneof ->
      field.name in oneof.fields and
        not field_state(ctx, field).message_oneof_set?
    end)
  end

  defp required_missing?(ctx, field) do
    if get_in(field, [PB.Validate, :required]) == true do
      state = field_state(ctx, field)

      if Features.has_presence?(field) do
        not state.present?
      else
        state.zero?
      end
    else
      false
    end
  end

  defp skip_unset_explicit_field?(ctx, field) do
    Features.has_presence?(field) and not field_state(ctx, field).present?
  end

  defp ignore_zero_field?(ctx, field) do
    get_in(field, [PB.Validate, :ignore]) == :IGNORE_IF_ZERO_VALUE and
      get_in(field, [PB.Validate, :required]) != true and
      not Features.has_presence?(field) and
      field_state(ctx, field).zero?
  end

  defp zero_value?(_schema, _message, _data, %{cardinality: :repeated}, false), do: true
  defp zero_value?(_schema, _message, _data, %{cardinality: :map}, false), do: true

  defp zero_value?(_schema, _message, data, %{cardinality: :repeated} = field, _present?) do
    case Map.fetch(data, field.name) do
      {:ok, values} when is_list(values) -> values == []
      :error -> true
      _other -> false
    end
  end

  defp zero_value?(_schema, _message, data, %{cardinality: :map} = field, _present?) do
    case Map.fetch(data, field.name) do
      {:ok, values} when is_map(values) -> map_size(values) == 0
      :error -> true
      _other -> false
    end
  end

  defp zero_value?(_schema, _message, data, %{type: type} = field, present?)
       when Field.message_type?(type) do
    if present? do
      Map.get(data, field.name) in [nil, %{}]
    else
      true
    end
  end

  defp zero_value?(_schema, _message, data, field, present?) do
    value =
      if present? do
        Map.get(data, field.name)
      else
        nil
      end

    with {:ok, value} <- Scalar.normalize_encode_value(field, value, []),
         :ok <- Scalar.validate_encode(field, value, []) do
      Scalar.default_value?(field, value)
    else
      _error -> false
    end
  end

  defp sorted_fields(message) do
    message.fields_by_name
    |> Map.values()
    |> Enum.sort_by(& &1.number)
  end

  defp sorted_oneofs(message) do
    message.oneofs
    |> Enum.sort_by(fn {index, _oneof} -> index end)
    |> Enum.map(fn {_index, oneof} -> oneof end)
  end

  defp violation(rule_id, field_path, rule_path, message) do
    %Violation{
      rule_id: rule_id,
      field: field_path,
      rule: rule_path,
      proto_rule: rule_path,
      message: message
    }
  end

  defp cel_violation(op, field_path, rule_path, proto_rule, message, for_key) do
    %Violation{
      rule_id: op.id,
      field: field_path,
      rule: rule_path,
      proto_rule: proto_rule,
      message: message,
      source: op.source,
      for_key: for_key
    }
  end

  defp native_violation(op, field_path, for_key) do
    %Violation{
      rule_id: op.id,
      field: field_path,
      rule: op.rule_path,
      proto_rule: op.proto_rule_path,
      message: op.message,
      for_key: for_key
    }
  end

  defp raise_cel_value_error!(message_name, path, reason) do
    raise cel_value_error(reason, message_name, path)
  end

  defp cel_value_error({:invalid_message_value, type_name, value}, message_name, path) do
    %PB.ValueError{
      operation: :validate,
      message_name: message_name,
      kind: :invalid_value,
      path: path,
      expected: {:message, type_name},
      got: value
    }
  end

  defp cel_value_error({:message_type_mismatch, type_name, actual}, message_name, path) do
    %PB.ValueError{
      operation: :validate,
      message_name: message_name,
      kind: :invalid_value,
      path: path,
      expected: {:message, type_name},
      got: {:message, actual}
    }
  end

  defp cel_value_error({:invalid_literal_field_value, type, value}, message_name, path) do
    %PB.ValueError{
      operation: :validate,
      message_name: message_name,
      kind: :invalid_value,
      path: path,
      expected: type,
      got: value
    }
  end

  defp cel_value_error({:unsupported_field_value, type, value}, message_name, path) do
    %PB.ValueError{
      operation: :validate,
      message_name: message_name,
      kind: :invalid_value,
      path: path,
      expected: type,
      got: value
    }
  end

  defp cel_value_error(reason, message_name, path) do
    RuntimeErrors.to_error(reason, :validate, message_name)
  rescue
    ArgumentError ->
      %PB.ValueError{
        operation: :validate,
        message_name: message_name,
        kind: :invalid_value,
        path: path,
        reason: reason
      }
  end

  defp message_oneof_fields(fields) do
    Enum.map_join(fields, ", ", &Atom.to_string/1)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end

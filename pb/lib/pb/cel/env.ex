defmodule PB.CEL.Env do
  @moduledoc """
  What a CEL expression may use: its variables and their types, custom
  functions, and the protobuf schema its messages and enums come from. The
  standard CEL functions and macros are always available.

  Build one with `build/1` and pass it to `PB.CEL.check/2`, `PB.CEL.compile/2`
  or `PB.CEL.eval/3`. A `PB.CEL.Program` keeps the environment it was compiled
  with, so evaluation does not take one.
  """

  alias PB.CEL.Checker.Literals
  alias PB.CEL.Checker.TypePattern
  alias PB.CEL.Library
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.Options
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Runtime.NoMessageRuntime
  alias PB.CEL.Runtime.NoMessageSchema

  # Neither provider has a protobuf binding by default: `message_schema` (checker
  # reflection) and `message_runtime` (evaluator field access) are supplied by a
  # host that works against protobuf messages — the protobuf binding's
  # `PB.CEL.MessageSchema` and `PB.CEL.MessageRuntime`. The CEL-side defaults
  # know no types; supplying a schema without a `:message_schema` provider
  # raises. See `NoMessageSchema` / `NoMessageRuntime`.
  defstruct vars: %{},
            functions: [],
            container: "",
            abbreviations: %{},
            schema: nil,
            message_schema: NoMessageSchema,
            message_runtime: NoMessageRuntime,
            validate_literals: []

  @typedoc "An environment; build one with `build/1`."
  @type t :: %__MODULE__{}

  @qualified_name ~r/\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+\z/

  @build_options [
    schema: {:any, nil},
    container: {:any, nil},
    abbreviations: {:list, []},
    vars: {:any, []},
    functions: {:list, []},
    validate_literals: {:list, []},
    message_schema: {:any, nil},
    message_runtime: {:any, nil}
  ]

  @doc """
  Builds an environment.

      env =
        PB.CEL.Env.build(
          schema: MyApp.Schema,
          container: "my.pkg",
          vars: [user: {:message, "my.pkg.User"}, tags: {:list, :string}],
          functions: [my_function]
        )

  ## Options

    * `:vars` — the variables expressions may read, as a keyword list or map
      from name to `t:PB.CEL.Type.t/0`.
    * `:functions` — custom functions, as `PB.CEL.Function` structs. See the
      "Custom CEL functions" guide.
    * `:schema` — a schema from `PB.compile/2`, or a module that
      `use PB.Schema`, whose messages and enums expressions may use.
    * `:container` — the protobuf package names are resolved in, as with
      `container` in other CEL implementations: with `"my.pkg"`, `User`
      resolves to `my.pkg.User`.
    * `:abbreviations` — fully qualified names expressions may refer to by
      their last segment, as with `Abbrevs` in cel-go: with
      `["my.pkg.Decision"]`, `Decision.REMOVED` means
      `my.pkg.Decision.REMOVED` whatever the container. An abbreviation is
      used instead of the container, even when the container would resolve
      the name to something else, and hides a variable of the same name;
      variables a macro binds still hide it. Abbreviations apply to
      variables, types and enum values, not to function names.
    * `:validate_literals` — a subset of `[:duration, :timestamp, :regex]`.
      Checking then rejects literal arguments evaluation would reject, such as
      `duration('30d')`, `timestamp('nope')` or `s.matches('[')`. By default
      these fail when evaluated, as CEL specifies.

  Raises `PB.OptionError` for an unknown option or an invalid value.
  """
  @spec build(keyword) :: t
  def build(opts \\ []) do
    case Options.validate(opts, @build_options) do
      {:ok, _valid} -> from_options(opts)
      {:error, reason} -> raise RuntimeErrors.to_error(reason)
    end
  end

  # The checker rebuilds an environment from `env:` plus overrides, so unset
  # options leave the base environment alone.
  @doc false
  @spec from_options(keyword) :: t
  def from_options(opts) when is_list(opts) do
    schema = Keyword.get(opts, :schema)

    # The one remaining reference from CEL to the protobuf binding: `schema:`
    # defaults the providers to `PB.CEL.MessageSchema`/`MessageRuntime`, which
    # `PB.CEL.Env.build(schema: ...)` callers rely on. Resolved in step 2 of the
    # cel_ex/pb_cel split, when the binding gets its own entry point.
    default_provider = fn pb_provider -> if schema, do: pb_provider end

    opts
    |> Keyword.get(:env, %__MODULE__{})
    |> put_message_schema(
      Keyword.get_lazy(opts, :message_schema, fn ->
        default_provider.(PB.CEL.MessageSchema)
      end)
    )
    |> put_message_runtime(
      Keyword.get_lazy(opts, :message_runtime, fn ->
        default_provider.(PB.CEL.MessageRuntime)
      end)
    )
    |> put_schema(schema)
    |> put_container(Keyword.get(opts, :container))
    |> put_abbreviations(Keyword.get(opts, :abbreviations, []))
    |> merge_vars(Keyword.get(opts, :vars, []))
    |> merge_functions(Keyword.get(opts, :functions, []))
    |> put_validate_literals(Keyword.get(opts, :validate_literals))
    |> register_library_functions()
  end

  @doc false
  @spec empty() :: t
  def empty, do: %__MODULE__{}

  defp put_validate_literals(env, nil), do: env

  defp put_validate_literals(env, kinds) do
    unless is_list(kinds) and kinds -- Literals.kinds() == [] do
      reason = "expected a subset of #{inspect(Literals.kinds())}"
      invalid_option!(:validate_literals, kinds, reason)
    end

    %{env | validate_literals: kinds}
  end

  defp put_message_schema(env, nil), do: env

  defp put_message_schema(env, provider),
    do: %{env | message_schema: provider!(:message_schema, provider, :normalize, 1)}

  defp put_message_runtime(env, nil), do: env

  defp put_message_runtime(env, provider),
    do: %{env | message_runtime: provider!(:message_runtime, provider, :from_decoded, 3)}

  defp provider!(option, provider, function, arity) do
    unless is_atom(provider) and Code.ensure_loaded?(provider) and
             function_exported?(provider, function, arity) do
      invalid_option!(option, provider, "expected a provider module")
    end

    provider
  end

  defp put_schema(env, nil), do: env
  defp put_schema(env, schema), do: %{env | schema: env.message_schema.normalize(schema)}

  defp put_container(env, nil), do: env

  defp put_container(env, container) when is_binary(container),
    do: %{env | container: normalize_container(container)}

  defp put_container(_env, container),
    do: invalid_option!(:container, container, "expected a string")

  defp put_abbreviations(env, names) do
    Enum.reduce(names, env, fn name, env ->
      unless is_binary(name) and name =~ @qualified_name do
        invalid_option!(:abbreviations, name, "expected a qualified name such as \"pkg.Name\"")
      end

      short = name |> String.split(".") |> List.last()

      if existing = env.abbreviations[short] do
        invalid_option!(:abbreviations, name, "#{short} already abbreviates #{existing}")
      end

      if env.container == short or String.starts_with?(env.container, short <> ".") do
        invalid_option!(:abbreviations, name, "#{short} collides with container #{env.container}")
      end

      %{env | abbreviations: Map.put(env.abbreviations, short, name)}
    end)
  end

  defp merge_vars(env, vars) when is_list(vars) or is_map(vars) do
    Enum.reduce(vars, env, fn
      {name, type}, env when is_atom(name) or is_binary(name) ->
        %{env | vars: Map.put(env.vars, normalize_name(name), var_type!(name, type))}

      entry, _env ->
        invalid_option!(:vars, entry, "expected {name, type}")
    end)
  end

  defp merge_vars(_env, vars), do: invalid_option!(:vars, vars, "expected a keyword list or map")

  defp var_type!(name, type) do
    CType.from_input(type)
  rescue
    FunctionClauseError ->
      invalid_option!(:vars, type, "#{inspect(name)} has no PB.CEL.Type: #{inspect(type)}")
  end

  defp merge_functions(env, functions) do
    Enum.reduce(functions, env, fn
      %Function{} = function, env ->
        %{env | functions: [normalize_function(function) | env.functions]}

      other, _env ->
        invalid_option!(:functions, other, "expected a %PB.CEL.Function{}")
    end)
  end

  @spec invalid_option!(atom, term, String.t()) :: no_return
  defp invalid_option!(option, value, reason) do
    raise PB.OptionError, kind: :invalid_option, option: option, value: value, reason: reason
  end

  @doc false
  @spec namespaces(t) :: MapSet.t(String.t())
  def namespaces(%__MODULE__{} = env) do
    for function <- env.functions,
        {:namespace, namespace} <- function.modes,
        into: MapSet.new(),
        do: namespace
  end

  @doc false
  @spec fetch_var(t, String.t()) :: {:ok, CType.t()} | :error
  def fetch_var(%__MODULE__{} = env, name) when is_binary(name) do
    Map.fetch(env.vars, name)
  end

  defp register_library_functions(%__MODULE__{} = env) do
    library_functions = Library.functions()

    if library_functions_registered?(env.functions, library_functions) do
      env
    else
      %{env | functions: env.functions ++ Enum.reverse(library_functions)}
    end
  end

  defp library_functions_registered?(functions, library_functions) do
    registered = MapSet.new(functions)

    Enum.all?(library_functions, &MapSet.member?(registered, &1))
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp normalize_container("." <> container), do: normalize_container(container)
  defp normalize_container(container), do: String.trim(container)

  defp normalize_function(%Function{} = function) do
    %{
      function
      | overloads: Enum.map(function.overloads, &check_overload(&1, function)),
        dynamic_overloads: Enum.map(function.dynamic_overloads, &check_overload(&1, function))
    }
  end

  defp check_overload(%Overload{} = overload, function) do
    unless is_binary(overload.id) do
      reason = "#{inspect(function.name)} overload :id must be a string"
      invalid_option!(:functions, overload.id, reason)
    end

    unless is_list(overload.args) and Enum.all?(overload.args, &TypePattern.valid?(&1, :arg)) do
      invalid_signature!(function, overload, :args, overload.args)
    end

    unless TypePattern.valid?(overload.result, :result) do
      invalid_signature!(function, overload, :result, overload.result)
    end

    normalize_overload(overload, function)
  end

  @spec invalid_signature!(Function.t(), Overload.t(), atom, term) :: no_return
  defp invalid_signature!(function, overload, field, value) do
    reason =
      "#{inspect(function.name)} overload #{inspect(overload.id)} #{inspect(field)} " <>
        "must be PB.CEL.Type shorthand"

    invalid_option!(:functions, value, reason)
  end

  defp normalize_overload(%Overload{eval: nil} = overload, _function), do: overload
  defp normalize_overload(%Overload{eval: :intrinsic} = overload, _function), do: overload

  defp normalize_overload(%Overload{eval: {:mfa, {mod, fun}}} = overload, _function)
       when is_atom(mod) and is_atom(fun) do
    overload
  end

  defp normalize_overload(%Overload{eval: {mod, fun}} = overload, _function)
       when is_atom(mod) and is_atom(fun) do
    %{overload | eval: {:mfa, {mod, fun}}}
  end

  defp normalize_overload(%Overload{eval: eval}, function) do
    invalid_option!(
      :functions,
      eval,
      "#{inspect(function.name)} overload :eval must be {Module, function}, got: #{inspect(eval)}"
    )
  end
end

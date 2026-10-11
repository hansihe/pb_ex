defmodule PB.CEL.Env do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Static CEL checker environment.
  #
  # The environment carries identifier declarations plus the function declarations
  # active for checking. Built-in functions are registered from the standard CEL
  # library; custom functions are appended to the same checker signature path.
  @moduledoc false

  alias PB.CEL.Library
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Runtime.NoMessageRuntime
  alias PB.CEL.Runtime.NoMessageSchema

  # Neither provider has a protobuf binding by default: `message_schema` (checker
  # reflection) and `message_runtime` (evaluator field access) are supplied by a
  # host that works against protobuf messages — `PB.Validate.CEL.MessageSchema`
  # and `PB.Validate.CEL.MessageRuntime`. The CEL-side defaults know no types;
  # supplying a schema without a `:message_schema` provider raises. See
  # `NoMessageSchema` / `NoMessageRuntime`.
  defstruct vars: %{},
            functions: [],
            container: "",
            schema: nil,
            message_schema: NoMessageSchema,
            message_runtime: NoMessageRuntime,
            validate_literals: []

  @type t :: %__MODULE__{
          vars: %{String.t() => CType.t()},
          functions: [Function.t()],
          container: String.t(),
          schema: term(),
          message_schema: module(),
          message_runtime: module(),
          validate_literals: [PB.CEL.Checker.Literals.kind()]
        }

  @spec new(keyword | map | t) :: t
  def new(%__MODULE__{} = env) do
    %{env | vars: Map.new(env.vars, fn {name, type} -> {name, CType.from_input(type)} end)}
  end

  def new(vars) when is_list(vars) or is_map(vars) do
    Enum.reduce(vars, %__MODULE__{}, fn {name, type}, env ->
      put_var(env, name, type)
    end)
  end

  @doc """
  Returns an empty environment with no variables, no functions, no schema, and
  no container. Used as the default for `PB.CEL.eval/3` when no env is
  needed.
  """
  @spec empty() :: t
  def empty, do: %__MODULE__{}

  @doc """
  Builds an environment from typical options.

  Equivalent to `from_options/1` but reads more naturally at call sites.

      env = PB.CEL.Env.build(
        schema: schema,
        vars: [name: :string, ids: {:list, :int}],
        functions: [my_function],
        container: "my.pkg"
      )

  `validate_literals: [:duration, :timestamp, :regex]` (any subset) makes
  checking reject literal arguments the evaluator would reject:
  `duration('30d')`, `timestamp('nope')` or `s.matches('[')`. By default these
  fail when evaluated, as CEL specifies.
  """
  @spec build(keyword) :: t
  def build(opts) when is_list(opts), do: from_options(opts)

  @spec from_options(keyword) :: t
  def from_options(opts) when is_list(opts) do
    opts
    |> Keyword.get(:env, %__MODULE__{})
    |> new()
    |> put_message_schema(Keyword.get(opts, :message_schema, nil))
    |> put_message_runtime(Keyword.get(opts, :message_runtime, nil))
    |> put_schema(Keyword.get(opts, :schema, nil))
    |> put_container(Keyword.get(opts, :container, nil))
    |> merge_vars(Keyword.get(opts, :vars, %{}))
    |> merge_functions(Keyword.get(opts, :functions, []))
    |> put_validate_literals(Keyword.get(opts, :validate_literals))
    |> register_library_functions()
  end

  defp put_validate_literals(env, nil), do: env

  defp put_validate_literals(env, kinds) do
    unless is_list(kinds) and kinds -- PB.CEL.Checker.Literals.kinds() == [] do
      raise ArgumentError,
            "expected :validate_literals to be a list of " <>
              "#{inspect(PB.CEL.Checker.Literals.kinds())}, got: #{inspect(kinds)}"
    end

    %{env | validate_literals: kinds}
  end

  @spec put_message_schema(t, module() | nil) :: t
  def put_message_schema(%__MODULE__{} = env, nil), do: env

  def put_message_schema(%__MODULE__{} = env, message_schema) when is_atom(message_schema) do
    Code.ensure_loaded(message_schema)

    unless function_exported?(message_schema, :normalize, 1) do
      raise ArgumentError,
            "expected :message_schema to implement PB.CEL.Message.Schema, got: #{inspect(message_schema)}"
    end

    %{env | message_schema: message_schema}
  end

  def put_message_schema(%__MODULE__{}, message_schema) do
    raise ArgumentError,
          "expected :message_schema to be a module, got: #{inspect(message_schema)}"
  end

  @spec put_message_runtime(t, module() | nil) :: t
  def put_message_runtime(%__MODULE__{} = env, nil), do: env

  def put_message_runtime(%__MODULE__{} = env, message_runtime) when is_atom(message_runtime) do
    Code.ensure_loaded(message_runtime)

    unless function_exported?(message_runtime, :from_decoded, 3) do
      raise ArgumentError,
            "expected :message_runtime to implement PB.CEL.Message.Runtime, got: #{inspect(message_runtime)}"
    end

    %{env | message_runtime: message_runtime}
  end

  def put_message_runtime(%__MODULE__{}, message_runtime) do
    raise ArgumentError,
          "expected :message_runtime to be a module, got: #{inspect(message_runtime)}"
  end

  @spec put_schema(t, term()) :: t
  def put_schema(%__MODULE__{} = env, nil), do: env

  def put_schema(%__MODULE__{} = env, schema) do
    %{env | schema: env.message_schema.normalize(schema)}
  end

  @spec put_container(t, String.t() | nil) :: t
  def put_container(%__MODULE__{} = env, nil), do: env

  def put_container(%__MODULE__{} = env, container) when is_binary(container) do
    %{env | container: normalize_container(container)}
  end

  @spec put_var(t, atom | String.t(), CType.t() | PB.CEL.Type.input()) :: t
  def put_var(%__MODULE__{} = env, name, type) when is_atom(name) or is_binary(name) do
    %{env | vars: Map.put(env.vars, normalize_name(name), CType.from_input(type))}
  end

  @spec merge_vars(t, keyword | map) :: t
  def merge_vars(%__MODULE__{} = env, vars) when is_list(vars) or is_map(vars) do
    Enum.reduce(vars, env, fn {name, type}, env -> put_var(env, name, type) end)
  end

  @spec put_function(t, Function.t()) :: t
  def put_function(%__MODULE__{} = env, %Function{} = function) do
    %{env | functions: [normalize_function(function) | env.functions]}
  end

  @spec merge_functions(t, [Function.t()]) :: t
  def merge_functions(%__MODULE__{} = env, functions) when is_list(functions) do
    Enum.reduce(functions, env, fn function, env -> put_function(env, function) end)
  end

  @spec namespaces(t) :: MapSet.t(String.t())
  def namespaces(%__MODULE__{} = env) do
    for function <- env.functions,
        {:namespace, namespace} <- function.modes,
        into: MapSet.new(),
        do: namespace
  end

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

  defp normalize_function(%Function{overloads: overloads, dynamic_overloads: dynamic} = function) do
    %{
      function
      | overloads: Enum.map(overloads, &normalize_overload(&1, function)),
        dynamic_overloads: Enum.map(dynamic, &normalize_overload(&1, function))
    }
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

  defp normalize_overload(%Overload{eval: eval}, function) when is_function(eval) do
    raise ArgumentError,
          "CEL custom function #{inspect(function.name)} overload eval must be an " <>
            "{Module, function_atom} MFA tuple; closures and anonymous functions are not " <>
            "supported. Got: #{inspect(eval)}"
  end

  defp normalize_overload(%Overload{eval: eval}, function) do
    raise ArgumentError,
          "CEL custom function #{inspect(function.name)} overload eval must be an " <>
            "{Module, function_atom} MFA tuple. Got: #{inspect(eval)}"
  end
end

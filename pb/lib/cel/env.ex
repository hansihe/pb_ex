defmodule CEL.Env do
  @moduledoc """
  What a CEL expression may use: its variables and their types, custom
  functions, and the message and enum types of its `CEL.TypeProvider`. The
  standard CEL functions and macros, and CEL's own types, are always
  available.

  Build one with `build/1` and pass it to `CEL.check/2`, `CEL.compile/2`
  or `CEL.eval/3`. A `CEL.Program` keeps the environment it was compiled
  with, so evaluation does not take one.
  """

  alias CEL.Checker.Literals
  alias CEL.Checker.TypePattern
  alias CEL.Library
  alias CEL.Options
  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Checker.Types, as: CType
  alias CEL.TypeProvider
  alias CEL.WellKnownTypes

  @no_types {TypeProvider.Empty, nil}

  defstruct vars: %{},
            functions: [],
            container: "",
            abbreviations: %{},
            types: @no_types,
            validate_literals: []

  @typedoc "An environment; build one with `build/1`."
  @type t :: %__MODULE__{}

  @qualified_name ~r/\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+\z/

  @build_options [
    types: {:any, nil},
    container: {:any, nil},
    abbreviations: {:list, []},
    vars: {:any, []},
    functions: {:list, []},
    validate_literals: {:list, []}
  ]

  @doc """
  Builds an environment.

      env =
        CEL.Env.build(
          types: PB.CEL.types(MyApp.Schema),
          container: "my.pkg",
          vars: [user: {:message, "my.pkg.User"}, tags: {:list, :string}],
          functions: [my_function]
        )

  ## Options

    * `:vars` — the variables expressions may read, as a keyword list or map
      from name to `t:CEL.Type.t/0`.
    * `:functions` — custom functions, as `CEL.Function` structs. See the
      "Custom CEL functions" guide.
    * `:types` — the message and enum types expressions may use, as a
      `t:CEL.TypeProvider.t/0`, such as `PB.CEL.types/1` returns for a
      protobuf schema. Without it there are none. Message and enum names in
      `:vars` and `:functions` may be atoms or strings; each is resolved
      through the provider, and an unknown one raises.
    * `:container` — the package names are resolved in, as with `container`
      in other CEL implementations: with `"my.pkg"`, `User` resolves to
      `my.pkg.User`.
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

  Raises `CEL.OptionError` for an unknown option or an invalid value.
  """
  @spec build(keyword) :: t
  def build(opts \\ []) do
    Options.validate!(opts, @build_options)
    from_options(opts)
  end

  # The checker rebuilds an environment from `env:` plus overrides, so unset
  # options leave the base environment alone.
  @doc false
  @spec from_options(keyword) :: t
  def from_options(opts) when is_list(opts) do
    opts
    |> Keyword.get(:env, %__MODULE__{})
    |> put_types(Keyword.get(opts, :types))
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

  defp put_types(env, nil), do: env

  defp put_types(env, {module, _state} = types) when is_atom(module) do
    exported? =
      Code.ensure_loaded?(module) and
        Enum.all?(TypeProvider.required_callbacks(), fn {function, arity} ->
          function_exported?(module, function, arity)
        end)

    unless exported? do
      invalid_option!(:types, types, "#{inspect(module)} does not implement CEL.TypeProvider")
    end

    %{env | types: types}
  end

  defp put_types(_env, types),
    do: invalid_option!(:types, types, "expected a {module, state} CEL.TypeProvider")

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
        %{env | vars: Map.put(env.vars, normalize_name(name), var_type!(env, name, type))}

      entry, _env ->
        invalid_option!(:vars, entry, "expected {name, type}")
    end)
  end

  defp merge_vars(_env, vars), do: invalid_option!(:vars, vars, "expected a keyword list or map")

  defp var_type!(env, name, type) do
    type =
      try do
        CType.from_input(type)
      rescue
        FunctionClauseError ->
          invalid_option!(:vars, type, "#{inspect(name)} has no CEL.Type: #{inspect(type)}")
      end

    resolve_names!(env, :vars, type)
  end

  # Message and enum names a declaration spells as atoms or strings become the
  # provider's, and the well-known types CEL's own. With no provider, names are
  # left as written.
  defp resolve_names!(env, option, {tag, name}) when tag in [:message, :enum] do
    cond do
      builtin = WellKnownTypes.builtin_type(to_string(name)) -> CType.from_input(builtin)
      env.types == @no_types -> {tag, name}
      true -> {tag, resolve_name!(env, option, name)}
    end
  end

  defp resolve_names!(env, option, types) when is_list(types),
    do: Enum.map(types, &resolve_names!(env, option, &1))

  defp resolve_names!(env, option, type) when is_tuple(type) do
    type
    |> Tuple.to_list()
    |> Enum.map(&resolve_names!(env, option, &1))
    |> List.to_tuple()
  end

  defp resolve_names!(_env, _option, type), do: type

  defp resolve_name!(env, option, name) do
    case find_type(env, to_string(name)) do
      {:ok, _kind, resolved} -> resolved
      :error -> invalid_option!(option, name, "unknown message or enum type #{name}")
    end
  end

  defp merge_functions(env, functions) do
    Enum.reduce(functions, env, fn
      %Function{} = function, env ->
        %{env | functions: [normalize_function(env, function) | env.functions]}

      other, _env ->
        invalid_option!(:functions, other, "expected a %CEL.Function{}")
    end)
  end

  @doc false
  @spec find_type(t, String.t()) :: {:ok, :message | :enum, TypeProvider.name()} | :error
  def find_type(%__MODULE__{types: {module, state}}, name), do: module.find_type(state, name)

  @doc false
  @spec find_field(t, TypeProvider.name(), String.t()) :: {:ok, CEL.Field.t()} | :error
  def find_field(%__MODULE__{types: {module, state}}, message, field),
    do: module.find_field(state, message, field)

  @doc false
  @spec enum_value(t, TypeProvider.name(), String.t()) :: {:ok, integer} | :error
  def enum_value(%__MODULE__{types: {module, state}}, enum, value),
    do: module.enum_value(state, enum, value)

  @doc false
  @spec required_fields(t, TypeProvider.name()) :: [String.t()]
  def required_fields(%__MODULE__{types: {module, state}}, message) do
    if function_exported?(module, :required_fields, 2),
      do: module.required_fields(state, message),
      else: []
  end

  # The checker spells an enum type as a message of the enum's name.
  @doc false
  @spec enum?(t, TypeProvider.name()) :: boolean
  def enum?(%__MODULE__{} = env, name) do
    not WellKnownTypes.literal_message?(name) and
      match?({:ok, :enum, ^name}, find_type(env, to_string(name)))
  end

  @spec invalid_option!(atom, term, String.t()) :: no_return
  defp invalid_option!(option, value, reason) do
    raise CEL.OptionError, kind: :invalid_option, option: option, value: value, reason: reason
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

  defp normalize_function(env, %Function{} = function) do
    %{
      function
      | overloads: Enum.map(function.overloads, &check_overload(env, &1, function)),
        dynamic_overloads:
          Enum.map(function.dynamic_overloads, &check_overload(env, &1, function))
    }
  end

  defp check_overload(env, %Overload{} = overload, function) do
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

    overload = %{
      overload
      | args: resolve_names!(env, :functions, overload.args),
        result: resolve_names!(env, :functions, overload.result)
    }

    normalize_overload(overload, function)
  end

  @spec invalid_signature!(Function.t(), Overload.t(), atom, term) :: no_return
  defp invalid_signature!(function, overload, field, value) do
    reason =
      "#{inspect(function.name)} overload #{inspect(overload.id)} #{inspect(field)} " <>
        "must be CEL.Type shorthand"

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

defmodule CEL do
  @moduledoc """
  The Common Expression Language (CEL): parse, type-check and evaluate CEL
  expressions against variables and messages.

      env = CEL.Env.build(vars: [age: :int, tags: {:list, :string}])

      CEL.eval("age >= 18 && 'vip' in tags", %{age: 30, tags: ["vip"]}, env)
      #=> {:ok, {:bool, true}}

  An expression goes through three steps, each also available on its own:

    * `parse/2` turns source text into a `cel.expr.ParsedExpr` map.
    * `check/2` type-checks it against a `CEL.Env` (the variables, functions
      and message types it may use) into a `CEL.Checked`, which can be
      inspected with `CEL.Checked.expr/1` and
      `CEL.Checked.references/1`.
    * `compile/2` bundles a checked expression with its environment into a
      `CEL.Program`, which `CEL.Program.eval/2` evaluates as many times
      as needed.

  `eval/3` does all three for a one-off evaluation.

  ## Messages

  CEL's own types are always there, including the protobuf well-known types
  it builds in: `google.protobuf.Timestamp` and `Duration`, the wrappers,
  `Any`, `Value`, `ListValue` and `Struct`. Message and enum types come from a
  `CEL.TypeProvider`, given to `CEL.Env.build/1` as `:types`. For protobuf
  messages, `PB.CEL.types/1` is one:

      env =
        CEL.Env.build(
          types: PB.CEL.types(MyApp.Schema),
          container: "my.pkg",
          vars: [user: {:message, "my.pkg.User"}]
        )

      CEL.eval("user.age >= 18", %{user: %{age: 30}}, env)
      #=> {:ok, {:bool, true}}

  ## Values

  Variables are bound by name (atom or string keys) to plain Elixir terms, which
  are converted using the variable's declared type: integers, floats, strings,
  booleans, lists and maps, and `DateTime` for `:timestamp`. A variable of a
  message or enum type takes what its provider converts, for `PB.CEL.types/1`
  a message as `PB.decode/4` returns it and an enum value's name as an atom or
  its number. `nil` binds a wrapper variable to `null`.

  Results are `t:CEL.Value.t/0` terms, tagged so that CEL's distinctions
  survive: `{:int, 1}` and `{:uint, 1}`, `{:string, "a"}` and `{:bytes, "a"}`,
  `{:enum, :"pkg.Enum", 2}`, with message and enum types named as their
  provider names them. `CEL.Value.to_native/1` turns one back into a plain
  term.

  ## Results

  Evaluation returns `{:ok, value}`, `{:error, %CEL.Error{}}`, or
  `{:unknown, %CEL.Unknown{}}` when the result depends on a variable bound
  to `{:unknown, reason}` or on a custom function that returned one; see
  `CEL.Unknown`. Parse and check errors are `CEL.Error`s too, with the
  line and column of the problem in the source.

  ## Custom functions

  Register `CEL.Function` structs with `CEL.Env.build/1`'s `:functions`
  option. See the "Custom CEL functions" guide.
  """

  alias CEL.Checked
  alias CEL.Checker
  alias CEL.Env
  alias CEL.Error
  alias CEL.Options
  alias CEL.Program
  alias CEL.Syntax.MacroExpander
  alias CEL.Syntax.Parser
  alias CEL.Syntax.Source
  alias CEL.Unknown
  alias CEL.Value

  @typedoc """
  A parsed expression: a `cel.expr.ParsedExpr` map with `:expr` and
  `:source_info`, as `parse/2` returns.
  """
  @type parsed :: %{expr: map, source_info: map}

  @parse_options [location: {:any, "<input>"}, macros: {:boolean, true}]

  @doc """
  Parses CEL source into a `cel.expr.ParsedExpr` map.

  ## Options

    * `:location` - where the source came from, such as a file name. Parse
      and check errors report it in `CEL.Error`'s `:location`. Defaults to
      `"<input>"`.
    * `:macros` - whether to expand the standard macros (`has`, `all`,
      `exists`, `exists_one`, `map`, `filter`, `cel.bind`, `optMap`,
      `optFlatMap`). Defaults to `true`.

  Raises `CEL.OptionError` for an unknown option or an invalid value.
  """
  @spec parse(String.t(), keyword) :: {:ok, parsed()} | {:error, Error.t()}
  def parse(source, opts \\ []) when is_binary(source) do
    opts = Options.validate!(opts, @parse_options)

    source
    |> Parser.parse(location: opts.location)
    |> expand_macros(opts.macros)
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      {:error, %Error{} = error} ->
        error = %{error | location: opts.location}
        {:error, Source.locate(error, Source.line_offsets(source))}
    end
  end

  defp expand_macros({:ok, parsed}, true), do: MacroExpander.expand(parsed)
  defp expand_macros(result, _macros), do: result

  @doc """
  Parses CEL source into a `cel.expr.ParsedExpr` map, raising on errors.
  """
  @spec parse!(String.t(), keyword) :: parsed()
  def parse!(source, opts \\ []) when is_binary(source) do
    case parse(source, opts) do
      {:ok, parsed} -> parsed
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Checks CEL source or a parsed expression into a `CEL.Checked` value.

  The second argument must be a `CEL.Env`.

  Passing a pre-parsed expression skips parser resource limits and assumes the
  AST came from `parse/2` or another trusted producer.

  """
  @spec check(String.t() | parsed(), Env.t()) ::
          {:ok, Checked.t()} | {:error, Error.t()}
  def check(source_or_parsed, env \\ Env.empty())

  def check(source, %Env{} = env) when is_binary(source) do
    with {:ok, parsed} <- parse(source) do
      Checker.check(parsed, env: env)
    end
  end

  def check(%{expr: _expr, source_info: _source_info} = parsed, %Env{} = env) do
    Checker.check(parsed, env: env)
  end

  @doc """
  Checks CEL source or a parsed expression, raising on parse or check errors.
  """
  @spec check!(String.t() | parsed(), Env.t()) :: Checked.t()
  def check!(source_or_parsed, env \\ Env.empty()) do
    case check(source_or_parsed, env) do
      {:ok, checked} -> checked
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Checks CEL source or a parsed expression and bundles the result with the
  supplied environment as a `CEL.Program`.

  Programs carry their environment so eval callers do not have to re-pass
  types or function declarations on every call. See `CEL.Program`.
  """
  @spec compile(String.t() | parsed(), Env.t()) ::
          {:ok, Program.t()} | {:error, Error.t()}
  def compile(source_or_parsed, env \\ Env.empty())

  def compile(source_or_parsed, %Env{} = env) do
    with {:ok, checked} <- check(source_or_parsed, env) do
      {:ok, Program.new(checked, env)}
    end
  end

  @doc """
  Checks CEL source or a parsed expression and bundles it with `env`, raising
  on parse or check errors.
  """
  @spec compile!(String.t() | parsed(), Env.t()) :: Program.t()
  def compile!(source_or_parsed, env \\ Env.empty()) do
    case compile(source_or_parsed, env) do
      {:ok, program} -> program
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Evaluates CEL source against `env` with the supplied variable bindings.

  This is the one-shot convenience that parses, checks, and evaluates `source`
  in a single call. To compile once and evaluate many times, build a
  `CEL.Program` with `compile/2` and evaluate it with
  `CEL.Program.eval/2`.

  The evaluator returns tagged `CEL.Value` terms so CEL runtime
  distinctions such as `int`/`uint` and `string`/`bytes` are preserved.

  A variable bound to `{:unknown, reason}` is unknown. When the result depends
  on unknown inputs, the result is `{:unknown, %CEL.Unknown{}}`; see
  `CEL.Unknown`.
  """
  @spec eval(String.t(), keyword | map, Env.t()) ::
          {:ok, Value.t()} | {:unknown, Unknown.t()} | {:error, Error.t()}
  def eval(source, values \\ %{}, env \\ Env.empty())

  def eval(source, values, %Env{} = env) when is_binary(source) do
    with {:ok, program} <- compile(source, env) do
      Program.eval(program, values)
    end
  end

  @doc """
  Evaluates CEL source against `env`, raising on parse, check, or eval errors
  and on unknown results.
  """
  @spec eval!(String.t(), keyword | map, Env.t()) :: Value.t()
  def eval!(source, values \\ %{}, env \\ Env.empty()) do
    source |> eval(values, env) |> Program.unwrap!()
  end

  @doc """
  Reads `name.f1.f2...` from `values` as evaluating that expression with `env`
  would, but tells an unset field apart from one set to its default.

  Returns `:absent` when `has()` is false at some step of the path: a field
  with presence that is unset (for a proto3 field without presence, one that
  holds its default), or a map key that is missing. Otherwise returns what
  evaluation would. `path` is a list of field names or map keys, as in the
  `{:var, name, path}` arguments of `CEL.Checked.references/1`; `name` must
  be a variable declared in `env`.

      env = CEL.Env.build(vars: [req: {:map, :string, :string}])

      CEL.select(env, %{req: %{"a" => ""}}, "req", ["a"])
      #=> {:ok, {:string, ""}}

      CEL.select(env, %{req: %{}}, "req", ["a"])
      #=> :absent
  """
  @spec select(Env.t(), keyword | map, atom | String.t(), [String.t()]) ::
          {:ok, Value.t()} | :absent | {:unknown, Unknown.t()} | {:error, Error.t()}
  def select(%Env{} = env, values, name, path) when is_list(path) do
    root = %{id: 1, expr_kind: {:ident_expr, %{name: to_string(name)}}}

    {expr, _next_id} =
      Enum.reduce(path, {root, 2}, fn field, {operand, id} when is_binary(field) ->
        key = %{id: id, expr_kind: {:const_expr, %{constant_kind: {:string_value, field}}}}
        select = {:call_expr, %{function: "_?._", args: [operand, key]}}
        {%{id: id + 1, expr_kind: select}, id + 2}
      end)

    source_info = %{location: "<select>", positions: %{}, macro_calls: %{}, line_offsets: []}

    with {:ok, program} <- compile(%{expr: expr, source_info: source_info}, env) do
      case {path, Program.eval(program, values)} do
        {[_ | _], {:ok, {:optional, :none}}} -> :absent
        {[_ | _], {:ok, {:optional, {:some, value}}}} -> {:ok, value}
        {_path, result} -> result
      end
    end
  end
end

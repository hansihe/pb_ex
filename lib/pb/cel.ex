defmodule PB.CEL do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Common Expression Language support for PB.
  #
  # CEL source text can be parsed into the standard `cel.expr.ParsedExpr`
  # protobuf shape and checked into `PB.CEL.Checked`. Later phases consume
  # this PB-native checked representation for runtime evaluation. Convert to
  # standard `cel.expr.CheckedExpr` explicitly with
  # `PB.CEL.Checked.to_proto/1` when needed.
  #
  # ## Environments
  #
  # Checker configuration — variable declarations, function registry, container,
  # and schema — is carried in a `PB.CEL.Env` struct. Build one with
  # `PB.CEL.Env.build/1` and pass it positionally to `check/2`, `compile/2`,
  # and `eval/3`:
  #
  #     env =
  #       PB.CEL.Env.build(
  #         schema: schema,
  #         container: "my.pkg",
  #         vars: [name: :string, ids: {:list, :int}],
  #         functions: [greet_fn]
  #       )
  #
  #     # one-shot — `eval/3` takes source only and parses + checks + evaluates
  #     {:ok, value} = PB.CEL.eval(source, %{"name" => "alice"}, env)
  #
  #     # pre-compile once, run many — `compile/2` returns a `Program` and
  #     # `eval_program/2` evaluates it; `PB.CEL.Program.eval/2` works too
  #     {:ok, program} = PB.CEL.compile(source, env)
  #     {:ok, value}   = PB.CEL.eval_program(program, %{"name" => "alice"})
  #
  # A compiled `PB.CEL.Program` carries its env so re-passing schema or
  # functions at eval time is not needed. `PB.CEL.Checked` values represent
  # the check-phase output and are not direct inputs to evaluation: bundle one
  # with its env into a `Program` (`PB.CEL.Program.new/2`) to evaluate it.
  #
  # ## Custom functions
  #
  # Custom functions are registered in the `PB.CEL.Env` passed to `check/2`,
  # `compile/2`, and `eval/3`. Each function is declared with a function struct
  # whose overloads carry checker signatures plus an optional executable `:eval`
  # MFA — see the "Writing a custom CEL function" guide for the shape. The MFA
  # must be a 2-tuple of
  # `{Module, function_atom}`; closures and anonymous functions are rejected at
  # registration time so registered functions remain introspectable.
  # Registration validates only the MFA shape (`Mod` and `Fun` must be atoms); it
  # does not check module/function existence, so a missing `Mod.Fun/arity` at
  # dispatch time raises `:undef` to the caller.
  #
  # The eval target receives the list of evaluated `PB.CEL.Value` arguments.
  # For receiver-mode calls the target value is prepended to that list. The
  # target must return `{:ok, value} | {:unknown, reason} | {:error, reason}`.
  # It is not called with error or unknown arguments unless the overload sets
  # `strict: false`, in which case they arrive as `{:error, %PB.CEL.Error{}}`
  # and `{:unknown, %PB.CEL.Unknown{}}`.
  # An overload's `:eval_context` appends extra arguments; `:vars` passes the
  # variable bindings given to eval, keyed by string name, and `:call` passes
  # `%{function: name, overload_id: id, expr_id: id}` for the call being
  # evaluated.
  #
  #     alias PB.CEL.Function
  #     alias PB.CEL.Function.Overload
  #
  #     defmodule MyHandlers do
  #       def greet([{:string, name}]), do: {:ok, {:string, "Hello, " <> name}}
  #     end
  #
  #     function = %Function{
  #       name: "greet",
  #       overloads: [
  #         %Overload{
  #           id: "greet_string",
  #           args: [:string],
  #           result: :string,
  #           eval: {MyHandlers, :greet}
  #         }
  #       ]
  #     }
  #
  #     env = PB.CEL.Env.build(functions: [function])
  #     {:ok, value} = PB.CEL.eval(~s|greet("world")|, %{}, env)
  #
  # Overloads without an `:eval` MFA are accepted as check-only declarations; an
  # attempt to evaluate such a call raises an evaluator error.
  @moduledoc false

  alias PB.CEL.Checked
  alias PB.CEL.Checker
  alias PB.CEL.Env
  alias PB.CEL.Error
  alias PB.CEL.Program
  alias PB.CEL.Proto
  alias PB.CEL.Syntax.MacroExpander
  alias PB.CEL.Syntax.Parser
  alias PB.CEL.Unknown
  alias PB.CEL.Value
  alias PB.Runtime.Errors, as: RuntimeErrors
  alias PB.Runtime.Options

  @parse_options [location: {:any, "<input>"}, macros: {:boolean, true}]

  @doc """
  Parses CEL source into a `cel.expr.ParsedExpr` map.

  ## Options

    * `:location` - where the source came from, such as a file name. Parse
      and check errors report it in `PB.CEL.Error`'s `:location`. Defaults to
      `"<input>"`.
    * `:macros` - whether to expand the standard macros (`has`, `all`,
      `exists`, `exists_one`, `map`, `filter`, `cel.bind`, `optMap`,
      `optFlatMap`). Defaults to `true`.

  Raises `PB.OptionError` for an unknown option or an invalid value.
  """
  @spec parse(String.t(), keyword) :: {:ok, Proto.parsed_expr()} | {:error, Error.t()}
  def parse(source, opts \\ []) when is_binary(source) do
    opts =
      case Options.validate(opts, @parse_options) do
        {:ok, opts} -> opts
        {:error, reason} -> raise RuntimeErrors.to_error(reason)
      end

    with {:ok, parsed} <- Parser.parse(source, location: opts.location) do
      if opts.macros, do: MacroExpander.expand(parsed), else: {:ok, parsed}
    end
  end

  @doc """
  Parses CEL source into a `cel.expr.ParsedExpr` map, raising on errors.
  """
  @spec parse!(String.t(), keyword) :: Proto.parsed_expr()
  def parse!(source, opts \\ []) when is_binary(source) do
    case parse(source, opts) do
      {:ok, parsed} -> parsed
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Checks CEL source or a parsed expression into a `PB.CEL.Checked` value.

  The second argument must be a `PB.CEL.Env`.

  Passing a pre-parsed expression skips parser resource limits and assumes the
  AST came from `parse/2` or another trusted producer.

  Variable declaration values may be checker-native types, generated
  `cel.expr.Type` maps (see `PB.CEL.ProtoType`), or shorthand atoms/tuples such as
  `:int`, `{:list, :string}`, or `{:map, :string, :dyn}`.
  """
  @spec check(String.t() | Proto.parsed_expr(), Env.t()) ::
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
  @spec check!(String.t() | Proto.parsed_expr(), Env.t()) :: Checked.t()
  def check!(source_or_parsed, env \\ Env.empty()) do
    case check(source_or_parsed, env) do
      {:ok, checked} -> checked
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Checks CEL source or a parsed expression and bundles the result with the
  supplied environment as a `PB.CEL.Program`.

  Programs carry their environment so eval callers do not have to re-pass
  schema or function declarations on every call. See `PB.CEL.Program`.
  """
  @spec compile(String.t() | Proto.parsed_expr(), Env.t()) ::
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
  @spec compile!(String.t() | Proto.parsed_expr(), Env.t()) :: Program.t()
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
  `PB.CEL.Program` with `compile/2` and evaluate it with
  `PB.CEL.Program.eval/2`.

  The evaluator returns tagged `PB.CEL.Value` terms so CEL runtime
  distinctions such as `int`/`uint` and `string`/`bytes` are preserved.

  A variable bound to `{:unknown, reason}` is unknown. When the result depends
  on unknown inputs, the result is `{:unknown, %PB.CEL.Unknown{}}`; see
  `PB.CEL.Unknown`.
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
end

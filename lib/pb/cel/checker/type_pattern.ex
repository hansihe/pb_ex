defmodule PB.CEL.Checker.TypePattern do
  @moduledoc false

  # Type-pattern language used by `PB.CEL.Function.Overload` to declare
  # argument patterns and by `PB.CEL.Checker.Signatures.Matcher` to match calls
  # against them.
  #
  # ## Concrete leaf types (reused from `PB.CEL.Checker.Types`)
  #
  # The following tagged-tuple constructors are shared with `PB.CEL.Checker.Types`
  # and carry the same semantics here as they do in the checker's type system:
  #
  #   * `{:list, elem_type}` — homogeneous list
  #   * `{:map, key_type, value_type}` — map
  #   * `{:message, name}` — protobuf message type
  #   * `{:optional, value_type}` — optional wrapper
  #   * `{:abstract, name, params}` — abstract/parameterised type
  #
  # ## Pattern-only constructs (live in this module)
  #
  # The following atoms and tagged tuples are pattern-only and have no counterpart in
  # `PB.CEL.Checker.Types`:
  #
  #   * `:any` — matches any type
  #   * `:dyn` — matches the dynamic (dyn) type
  #   * `:numeric` — matches any numeric type (int, uint, double)
  #   * `:integral` — matches integer types (int, uint)
  #   * `{:param, name}` — named type parameter (generic overloads)
  #   * `{:one_of, patterns}` — matches any one of the given patterns
  #   * `{:repeat, pattern, min}` — variadic tail; at least `min` occurrences

  @type t ::
          :any
          | :dyn
          | :dynamic
          | :null
          | :bool
          | :int
          | :uint
          | :double
          | :numeric
          | :integral
          | :string
          | :bytes
          | :list
          | :map
          | :message
          | :timestamp
          | :duration
          | {:param, atom}
          | {:type, t}
          | {:list, t}
          | {:map, t, t}
          | {:message, String.t()}
          | {:abstract, String.t(), [t]}
          | {:one_of, [t]}
          | {:optional, t}
          | {:repeat, t, non_neg_integer}

  @spec param(atom) :: t
  def param(name) when is_atom(name), do: {:param, name}

  @spec list(t) :: t
  def list(elem), do: {:list, elem}

  @spec map(t, t) :: t
  def map(key, value), do: {:map, key, value}

  @spec optional(t) :: t
  def optional(value), do: {:optional, value}

  @spec abstract(String.t(), [t]) :: t
  def abstract(name, params), do: {:abstract, name, params}

  @spec one_of([t]) :: t
  def one_of(matchers) when is_list(matchers), do: {:one_of, matchers}

  @spec repeat(t, keyword) :: t
  def repeat(matcher, opts \\ []) do
    min = Keyword.get(opts, :min, 0)

    if is_integer(min) and min >= 0 do
      {:repeat, matcher, min}
    else
      raise ArgumentError, "repeat min must be a non-negative integer"
    end
  end

  @spec expand_args([t], [term]) :: {:ok, [t]} | :error
  def expand_args(patterns, values) do
    case List.last(patterns) do
      {:repeat, matcher, min} ->
        prefix = Enum.drop(patterns, -1)
        repeat_count = length(values) - length(prefix)

        if repeat_count >= min and not Enum.any?(prefix, &repeat_matcher?/1) do
          {:ok, prefix ++ List.duplicate(matcher, repeat_count)}
        else
          :error
        end

      _matcher ->
        if length(patterns) == length(values) and not Enum.any?(patterns, &repeat_matcher?/1) do
          {:ok, patterns}
        else
          :error
        end
    end
  end

  @spec generic?(t | {:arg, non_neg_integer}) :: boolean
  def generic?({:arg, _index}), do: false
  def generic?({:param, _name}), do: true
  def generic?({:type, type}), do: generic?(type)
  def generic?({:list, elem_type}), do: generic?(elem_type)

  def generic?({:map, key_type, value_type}),
    do: generic?(key_type) or generic?(value_type)

  def generic?({:abstract, _name, params}), do: Enum.any?(params, &generic?/1)
  def generic?({:one_of, matchers}), do: Enum.any?(matchers, &generic?/1)
  def generic?({:optional, value_type}), do: generic?(value_type)
  def generic?({:repeat, matcher, _min}), do: generic?(matcher)
  def generic?(_matcher), do: false

  defp repeat_matcher?({:repeat, _matcher, _min}), do: true
  defp repeat_matcher?(_matcher), do: false
end

defmodule PB.CEL.Regexes do
  @moduledoc false

  # Regular expressions for CEL `matches()` and protovalidate `string.pattern`.
  #
  # CEL specifies RE2. PB uses PCRE, configured to stay close where it is
  # cheap: patterns are Unicode-aware (`.` matches a code point, as in RE2)
  # without Unicode classes (`\w`, `\d` and `\s` stay ASCII, as in RE2), and a
  # match gives up with an error after a bounded number of steps, since PCRE
  # backtracks where RE2 runs in linear time. Syntax RE2 rejects (lookaround,
  # backreferences) is still accepted.
  #
  # Patterns known when a program is built are compiled once, by
  # `precompile/2`; the evaluator looks them up by call expression id.

  alias PB.CEL.Checked

  @matches_eval {:mfa, {PB.CEL.Runtime.Strings, :matches}}
  @match_limit 1_000_000

  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def compile(pattern) do
    case Regex.compile(pattern, [:unicode]) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, at}} -> {:error, "invalid regex at #{at}: #{reason}"}
    end
  end

  @spec match(Regex.t(), String.t()) :: {:ok, boolean} | {:error, String.t()}
  def match(%Regex{re_pattern: pattern}, string) do
    case :re.run(string, pattern, [
           {:capture, :none},
           {:match_limit, @match_limit},
           :report_errors
         ]) do
      :match -> {:ok, true}
      :nomatch -> {:ok, false}
      {:error, :match_limit} -> {:error, "regex match exceeded #{@match_limit} steps"}
      {:error, reason} -> {:error, "regex match failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Compiles the `matches()` patterns of a checked expression that are known
  before evaluation: string literals, and selections from `vars` (the rule
  values protovalidate binds as constants). Returns the regexes by call id.
  """
  @spec precompile(Checked.t(), map) ::
          {:ok, %{Checked.expr_id() => Regex.t()}} | {:error, String.t()}
  def precompile(%Checked{ops: ops}, vars) do
    Enum.reduce_while(ops, {:ok, %{}}, fn
      {id, {:call, %{eval: @matches_eval} = op}}, {:ok, regexes} ->
        with {:ok, pattern} <- static_match_pattern(op, ops, vars),
             {:ok, regex} <- compile(pattern) do
          {:cont, {:ok, Map.put(regexes, id, regex)}}
        else
          :dynamic -> {:cont, {:ok, regexes}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _op, acc ->
        {:cont, acc}
    end)
  end

  defp static_match_pattern(%{arg_ids: []}, _ops, _vars), do: :dynamic

  defp static_match_pattern(%{arg_ids: arg_ids}, ops, vars) do
    case static_value(List.last(arg_ids), ops, vars, MapSet.new()) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> :dynamic
    end
  end

  defp static_value(id, ops, vars, seen) when is_integer(id) do
    if MapSet.member?(seen, id) do
      :dynamic
    else
      seen = MapSet.put(seen, id)

      case Map.get(ops, id) do
        {:const, %{value: {:string, value}}} ->
          {:ok, value}

        {:ident, %{kind: :var, name: name}} ->
          Map.fetch(vars, name)

        {:select, %{receiver_id: receiver_id} = select} ->
          case static_value(receiver_id, ops, vars, seen) do
            {:ok, receiver} -> static_select(receiver, select)
            _dynamic -> :dynamic
          end

        _other ->
          :dynamic
      end
    end
  end

  defp static_value(_id, _ops, _vars, _seen), do: :dynamic

  defp static_select(value, select) when is_map(value) and not is_struct(value) do
    select
    |> static_select_keys()
    |> Enum.find_value(:dynamic, fn key ->
      case Map.fetch(value, key) do
        {:ok, value} -> {:ok, value}
        :error -> false
      end
    end)
  end

  defp static_select(_value, _select), do: :dynamic

  defp static_select_keys(select) do
    [
      get_in(select, [:field_ref, :field]),
      Map.get(select, :field)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end

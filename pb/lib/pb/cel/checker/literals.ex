defmodule PB.CEL.Checker.Literals do
  @moduledoc false

  # Opt-in validation of literal arguments, like cel-go's
  # `ValidateDurationLiterals`, `ValidateTimestampLiterals` and
  # `ValidateRegexLiterals`: a `duration()` or `timestamp()` conversion of a
  # string literal, or a `matches()` with a literal pattern, is run at check
  # time with the evaluator's own code, and a failure becomes a check error at
  # the literal. Off by default, because CEL reports these when evaluated and
  # the conformance suite expects that.

  alias PB.CEL.Error
  alias PB.CEL.Regexes
  alias PB.CEL.Runtime.Convert

  @kinds [:duration, :timestamp, :regex]

  @kinds_by_eval %{
    {:mfa, {Convert, :to_duration}} => :duration,
    {:mfa, {Convert, :to_timestamp}} => :timestamp,
    {:mfa, {PB.CEL.Runtime.Strings, :matches}} => :regex
  }

  @type kind :: :duration | :timestamp | :regex

  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc """
  Returns the first invalid literal, in expression id order, among the calls
  of the given kinds.
  """
  @spec validate(%{integer => tuple}, [kind]) :: :ok | {:error, Error.t()}
  def validate(_ops, []), do: :ok

  def validate(ops, kinds) do
    ops
    |> Enum.sort()
    |> Enum.find_value(:ok, fn
      {_id, {:call, %{eval: eval, arg_ids: [_ | _] = arg_ids}}} ->
        kind = Map.get(@kinds_by_eval, eval)
        literal_id = List.last(arg_ids)

        with true <- kind in kinds,
             {:const, %{value: {:string, literal}}} <- Map.get(ops, literal_id),
             {:error, message} <- run(kind, literal) do
          {:error, Error.exception(phase: :check, message: message, expr_id: literal_id)}
        else
          _valid -> nil
        end

      _op ->
        nil
    end)
  end

  defp run(:duration, literal), do: Convert.to_duration([{:string, literal}])
  defp run(:timestamp, literal), do: Convert.to_timestamp([{:string, literal}])
  defp run(:regex, literal), do: Regexes.compile(literal)
end

defmodule PB.Validate.Context do
  @moduledoc false

  # Runtime context for protovalidate evaluation.

  alias PB.CEL.Runtime.Time, as: RuntimeTime
  alias PB.CEL.Value

  @type t :: %__MODULE__{
          now: Value.t()
        }

  defstruct [:now]

  @spec new(keyword | map) :: t
  def new(opts \\ []) do
    opts = options_map(opts)

    now =
      if Map.has_key?(opts, :now),
        do: Map.fetch!(opts, :now),
        else: System.system_time(:nanosecond)

    %__MODULE__{
      now: normalize_now(now)
    }
  end

  @doc false
  @spec from_options(keyword) :: t
  def from_options(opts) when is_list(opts) do
    case Keyword.get(opts, :context) do
      nil -> new(opts)
      %__MODULE__{} = context -> context
      context when is_list(context) or is_map(context) -> new(context)
      context -> raise ArgumentError, "invalid PB validation context: #{inspect(context)}"
    end
  end

  @doc false
  @spec vars(t) :: %{String.t() => Value.t()}
  def vars(%__MODULE__{now: now}) do
    %{"now" => now}
  end

  defp options_map(opts) when is_list(opts), do: Map.new(opts)
  defp options_map(opts) when is_map(opts), do: opts

  defp normalize_now({:timestamp, ns} = timestamp) when is_integer(ns) do
    case RuntimeTime.timestamp(ns) do
      {:ok, ^timestamp} -> timestamp
      {:error, reason} -> raise ArgumentError, "invalid PB validation now: #{reason}"
    end
  end

  defp normalize_now(ns) when is_integer(ns), do: normalize_now(Value.timestamp(ns))

  defp normalize_now(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_unix(:nanosecond)
    |> normalize_now()
  end

  defp normalize_now(value) do
    raise ArgumentError,
          "invalid PB validation now: expected unix nanoseconds, DateTime, or CEL timestamp, got #{inspect(value)}"
  end
end

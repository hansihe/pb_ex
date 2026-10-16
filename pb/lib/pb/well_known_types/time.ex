defmodule PB.WellKnownTypes.Time do
  @moduledoc false

  # Native adapters for protobuf timestamp and duration well-known types.
  #
  # The exact representation uses integer nanoseconds:
  #
  #   * `{:timestamp, unix_nanoseconds}` for `google.protobuf.Timestamp`
  #   * `{:duration, nanoseconds}` for `google.protobuf.Duration`
  #
  # This keeps protobuf nanosecond precision intact. Higher-level integrations may
  # expose lossy `DateTime` / `Duration` forms explicitly.

  alias PB.WellKnownTypes.Spec

  @nanos_per_second Spec.nanos_per_second()

  @type timestamp :: {:timestamp, integer()}
  @type duration :: {:duration, integer()}

  @projections [
    {:"google.protobuf.Timestamp",
     [
       adapter: %PB.Adapter{
         to_proto: {__MODULE__, :to_proto_timestamp},
         from_proto: {__MODULE__, :from_proto_timestamp},
         type: quote(do: PB.WellKnownTypes.Time.timestamp())
       }
     ]},
    {:"google.protobuf.Duration",
     [
       adapter: %PB.Adapter{
         to_proto: {__MODULE__, :to_proto_duration},
         from_proto: {__MODULE__, :from_proto_duration},
         type: quote(do: PB.WellKnownTypes.Time.duration())
       }
     ]}
  ]

  @doc false
  @spec projections() :: [{PB.Schema.Compiled.message_name(), keyword()}]
  def projections, do: @projections

  @spec timestamp(integer()) :: timestamp()
  def timestamp(ns) when is_integer(ns), do: {:timestamp, ns}

  @spec duration(integer()) :: duration()
  def duration(ns) when is_integer(ns), do: {:duration, ns}

  @spec to_proto_timestamp(timestamp()) :: {:ok, map()} | {:error, term}
  def to_proto_timestamp({:timestamp, ns} = value) when is_integer(ns) do
    # Validate through the shared spec on the split `%{seconds, nanos}` rather
    # than against a derived ns bound, so both directions of this adapter route
    # through the single source of truth.
    {seconds, nanos} = split_timestamp_ns(ns)

    case Spec.validate_timestamp(seconds, nanos) do
      :ok -> {:ok, %{seconds: seconds, nanos: nanos}}
      {:error, _reason} -> {:error, {:invalid_timestamp, value}}
    end
  end

  def to_proto_timestamp(value), do: {:error, {:invalid_timestamp, value}}

  @spec from_proto_timestamp(map()) :: {:ok, timestamp()} | {:error, term}
  def from_proto_timestamp(message) when is_map(message) do
    with {:ok, ns} <- timestamp_message_ns(message) do
      {:ok, timestamp(ns)}
    end
  end

  def from_proto_timestamp(value), do: {:error, {:invalid_timestamp_message, value}}

  @spec to_proto_duration(duration()) :: {:ok, map()} | {:error, term}
  def to_proto_duration({:duration, ns} = value) when is_integer(ns) do
    {seconds, nanos} = split_duration_ns(ns)

    case Spec.validate_duration(seconds, nanos) do
      :ok -> {:ok, %{seconds: seconds, nanos: nanos}}
      {:error, _reason} -> {:error, {:invalid_duration, value}}
    end
  end

  def to_proto_duration(value), do: {:error, {:invalid_duration, value}}

  @spec from_proto_duration(map()) :: {:ok, duration()} | {:error, term}
  def from_proto_duration(message) when is_map(message) do
    with {:ok, ns} <- duration_message_ns(message) do
      {:ok, duration(ns)}
    end
  end

  def from_proto_duration(value), do: {:error, {:invalid_duration_message, value}}

  defp timestamp_message_ns(message) do
    case Spec.validate_timestamp_map(message) do
      {:ok, seconds, nanos} -> {:ok, seconds * @nanos_per_second + nanos}
      {:error, {:seconds_out_of_range, _min, _max}} -> {:error, :timestamp_out_of_range}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp duration_message_ns(message) do
    case Spec.validate_duration_map(message) do
      {:ok, seconds, nanos} -> {:ok, seconds * @nanos_per_second + nanos}
      {:error, {:seconds_out_of_range, _min, _max}} -> {:error, :duration_out_of_range}
      {:error, _reason} -> {:error, :invalid_duration}
    end
  end

  defp split_timestamp_ns(ns) do
    seconds = floor_div(ns, @nanos_per_second)
    nanos = ns - seconds * @nanos_per_second
    {seconds, nanos}
  end

  defp split_duration_ns(ns), do: {div(ns, @nanos_per_second), rem(ns, @nanos_per_second)}

  defp floor_div(value, divisor) do
    quotient = div(value, divisor)
    remainder = rem(value, divisor)

    if remainder < 0, do: quotient - 1, else: quotient
  end
end

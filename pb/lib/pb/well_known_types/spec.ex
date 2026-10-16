defmodule PB.WellKnownTypes.Spec do
  @moduledoc false

  # Canonical proto-map validity rules and constants for
  # `google.protobuf.Timestamp` and `google.protobuf.Duration`, mirroring the
  # protobuf reference (`time_util.cc`): seconds and nanos are bounded
  # *independently*, plus a sign-consistency rule for Duration.
  #
  # This is the single source of truth shared by the two layers that sit on
  # opposite ends of the same `%{seconds, nanos}` proto-map pivot:
  #
  #   * the ProtoJSON backend (`PB.JSON.WKT`) — proto-map <-> JSON text;
  #   * the native time adapter (`PB.WellKnownTypes.Time`) — proto-map <->
  #     `{:timestamp | :duration, nanoseconds}`.
  #
  # Keeping the ranges/sign rules here means those two cannot drift apart.
  #
  # NOTE: CEL (`PB.CEL.Runtime.Time`) deliberately uses *different* bounds
  # (int64-nanosecond durations per the CEL spec), so it does not consume this
  # module.

  @nanos_per_second 1_000_000_000

  # Inclusive nanos magnitude: a fraction of a second is in (-1s, 1s).
  @nanos_max 999_999_999

  # Gregorian seconds at 1970-01-01T00:00:00Z (bridges Unix epoch seconds and
  # `:calendar`'s gregorian-seconds scale).
  @unix_epoch_gregorian 62_167_219_200

  # google.protobuf.Duration.seconds inclusive range (+/- 10000 years).
  @duration_min_seconds -315_576_000_000
  @duration_max_seconds 315_576_000_000

  # google.protobuf.Timestamp.seconds inclusive range
  # (0001-01-01T00:00:00Z .. 9999-12-31T23:59:59Z).
  @timestamp_min_seconds -62_135_596_800
  @timestamp_max_seconds 253_402_300_799

  @type validation_error ::
          {:non_integer, :seconds | :nanos}
          | {:seconds_out_of_range, integer(), integer()}
          | {:nanos_out_of_range, integer(), integer()}
          | {:sign_mismatch, integer(), integer()}

  # ── Constants ─────────────────────────────────────────────────────────
  # Exposed only where another module / test actually consumes the value
  # (the seconds ranges are enforced internally by the validators below, so
  # they are not part of the public accessor surface).

  @spec nanos_per_second() :: pos_integer()
  def nanos_per_second, do: @nanos_per_second

  @spec nanos_max() :: pos_integer()
  def nanos_max, do: @nanos_max

  @spec unix_epoch_gregorian() :: pos_integer()
  def unix_epoch_gregorian, do: @unix_epoch_gregorian

  @spec duration_max_seconds() :: integer()
  def duration_max_seconds, do: @duration_max_seconds

  # ── Proto-map validators ─────────────────────────────────────────────

  @doc """
  Validates a `google.protobuf.Timestamp` `%{seconds, nanos}` proto-map.

  Seconds must be in the inclusive calendar range and nanos in `[0, 1e9)`.
  """
  @spec validate_timestamp(term(), term()) :: :ok | {:error, validation_error()}
  def validate_timestamp(seconds, nanos) do
    cond do
      not is_integer(seconds) ->
        {:error, {:non_integer, :seconds}}

      not is_integer(nanos) ->
        {:error, {:non_integer, :nanos}}

      seconds < @timestamp_min_seconds or seconds > @timestamp_max_seconds ->
        seconds_error(:timestamp)

      nanos < 0 or nanos > @nanos_max ->
        {:error, {:nanos_out_of_range, 0, @nanos_max}}

      true ->
        :ok
    end
  end

  @doc """
  Validates a `google.protobuf.Duration` `%{seconds, nanos}` proto-map.

  Seconds and nanos are bounded independently (nanos in `(-1s, 1s)`) and must
  share the same sign.
  """
  @spec validate_duration(term(), term()) :: :ok | {:error, validation_error()}
  def validate_duration(seconds, nanos) do
    cond do
      not is_integer(seconds) ->
        {:error, {:non_integer, :seconds}}

      not is_integer(nanos) ->
        {:error, {:non_integer, :nanos}}

      seconds < @duration_min_seconds or seconds > @duration_max_seconds ->
        seconds_error(:duration)

      nanos < -@nanos_max or nanos > @nanos_max ->
        {:error, {:nanos_out_of_range, -@nanos_max, @nanos_max}}

      seconds > 0 and nanos < 0 ->
        {:error, {:sign_mismatch, seconds, nanos}}

      seconds < 0 and nanos > 0 ->
        {:error, {:sign_mismatch, seconds, nanos}}

      true ->
        :ok
    end
  end

  @doc """
  Like `validate_timestamp/2` but reads `:seconds`/`:nanos` (defaulting to 0)
  from a proto-map and returns the extracted pair on success, so callers do not
  each re-derive it.
  """
  @spec validate_timestamp_map(map()) ::
          {:ok, integer(), integer()} | {:error, validation_error()}
  def validate_timestamp_map(map) do
    seconds = Map.get(map, :seconds, 0)
    nanos = Map.get(map, :nanos, 0)

    with :ok <- validate_timestamp(seconds, nanos), do: {:ok, seconds, nanos}
  end

  @doc """
  Like `validate_duration/2` but reads `:seconds`/`:nanos` (defaulting to 0)
  from a proto-map and returns the extracted pair on success.
  """
  @spec validate_duration_map(map()) :: {:ok, integer(), integer()} | {:error, validation_error()}
  def validate_duration_map(map) do
    seconds = Map.get(map, :seconds, 0)
    nanos = Map.get(map, :nanos, 0)

    with :ok <- validate_duration(seconds, nanos), do: {:ok, seconds, nanos}
  end

  defp seconds_error(:timestamp),
    do: {:error, {:seconds_out_of_range, @timestamp_min_seconds, @timestamp_max_seconds}}

  defp seconds_error(:duration),
    do: {:error, {:seconds_out_of_range, @duration_min_seconds, @duration_max_seconds}}
end

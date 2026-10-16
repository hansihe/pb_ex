defmodule PB.CEL.Runtime.Time do
  @moduledoc false

  alias PB.CEL.Value
  alias PB.WellKnownTypes.Time, as: WKTTime

  @nanos_per_microsecond 1_000
  @nanos_per_millisecond 1_000_000
  @nanos_per_second 1_000_000_000
  @nanos_per_minute 60 * @nanos_per_second
  @nanos_per_hour 60 * @nanos_per_minute
  @nanos_per_day 24 * @nanos_per_hour

  @duration_min_ns -9_223_372_036_854_775_808
  @duration_max_ns 9_223_372_036_854_775_807
  @timestamp_min_ns -62_135_596_800 * @nanos_per_second
  @timestamp_max_ns 253_402_300_799 * @nanos_per_second + 999_999_999

  @epoch ~D[1970-01-01]
  @timestamp_pattern ~r/\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})\z/
  @duration_component_pattern ~r/\A(\d+(?:\.\d+)?)(h|ms|us|ns|m|s)/

  @type comparison :: :lt | :eq | :gt
  @type result :: {:ok, Value.t()} | {:error, String.t()} | :error
  @type mfa_result :: {:ok, Value.t()} | {:error, String.t()}

  @spec timestamp(integer()) :: {:ok, WKTTime.timestamp()} | {:error, String.t()}
  def timestamp(ns) when is_integer(ns) do
    if timestamp_ns?(ns), do: {:ok, WKTTime.timestamp(ns)}, else: {:error, "timestamp range"}
  end

  @spec duration(integer()) :: {:ok, WKTTime.duration()} | {:error, String.t()}
  def duration(ns) when is_integer(ns) do
    if duration_ns?(ns), do: {:ok, WKTTime.duration(ns)}, else: {:error, "duration range"}
  end

  @spec duration_ns?(integer()) :: boolean()
  def duration_ns?(ns) when is_integer(ns), do: ns >= @duration_min_ns and ns <= @duration_max_ns

  @spec timestamp_ns?(integer()) :: boolean()
  def timestamp_ns?(ns) when is_integer(ns),
    do: ns >= @timestamp_min_ns and ns <= @timestamp_max_ns

  @spec parse_timestamp(String.t()) :: {:ok, WKTTime.timestamp()} | {:error, String.t()}
  def parse_timestamp(string) when is_binary(string) do
    with [_, year, month, day, hour, minute, second, fraction, zone] <-
           Regex.run(@timestamp_pattern, string),
         {:ok, offset_seconds} <- parse_rfc3339_offset(zone),
         {:ok, ns} <-
           timestamp_ns(year, month, day, hour, minute, second, fraction, offset_seconds),
         {:ok, timestamp} <- timestamp(ns) do
      {:ok, timestamp}
    else
      nil -> {:error, "invalid timestamp"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_duration(String.t()) :: {:ok, WKTTime.duration()} | {:error, String.t()}
  def parse_duration("0"), do: {:ok, WKTTime.duration(0)}

  def parse_duration(string) when is_binary(string) do
    {sign, rest} =
      case string do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        rest -> {1, rest}
      end

    with false <- rest == "",
         {:ok, ns} <- parse_duration_components(rest, 0),
         {:ok, duration} <- duration(sign * ns) do
      {:ok, duration}
    else
      true -> {:error, "invalid duration"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec format_timestamp(WKTTime.timestamp()) :: {:ok, String.t()} | {:error, String.t()}
  def format_timestamp({:timestamp, ns}) when is_integer(ns) do
    if timestamp_ns?(ns) do
      parts = datetime_parts(ns)

      {:ok,
       pad(parts.year, 4) <>
         "-" <>
         pad(parts.month, 2) <>
         "-" <>
         pad(parts.day, 2) <>
         "T" <>
         pad(parts.hour, 2) <>
         ":" <>
         pad(parts.minute, 2) <>
         ":" <>
         pad(parts.second, 2) <>
         fractional_suffix(parts.nanos) <>
         "Z"}
    else
      {:error, "timestamp range"}
    end
  end

  @spec format_duration(WKTTime.duration()) :: {:ok, String.t()} | {:error, String.t()}
  def format_duration({:duration, ns}) when is_integer(ns) do
    if duration_ns?(ns) do
      sign = if ns < 0, do: "-", else: ""
      abs_ns = abs(ns)
      seconds = div(abs_ns, @nanos_per_second)
      nanos = rem(abs_ns, @nanos_per_second)

      {:ok, sign <> Integer.to_string(seconds) <> fractional_suffix(nanos) <> "s"}
    else
      {:error, "duration range"}
    end
  end

  @spec convert(atom(), Value.t()) :: result
  def convert(:timestamp, {:timestamp, _ns} = value), do: {:ok, value}
  def convert(:timestamp, {:int, seconds}), do: checked_timestamp(seconds * @nanos_per_second)
  def convert(:timestamp, {:string, value}), do: parse_timestamp(value)
  def convert(:duration, {:duration, _ns} = value), do: {:ok, value}
  def convert(:duration, {:string, value}), do: parse_duration(value)
  def convert(:int, {:timestamp, ns}), do: {:ok, Value.int(floor_div(ns, @nanos_per_second))}

  def convert(:string, {:timestamp, _ns} = value),
    do: value |> format_timestamp() |> wrap_string()

  def convert(:string, {:duration, _ns} = value), do: value |> format_duration() |> wrap_string()
  def convert(_target, _value), do: :error

  @spec add(Value.t(), Value.t()) :: result
  def add({:timestamp, timestamp_ns}, {:duration, duration_ns}) do
    checked_timestamp(timestamp_ns + duration_ns)
  end

  def add({:duration, duration_ns}, {:timestamp, timestamp_ns}) do
    checked_timestamp(timestamp_ns + duration_ns)
  end

  def add({:duration, left}, {:duration, right}), do: checked_duration(left + right)
  def add(_left, _right), do: :error

  @spec subtract(Value.t(), Value.t()) :: result
  def subtract({:timestamp, left}, {:timestamp, right}), do: checked_duration(left - right)
  def subtract({:timestamp, left}, {:duration, right}), do: checked_timestamp(left - right)
  def subtract({:duration, left}, {:duration, right}), do: checked_duration(left - right)
  def subtract(_left, _right), do: :error

  @spec compare(Value.t(), Value.t()) :: {:ok, comparison()} | :error
  def compare({:timestamp, left}, {:timestamp, right}), do: {:ok, compare_ns(left, right)}
  def compare({:duration, left}, {:duration, right}), do: {:ok, compare_ns(left, right)}
  def compare(_left, _right), do: :error

  @spec get_date([Value.t()]) :: mfa_result
  def get_date(values), do: timestamp_field(values, fn parts -> parts.day end)

  @spec get_day_of_month([Value.t()]) :: mfa_result
  def get_day_of_month(values), do: timestamp_field(values, fn parts -> parts.day - 1 end)

  @spec get_day_of_week([Value.t()]) :: mfa_result
  def get_day_of_week(values) do
    timestamp_field(values, fn parts -> rem(Date.day_of_week(parts.date), 7) end)
  end

  @spec get_day_of_year([Value.t()]) :: mfa_result
  def get_day_of_year(values),
    do: timestamp_field(values, fn parts -> Date.day_of_year(parts.date) - 1 end)

  @spec get_full_year([Value.t()]) :: mfa_result
  def get_full_year(values), do: timestamp_field(values, fn parts -> parts.year end)

  @spec get_hours([Value.t()]) :: mfa_result
  def get_hours([{:duration, ns}]), do: {:ok, Value.int(div(ns, @nanos_per_hour))}
  def get_hours(values), do: timestamp_field(values, fn parts -> parts.hour end)

  @spec get_milliseconds([Value.t()]) :: mfa_result
  def get_milliseconds([{:duration, ns}]) do
    {:ok, Value.int(ns |> rem(@nanos_per_second) |> div(@nanos_per_millisecond))}
  end

  def get_milliseconds(values) do
    timestamp_field(values, fn parts -> div(parts.nanos, @nanos_per_millisecond) end)
  end

  @spec get_minutes([Value.t()]) :: mfa_result
  def get_minutes([{:duration, ns}]), do: {:ok, Value.int(div(ns, @nanos_per_minute))}
  def get_minutes(values), do: timestamp_field(values, fn parts -> parts.minute end)

  @spec get_month([Value.t()]) :: mfa_result
  def get_month(values), do: timestamp_field(values, fn parts -> parts.month - 1 end)

  @spec get_seconds([Value.t()]) :: mfa_result
  def get_seconds([{:duration, ns}]), do: {:ok, Value.int(div(ns, @nanos_per_second))}
  def get_seconds(values), do: timestamp_field(values, fn parts -> parts.second end)

  defp timestamp_ns(year, month, day, hour, minute, second, fraction, offset_seconds) do
    with {:ok, year} <- parse_int(year),
         {:ok, month} <- parse_int(month),
         {:ok, day} <- parse_int(day),
         {:ok, hour} <- parse_int(hour),
         {:ok, minute} <- parse_int(minute),
         {:ok, second} <- parse_int(second),
         {:ok, nanos} <- parse_fraction(fraction),
         :ok <- validate_time(hour, minute, second),
         {:ok, date} <- valid_date(year, month, day) do
      days = Date.diff(date, @epoch)

      ns =
        days * @nanos_per_day +
          hour * @nanos_per_hour +
          minute * @nanos_per_minute +
          second * @nanos_per_second +
          nanos -
          offset_seconds * @nanos_per_second

      {:ok, ns}
    end
  end

  defp valid_date(year, month, day) do
    if year < 1 or year > 9999 do
      {:error, "timestamp range"}
    else
      case Date.new(year, month, day) do
        {:ok, date} -> {:ok, date}
        {:error, _reason} -> {:error, "invalid timestamp"}
      end
    end
  end

  defp validate_time(hour, minute, second) do
    # `second` is capped at 59 here, NOT 60: CEL's `timestamp()` follows RFC 3339
    # as the CEL-go reference does (Go's time.Parse), which rejects the
    # leap-second form `23:59:60`. This is a deliberate divergence from the
    # ProtoJSON Timestamp parser (`PB.JSON.WKT`), which accepts and smears `:60`
    # per protobuf's own rules — do not "unify" the two or CEL conformance breaks.
    if hour in 0..23 and minute in 0..59 and second in 0..59 do
      :ok
    else
      {:error, "invalid timestamp"}
    end
  end

  defp parse_fraction(""), do: {:ok, 0}

  defp parse_fraction(fraction) do
    {:ok, fraction |> String.pad_trailing(9, "0") |> String.to_integer()}
  end

  defp parse_rfc3339_offset("Z"), do: {:ok, 0}

  defp parse_rfc3339_offset(<<sign, hour::binary-size(2), ":", minute::binary-size(2)>>)
       when sign in [?+, ?-] do
    with {:ok, seconds} <- fixed_offset_seconds(hour, minute) do
      if sign == ?-, do: {:ok, -seconds}, else: {:ok, seconds}
    end
  end

  defp parse_rfc3339_offset(_zone), do: {:error, "invalid timestamp"}

  defp parse_duration_components("", total), do: {:ok, total}

  defp parse_duration_components(rest, total) do
    case Regex.run(@duration_component_pattern, rest) do
      [component, number, unit] ->
        with {:ok, ns} <- duration_component_ns(number, unit) do
          parse_duration_components(String.slice(rest, byte_size(component)..-1//1), total + ns)
        end

      nil ->
        {:error, "invalid duration"}
    end
  end

  defp duration_component_ns(number, unit) do
    with {:ok, numerator, denominator} <- decimal_parts(number) do
      ns = numerator * unit_ns(unit)

      if rem(ns, denominator) == 0 do
        {:ok, div(ns, denominator)}
      else
        {:error, "duration range"}
      end
    end
  end

  defp decimal_parts(number) do
    case String.split(number, ".", parts: 2) do
      [whole] ->
        {:ok, String.to_integer(whole), 1}

      [whole, fraction] ->
        denominator = pow10(byte_size(fraction))
        numerator = String.to_integer(whole) * denominator + String.to_integer(fraction)
        {:ok, numerator, denominator}
    end
  end

  defp unit_ns("h"), do: @nanos_per_hour
  defp unit_ns("m"), do: @nanos_per_minute
  defp unit_ns("s"), do: @nanos_per_second
  defp unit_ns("ms"), do: @nanos_per_millisecond
  defp unit_ns("us"), do: @nanos_per_microsecond
  defp unit_ns("ns"), do: 1

  defp timestamp_field([{:timestamp, ns}], field), do: timestamp_field(ns, "UTC", field)

  defp timestamp_field([{:timestamp, ns}, {:string, zone}], field),
    do: timestamp_field(ns, zone, field)

  defp timestamp_field(_values, _field), do: {:error, "no such overload"}

  defp timestamp_field(ns, zone, field) do
    with {:ok, parts} <- timestamp_parts(ns, zone) do
      {:ok, Value.int(field.(parts))}
    end
  end

  defp timestamp_parts(ns, "UTC"), do: {:ok, datetime_parts(ns)}
  defp timestamp_parts(ns, "Z"), do: {:ok, datetime_parts(ns)}

  defp timestamp_parts(ns, zone) do
    case parse_accessor_offset(zone) do
      {:ok, offset_seconds} ->
        {:ok, datetime_parts(ns + offset_seconds * @nanos_per_second)}

      :error ->
        named_timezone_parts(ns, zone)
    end
  end

  defp parse_accessor_offset(<<sign, hour::binary-size(2), ":", minute::binary-size(2)>>)
       when sign in [?+, ?-] do
    with {:ok, seconds} <- fixed_offset_seconds(hour, minute) do
      if sign == ?-, do: {:ok, -seconds}, else: {:ok, seconds}
    end
  end

  defp parse_accessor_offset(<<hour::binary-size(2), ":", minute::binary-size(2)>>) do
    fixed_offset_seconds(hour, minute)
  end

  defp parse_accessor_offset(_zone), do: :error

  defp named_timezone_parts(ns, zone) do
    micros = floor_div(ns, @nanos_per_microsecond)

    with {:ok, utc} <- DateTime.from_unix(micros, :microsecond),
         {:ok, zoned} <- DateTime.shift_zone(utc, zone) do
      {:ok,
       %{
         date: DateTime.to_date(zoned),
         year: zoned.year,
         month: zoned.month,
         day: zoned.day,
         hour: zoned.hour,
         minute: zoned.minute,
         second: zoned.second,
         nanos: positive_rem(ns, @nanos_per_second)
       }}
    else
      {:error, _reason} -> {:error, "unknown timezone"}
    end
  end

  defp fixed_offset_seconds(hour, minute) do
    with {:ok, hour} <- parse_int(hour),
         {:ok, minute} <- parse_int(minute),
         true <- hour in 0..23 and minute in 0..59 do
      {:ok, hour * 3600 + minute * 60}
    else
      _other -> {:error, "invalid timezone"}
    end
  end

  defp datetime_parts(ns) do
    days = floor_div(ns, @nanos_per_day)
    day_ns = ns - days * @nanos_per_day
    date = Date.add(@epoch, days)

    hour = div(day_ns, @nanos_per_hour)
    day_ns = rem(day_ns, @nanos_per_hour)
    minute = div(day_ns, @nanos_per_minute)
    day_ns = rem(day_ns, @nanos_per_minute)
    second = div(day_ns, @nanos_per_second)
    nanos = rem(day_ns, @nanos_per_second)

    %{
      date: date,
      year: date.year,
      month: date.month,
      day: date.day,
      hour: hour,
      minute: minute,
      second: second,
      nanos: nanos
    }
  end

  defp checked_timestamp(ns), do: timestamp(ns)
  defp checked_duration(ns), do: duration(ns)

  defp compare_ns(left, right) when left < right, do: :lt
  defp compare_ns(left, right) when left > right, do: :gt
  defp compare_ns(_left, _right), do: :eq

  defp wrap_string({:ok, string}), do: {:ok, Value.string(string)}
  defp wrap_string({:error, reason}), do: {:error, reason}

  defp fractional_suffix(0), do: ""

  defp fractional_suffix(nanos) when rem(nanos, @nanos_per_millisecond) == 0 do
    "." <>
      (nanos |> div(@nanos_per_millisecond) |> Integer.to_string() |> String.pad_leading(3, "0"))
  end

  defp fractional_suffix(nanos) when rem(nanos, @nanos_per_microsecond) == 0 do
    "." <>
      (nanos |> div(@nanos_per_microsecond) |> Integer.to_string() |> String.pad_leading(6, "0"))
  end

  defp fractional_suffix(nanos) do
    "." <> (nanos |> Integer.to_string() |> String.pad_leading(9, "0"))
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, "invalid integer"}
    end
  end

  defp pad(value, count), do: value |> Integer.to_string() |> String.pad_leading(count, "0")

  defp pow10(count), do: Enum.reduce(1..count//1, 1, fn _index, acc -> acc * 10 end)

  defp floor_div(value, divisor) do
    quotient = div(value, divisor)
    remainder = rem(value, divisor)

    if remainder < 0, do: quotient - 1, else: quotient
  end

  defp positive_rem(value, divisor) do
    remainder = rem(value, divisor)
    if remainder < 0, do: remainder + divisor, else: remainder
  end
end

defmodule PB.CEL.Runtime.TimeTest do
  use ExUnit.Case, async: true

  alias PB.CEL.Runtime.Time
  alias PB.CEL.Value

  test "parses and formats timestamps with nanosecond precision" do
    assert {:ok, timestamp} = Time.parse_timestamp("9999-12-31T23:59:59.999999999Z")
    assert Time.format_timestamp(timestamp) == {:ok, "9999-12-31T23:59:59.999999999Z"}

    assert {:ok, timestamp} = Time.parse_timestamp("2009-02-13T23:31:30-02:30")
    assert Time.format_timestamp(timestamp) == {:ok, "2009-02-14T02:01:30Z"}
  end

  test "parses CEL durations and preserves nanosecond arithmetic" do
    assert Time.parse_duration("1h30m1.000000001s") ==
             {:ok, Value.duration(5_401_000_000_001)}

    assert Time.format_duration(Value.duration(60_001_000_000)) == {:ok, "60.001s"}

    assert Time.add(Value.duration(600_000_000_000), Value.duration(50_000_000_000)) ==
             {:ok, Value.duration(650_000_000_000)}
  end

  test "enforces CEL time ranges" do
    assert Time.parse_timestamp("0000-01-01T00:00:00Z") == {:error, "timestamp range"}
    assert Time.parse_duration("320000000000s") == {:error, "duration range"}

    assert Time.subtract(
             Value.timestamp(253_402_300_799_000_000_000),
             Value.timestamp(-62_135_596_800_000_000_000)
           ) == {:error, "duration range"}
  end

  test "extracts timestamp and duration fields" do
    assert Time.get_day_of_month([Value.timestamp(1_234_567_890_000_000_000)]) ==
             {:ok, Value.int(12)}

    assert Time.get_hours([
             Value.timestamp(1_234_567_890_000_000_000),
             Value.string("02:00")
           ]) ==
             {:ok, Value.int(1)}

    assert Time.get_milliseconds([Value.duration(123_321_456_789)]) ==
             {:ok, Value.int(321)}
  end
end

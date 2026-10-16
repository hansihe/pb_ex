defmodule CEL.Library.Time do
  @moduledoc false

  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Runtime.Time, as: RuntimeTime

  @timestamp_accessors [
    {"getDate", :get_date},
    {"getDayOfMonth", :get_day_of_month},
    {"getDayOfWeek", :get_day_of_week},
    {"getDayOfYear", :get_day_of_year},
    {"getFullYear", :get_full_year},
    {"getHours", :get_hours},
    {"getMilliseconds", :get_milliseconds},
    {"getMinutes", :get_minutes},
    {"getMonth", :get_month},
    {"getSeconds", :get_seconds}
  ]

  @duration_accessors [
    {"getHours", :get_hours},
    {"getMilliseconds", :get_milliseconds},
    {"getMinutes", :get_minutes},
    {"getSeconds", :get_seconds}
  ]

  @spec functions() :: [Function.t()]
  def functions do
    Enum.map(@timestamp_accessors, fn {name, runtime} ->
      %Function{
        name: name,
        modes: [:receiver],
        overloads: timestamp_overloads(name, runtime) ++ duration_overloads(name)
      }
    end)
  end

  defp timestamp_overloads(name, runtime) do
    [
      %Overload{
        id: timestamp_overload_id(name, :utc),
        args: [:timestamp],
        result: :int,
        eval: {:mfa, {RuntimeTime, runtime}}
      },
      %Overload{
        id: timestamp_overload_id(name, :tz),
        args: [:timestamp, :string],
        result: :int,
        eval: {:mfa, {RuntimeTime, runtime}}
      }
    ]
  end

  defp duration_overloads(name) do
    case Enum.find(@duration_accessors, fn {accessor_name, _runtime} -> accessor_name == name end) do
      {_name, runtime} ->
        [
          %Overload{
            id: duration_overload_id(name),
            args: [:duration],
            result: :int,
            eval: {:mfa, {RuntimeTime, runtime}}
          }
        ]

      nil ->
        []
    end
  end

  defp timestamp_overload_id(name, :utc), do: time_name(name) <> "_timestamp"
  defp timestamp_overload_id(name, :tz), do: time_name(name) <> "_timestamp_tz"
  defp duration_overload_id(name), do: time_name(name) <> "_duration"

  defp time_name(name) do
    name
    |> Macro.underscore()
    |> String.replace("get_", "time_get_")
  end
end

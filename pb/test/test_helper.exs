Application.put_env(:tzdata, :autoupdate, :disabled)
Calendar.put_time_zone_database(Tzdata.TimeZoneDatabase)

exclude = if System.find_executable("protoc"), do: [], else: [:protoc]
ExUnit.start(exclude: exclude)

Application.put_env(:tzdata, :autoupdate, :disabled)
Calendar.put_time_zone_database(Tzdata.TimeZoneDatabase)

ExUnit.start()

exclude = if System.find_executable("protoc"), do: [], else: [:protoc]
ExUnit.start(exclude: exclude)

defmodule PB.WellKnownTypesTest do
  use ExUnit.Case

  import PB.TestSupport.CodegenConsistency

  alias PB.Schema.Main
  alias PB.WellKnownTypes

  @host :"wkt_test.Host"

  @root_roundtrips [
    {:"google.protobuf.DoubleValue", 1.25},
    {:"google.protobuf.FloatValue", 1.5},
    {:"google.protobuf.Int64Value", -1_099_511_627_776},
    {:"google.protobuf.UInt64Value", 1_099_511_627_776},
    {:"google.protobuf.Int32Value", -123},
    {:"google.protobuf.UInt32Value", 123},
    {:"google.protobuf.BoolValue", true},
    {:"google.protobuf.StringValue", "text"},
    {:"google.protobuf.BytesValue", <<0, 1, 2, 255>>}
  ]

  @root_defaults [
    {:"google.protobuf.DoubleValue", 0.0},
    {:"google.protobuf.FloatValue", 0.0},
    {:"google.protobuf.Int64Value", 0},
    {:"google.protobuf.UInt64Value", 0},
    {:"google.protobuf.Int32Value", 0},
    {:"google.protobuf.UInt32Value", 0},
    {:"google.protobuf.BoolValue", false},
    {:"google.protobuf.StringValue", ""},
    {:"google.protobuf.BytesValue", ""}
  ]

  setup_all do
    %{schema: wrapper_schema()}
  end

  test "returns projection entries for wrapper types" do
    projections = WellKnownTypes.projections(:wrappers)

    assert WellKnownTypes.projections([:wrappers]) == projections

    assert Enum.all?(
             projections,
             &match?({fqn, [adapter: %PB.Adapter{}]} when is_atom(fqn), &1)
           )

    assert Enum.map(projections, fn {fqn, _opts} -> fqn end) == [
             :"google.protobuf.DoubleValue",
             :"google.protobuf.FloatValue",
             :"google.protobuf.Int64Value",
             :"google.protobuf.UInt64Value",
             :"google.protobuf.Int32Value",
             :"google.protobuf.UInt32Value",
             :"google.protobuf.BoolValue",
             :"google.protobuf.StringValue",
             :"google.protobuf.BytesValue"
           ]

    assert_raise ArgumentError,
                 ~r/unknown PB well-known type projection group :field_mask/,
                 fn ->
                   WellKnownTypes.projections(:field_mask)
                 end
  end

  test "returns projection entries for JSON value types" do
    projections = WellKnownTypes.projections(:json)

    assert Enum.all?(
             projections,
             &match?({fqn, [adapter: %PB.Adapter{}]} when is_atom(fqn), &1)
           )

    assert Enum.map(projections, fn {fqn, _opts} -> fqn end) == [
             :"google.protobuf.Value",
             :"google.protobuf.ListValue",
             :"google.protobuf.Struct"
           ]

    assert WellKnownTypes.projections([:wrappers, :json]) ==
             WellKnownTypes.projections(:wrappers) ++ projections
  end

  test "returns projection entries for time value types" do
    projections = WellKnownTypes.projections(:time)

    assert Enum.all?(
             projections,
             &match?({fqn, [adapter: %PB.Adapter{}]} when is_atom(fqn), &1)
           )

    assert Enum.map(projections, fn {fqn, _opts} -> fqn end) == [
             :"google.protobuf.Timestamp",
             :"google.protobuf.Duration"
           ]

    assert WellKnownTypes.projections([:time]) == projections
  end

  test "root time value types round-trip as exact nanosecond tuples" do
    schema =
      Main.schema() |> PB.Schema.Transform.projections(WellKnownTypes.projections(:time))

    cases = [
      {:"google.protobuf.Timestamp", {:timestamp, 1_234_567_890_123_456_789}},
      {:"google.protobuf.Duration", {:duration, -123_321_456_789}}
    ]

    Enum.each(cases, fn {fqn, value} ->
      {:ok, iodata} = PB.encode(value, schema, fqn)
      binary = IO.iodata_to_binary(iodata)

      assert {:ok, ^value} = PB.decode(binary, schema, fqn)
    end)
  end

  test "Duration boundary (max seconds with full nanos) is accepted consistently" do
    # seconds and nanos are bounded *independently* per the protobuf reference,
    # so seconds = max + nanos = 999_999_999 is valid. This layer used to reject
    # it via a combined-nanosecond range that lacked the sub-second headroom;
    # the shared spec fixes that, and the ProtoJSON backend (which already used
    # independent bounds) must agree.
    boundary = %{seconds: PB.WellKnownTypes.Spec.duration_max_seconds(), nanos: 999_999_999}
    max_ns = boundary.seconds * PB.WellKnownTypes.Spec.nanos_per_second() + boundary.nanos

    assert {:ok, {:duration, ^max_ns}} = PB.WellKnownTypes.Time.from_proto_duration(boundary)
    assert {:ok, ^boundary} = PB.WellKnownTypes.Time.to_proto_duration({:duration, max_ns})

    assert {:ok, "315576000000.999999999s"} =
             PB.JSON.to_term(boundary, Main.schema(), :"google.protobuf.Duration")
  end

  test "root wrappers round-trip as Elixir scalar values", %{schema: schema} do
    Enum.each(@root_roundtrips, fn {fqn, value} ->
      {:ok, iodata} = PB.encode(value, schema, fqn)
      binary = IO.iodata_to_binary(iodata)

      assert {:ok, ^value} = PB.decode(binary, schema, fqn)
    end)
  end

  test "root wrapper defaults decode from and encode to empty bodies", %{schema: schema} do
    Enum.each(@root_defaults, fn {fqn, default} ->
      assert {:ok, iodata} = PB.encode(default, schema, fqn)
      assert IO.iodata_to_binary(iodata) == <<>>
      assert {:ok, ^default} = PB.decode(<<>>, schema, fqn)
    end)
  end

  test "nested wrappers preserve absent versus present default values", %{schema: schema} do
    assert {:ok, %{}} = PB.decode(<<>>, schema, @host)
    assert {:ok, %{age: 0}} = PB.decode(<<0x0A, 0x00>>, schema, @host)

    assert %{age: 0} |> PB.encode!(schema, @host) |> IO.iodata_to_binary() ==
             <<0x0A, 0x00>>

    assert %{age: 7} |> PB.encode!(schema, @host) |> IO.iodata_to_binary() ==
             <<0x0A, 0x02, 0x08, 0x07>>
  end

  test "string wrappers reject invalid UTF-8", %{schema: schema} do
    value = <<255, 0, "not utf8">>

    assert {:error,
            %PB.ValueError{
              operation: :encode,
              message_name: @host,
              kind: :invalid_value,
              path: [:name, :value],
              expected: :utf8_string,
              got: :binary
            }} = PB.encode(%{name: value}, schema, @host)

    assert {:error,
            %PB.DecodeError{
              operation: :decode,
              message_name: @host,
              kind: :malformed,
              path: [:name, :value],
              reason: :invalid_utf8
            }} = PB.decode(<<0x12, 0x05, 0x0A, 0x03, 0xFF, 0x00, ?x>>, schema, @host)
  end

  test "wrapper decoders skip unknown fields and keep the last value", %{schema: schema} do
    assert {:ok, 2} =
             PB.decode(
               <<0x10, 0x7B, 0x08, 0x01, 0x08, 0x02>>,
               schema,
               :"google.protobuf.Int32Value"
             )
  end

  test "wrapper encode errors keep the parent field path", %{schema: schema} do
    assert {:error,
            %PB.ValueError{
              operation: :encode,
              message_name: @host,
              kind: :invalid_value,
              path: [:age],
              expected: :integer,
              got: :atom
            }} = PB.encode(%{age: :bad}, schema, @host)
  end

  test "root nil wrapper values encode as native defaults", %{schema: schema} do
    assert {:ok, iodata} = PB.encode(nil, schema, :"google.protobuf.Int32Value")
    assert IO.iodata_to_binary(iodata) == <<>>
    assert {:ok, 0} = PB.decode(<<>>, schema, :"google.protobuf.Int32Value")
  end

  test "wrapper decode errors keep the parent field path", %{schema: schema} do
    assert {:error,
            %PB.DecodeError{
              operation: :decode,
              message_name: @host,
              kind: :malformed,
              path: [:age, :value],
              reason: :truncated_varint
            }} = PB.decode(<<0x0A, 0x02, 0x08, 0x80>>, schema, @host)
  end

  test "wrapper values with the wrong wire type are skipped", %{schema: schema} do
    # age is an Int32Value whose value arrives as fixed32: it is an unknown
    # field of the wrapper, which the wrapper's scalar form cannot carry.
    assert PB.decode(<<0x0A, 0x05, 0x0D, 0, 0, 0, 0>>, schema, @host) == {:ok, %{age: 0}}
  end

  test "generated codecs use wrapper adapters", %{schema: schema} do
    codec = prepare_codec(schema, @host)
    message = %{age: 0, name: "bin", scores: [0, 5]}

    assert {:ok, decoded} = assert_codec_roundtrip_consistent(codec, message)
    assert decoded == message

    assert {:ok, generated} = apply(codec.module, codec.encode, [%{age: 0}])
    assert IO.iodata_to_binary(generated) == <<0x0A, 0x00>>
  end

  test "root JSON value types round-trip as JSON-shaped Elixir terms", %{schema: schema} do
    cases = [
      {:"google.protobuf.Value", nil, nil},
      {:"google.protobuf.Value", true, true},
      {:"google.protobuf.Value", 1.5, 1.5},
      {:"google.protobuf.Value", "text", "text"},
      {:"google.protobuf.Value", ["a", nil, false], ["a", nil, false]},
      {:"google.protobuf.Value", %{"nested" => [1.5]}, %{"nested" => [1.5]}},
      {:"google.protobuf.ListValue", [nil, true, %{"n" => 2.0}], [nil, true, %{"n" => 2.0}]},
      {:"google.protobuf.Struct", %{"list" => ["x", nil], "ok" => false},
       %{"list" => ["x", nil], "ok" => false}}
    ]

    Enum.each(cases, fn {fqn, value, expected} ->
      {:ok, iodata} = PB.encode(value, schema, fqn)
      binary = IO.iodata_to_binary(iodata)

      assert {:ok, ^expected} = PB.decode(binary, schema, fqn)
    end)
  end

  test "JSON Value accepts safe integers and decodes them as numbers", %{schema: schema} do
    assert {:ok, iodata} = PB.encode(42, schema, :"google.protobuf.Value")
    binary = IO.iodata_to_binary(iodata)

    assert {:ok, 42.0} = PB.decode(binary, schema, :"google.protobuf.Value")
  end

  test "JSON Value preserves absent parent fields separately from present null values", %{
    schema: schema
  } do
    assert {:ok, %{}} = PB.decode(<<>>, schema, @host)
    assert {:ok, %{payload: nil}} = PB.decode(<<0x2A, 0x00>>, schema, @host)

    encoded = %{payload: nil} |> PB.encode!(schema, @host) |> IO.iodata_to_binary()

    assert encoded == <<0x2A, 0x02, 0x08, 0x00>>
    assert {:ok, %{payload: nil}} = PB.decode(encoded, schema, @host)
  end

  test "nested JSON value types round-trip through adapted message fields", %{schema: schema} do
    message = %{
      payload: %{"items" => [nil, true, 1.5]},
      items: ["x", %{"ok" => false}],
      object: %{"name" => "Ada", "score" => 2.0}
    }

    {:ok, iodata} = PB.encode(message, schema, @host)
    binary = IO.iodata_to_binary(iodata)

    assert {:ok, ^message} = PB.decode(binary, schema, @host)
  end

  test "JSON value adapters expose reusable native typespecs", %{schema: schema} do
    type =
      schema
      |> PB.Schema.Transform.slice(roots: [@host])
      |> PB.Codegen.build()
      |> PB.Codegen.Typespec.to_string(@host)

    assert type =~ "optional(:payload) => PB.WellKnownTypes.Json.value()"
    assert type =~ "optional(:items) => PB.WellKnownTypes.Json.array()"
    assert type =~ "optional(:object) => PB.WellKnownTypes.Json.object()"
  end

  test "ProtoJSON decode honors json-value projections (native, not proto-map)", %{
    schema: schema
  } do
    # Before Phase 2, JSON decode ignored adapters and returned the proto-map
    # (`%{payload: %{kind: {:struct_value, ...}}}`). It now runs the same
    # frontend as the wire codec, so projected fields come back native.
    assert {:ok, %{payload: %{"nested" => [1.5]}, object: %{"ok" => false}}} =
             PB.JSON.from_term(
               %{"payload" => %{"nested" => [1.5]}, "object" => %{"ok" => false}},
               schema,
               @host
             )
  end

  test "ProtoJSON decode honors the time projection (native nanosecond tuple)" do
    schema = Main.schema() |> PB.Schema.Transform.projections(WellKnownTypes.projections(:time))

    assert {:ok, {:duration, 1_500_000_000}} =
             PB.JSON.from_term("1.5s", schema, :"google.protobuf.Duration")

    assert {:ok, {:timestamp, 0}} =
             PB.JSON.from_term("1970-01-01T00:00:00Z", schema, :"google.protobuf.Timestamp")
  end

  test "ProtoJSON decode stays proto-map when no projection is configured" do
    assert {:ok, %{seconds: 1, nanos: 500_000_000}} =
             PB.JSON.from_term("1.5s", Main.schema(), :"google.protobuf.Duration")
  end

  test "ProtoJSON encode honors the time projection (previously raised on native input)" do
    schema = Main.schema() |> PB.Schema.Transform.projections(WellKnownTypes.projections(:time))

    assert {:ok, "1.500s"} =
             PB.JSON.to_term({:duration, 1_500_000_000}, schema, :"google.protobuf.Duration")

    assert {:ok, "1970-01-01T00:00:00Z"} =
             PB.JSON.to_term({:timestamp, 0}, schema, :"google.protobuf.Timestamp")
  end

  test "ProtoJSON round-trips native json-value shapes through projections", %{schema: schema} do
    native = %{
      payload: %{"items" => [nil, true, 1.5]},
      items: ["x", %{"ok" => false}],
      object: %{"name" => "Ada", "score" => 2.0}
    }

    assert {:ok, json} = PB.JSON.to_term(native, schema, @host)
    assert {:ok, ^native} = PB.JSON.from_term(json, schema, @host)
  end

  test "JSON value encode errors carry proto-structural paths", %{schema: schema} do
    # Recursion is owned by the engine, so an error nested inside a Value/Struct
    # tree reports the proto-map path it walked (kind -> struct_value -> fields
    # -> ... -> value) rather than a native-shaped path. A one-level error on a
    # direct Struct field (below) still gets just the field name prepended.
    assert {:error,
            %PB.ValueError{
              operation: :encode,
              message_name: @host,
              kind: :value_out_of_range,
              path: [:payload, :kind, :struct_value, :fields, {:key, "big"}, :value],
              min: -9_007_199_254_740_991,
              max: 9_007_199_254_740_991,
              value: 9_007_199_254_740_992
            }} = PB.encode(%{payload: %{"big" => 9_007_199_254_740_992}}, schema, @host)

    assert {:error,
            %PB.ValueError{
              operation: :encode,
              message_name: @host,
              kind: :invalid_value,
              path: [:object, {:key, :bad}],
              expected: :binary_key,
              got: :atom
            }} = PB.encode(%{object: %{bad: true}}, schema, @host)
  end

  test "JSON value decoders reject non-finite number values", %{schema: schema} do
    assert {:error,
            %PB.ValueError{
              operation: :decode,
              message_name: :"google.protobuf.Value",
              kind: :invalid_value,
              path: [],
              expected: :finite_number,
              got: :atom
            }} =
             PB.decode(<<0x11, 0, 0, 0, 0, 0, 0, 248, 127>>, schema, :"google.protobuf.Value")
  end

  test "generated codecs use JSON value adapters", %{schema: schema} do
    codec = prepare_codec(schema, @host)

    message = %{
      payload: %{"items" => [nil, true, 1.5]},
      items: ["x", %{"ok" => false}],
      object: %{"name" => "Ada", "score" => 2.0}
    }

    assert {:ok, decoded} = assert_codec_roundtrip_consistent(codec, message)
    assert decoded == Map.put(message, :scores, [])

    assert {:ok, generated} = apply(codec.module, codec.encode, [%{payload: nil}])
    assert IO.iodata_to_binary(generated) == <<0x2A, 0x02, 0x08, 0x00>>
  end

  defp wrapper_schema do
    descriptor_set =
      Main.decode!(File.read!("priv/main.binpb"), :"google.protobuf.FileDescriptorSet")

    descriptor_set
    |> Map.update!(:file, &(&1 ++ [host_file()]))
    |> PB.compile(projections: WellKnownTypes.projections([:wrappers, :json]))
  end

  defp host_file do
    %{
      name: "wkt_test.proto",
      package: "wkt_test",
      syntax: "proto3",
      dependency: ["google/protobuf/struct.proto", "google/protobuf/wrappers.proto"],
      message_type: [
        %{
          name: "Host",
          field: [
            wrapper_field("age", 1, ".google.protobuf.Int32Value"),
            wrapper_field("name", 2, ".google.protobuf.StringValue"),
            wrapper_field("enabled", 3, ".google.protobuf.BoolValue"),
            wrapper_field("scores", 4, ".google.protobuf.Int32Value", :LABEL_REPEATED),
            wrapper_field("payload", 5, ".google.protobuf.Value"),
            wrapper_field("items", 6, ".google.protobuf.ListValue"),
            wrapper_field("object", 7, ".google.protobuf.Struct")
          ]
        }
      ]
    }
  end

  defp wrapper_field(name, number, type_name, label \\ :LABEL_OPTIONAL) do
    %{
      name: name,
      number: number,
      label: label,
      type: :TYPE_MESSAGE,
      type_name: type_name
    }
  end
end

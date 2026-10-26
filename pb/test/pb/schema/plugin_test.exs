defmodule PB.Schema.PluginTest.Counter do
  # Records how many messages the schema it compiled had, on the schema and on
  # every message, field, oneof, and enum it may write to. `put_new` keeps stale
  # data visible if PB failed to drop it before running the plugin again.
  @behaviour PB.Schema.Plugin

  @impl true
  def compile(schema, opts) do
    count = map_size(schema.messages)
    put = &Map.put_new(&1, __MODULE__, count)

    messages =
      Map.new(schema.messages, fn {name, message} ->
        message =
          message
          |> put.()
          |> Map.update!(:fields_by_name, &Map.new(&1, fn {k, field} -> {k, put.(field)} end))
          |> Map.update!(:oneofs, &Map.new(&1, fn {k, oneof} -> {k, put.(oneof)} end))

        {name, message}
      end)

    schema
    |> Map.put(:messages, messages)
    |> Map.update!(:enums, &Map.new(&1, fn {k, enum} -> {k, put.(enum)} end))
    |> Map.put_new(__MODULE__, %{count: count, opts: opts, prepared?: prepared?(schema)})
  end

  @impl true
  def schema_functions(opts) do
    quote do
      def plugin_count, do: {__pb_schema__()[unquote(__MODULE__)].count, unquote(opts)}
    end
  end

  defp prepared?(schema) do
    Enum.all?(schema.messages, fn {_name, message} -> Map.has_key?(message, :fields_by_number) end)
  end
end

defmodule PB.Schema.PluginTest.Follower do
  # Records what the plugin listed before it left on the schema.
  @behaviour PB.Schema.Plugin

  @impl true
  def compile(schema, _opts) do
    Map.put(schema, __MODULE__, Map.get(schema, PB.Schema.PluginTest.Counter))
  end
end

defmodule PB.Schema.PluginTest.CountedSchema do
  use PB.Schema,
    descriptor_set: PB.TestSupport.Fixtures.person_descriptor_set(),
    plugins: [{PB.Schema.PluginTest.Counter, mode: :y}, PB.Schema.PluginTest.Follower]
end

defmodule PB.Schema.PluginTest do
  use ExUnit.Case, async: true

  alias PB.Schema.PluginTest.CountedSchema
  alias PB.Schema.PluginTest.Counter
  alias PB.Schema.PluginTest.Follower
  alias PB.Schema.Transform
  alias PB.TestSupport.Fixtures

  @person :"test.Person"
  @phone :"test.PhoneNumber"

  test "plugins run in order on the prepared schema, which records them" do
    schema =
      PB.compile(Fixtures.person_descriptor_set(), plugins: [{Counter, mode: :x}, Follower])

    count = map_size(schema.messages)

    assert schema.plugins == [{Counter, [mode: :x]}, {Follower, []}]
    assert schema[Counter] == %{count: count, opts: [mode: :x], prepared?: true}
    assert schema[Follower] == schema[Counter]
    assert schema.messages[@person].fields_by_name[:name][Counter] == count
  end

  test "a schema compiled without plugins records none" do
    assert PB.compile(Fixtures.person_descriptor_set()).plugins == []
  end

  test "slice drops the recorded plugins' data and runs them again" do
    schema = PB.compile(Fixtures.person_descriptor_set(), plugins: [Counter])
    sliced = Transform.slice(schema, roots: [@phone])
    count = map_size(sliced.messages)

    assert count < map_size(schema.messages)
    assert sliced.plugins == [{Counter, []}]
    assert sliced[Counter].count == count

    assert sliced.messages[@phone][Counter] == count
    assert sliced.messages[@phone].fields_by_name[:number][Counter] == count
  end

  test "dropping plugin data clears every place a plugin may write to" do
    stripped =
      Fixtures.person_descriptor_set()
      |> PB.compile(plugins: [Counter])
      |> PB.Schema.Plugin.__strip__()

    refute Map.has_key?(stripped, Counter)

    for {_name, message} <- stripped.messages do
      refute Map.has_key?(message, Counter)
      for {_name, field} <- message.fields_by_name, do: refute(Map.has_key?(field, Counter))
      for {_index, oneof} <- message.oneofs, do: refute(Map.has_key?(oneof, Counter))
    end

    assert map_size(stripped.enums) > 0
    for {_name, enum} <- stripped.enums, do: refute(Map.has_key?(enum, Counter))
  end

  test "projections run the recorded plugins again" do
    schema = PB.compile(Fixtures.person_descriptor_set(), plugins: [Counter])
    projected = Transform.projections(schema, [{@phone, unwrap: true}])

    assert projected.plugins == [{Counter, []}]
    assert projected[Counter].prepared?
  end

  test "schema modules compile with the plugins and get their schema functions" do
    schema =
      PB.compile(Fixtures.person_descriptor_set(), plugins: [{Counter, mode: :y}, Follower])

    assert CountedSchema.schema() == schema
    assert CountedSchema.plugin_count() == {map_size(schema.messages), [mode: :y]}
  end

  test "rejects plugin entries that are not loaded plugin modules" do
    set = Fixtures.person_descriptor_set()

    for plugins <- [Counter, [:no_such_module], [Enum], [{Counter, [:not_keyword]}], ["x"]] do
      error = assert_raise PB.OptionError, fn -> PB.compile(set, plugins: plugins) end
      assert %{kind: :invalid_option, option: :plugins, operation: :compile} = error
    end
  end
end

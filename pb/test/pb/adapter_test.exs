defmodule PB.AdapterTest do
  use ExUnit.Case, async: true

  import PB.TestSupport.Assertions

  @message :"adapter_contract.Msg"

  @descriptor_set %{
    file: [
      %{
        name: "adapter_contract.proto",
        package: "adapter_contract",
        syntax: "proto3",
        message_type: [
          %{
            name: "Msg",
            field: []
          }
        ]
      }
    ]
  }

  @adapter %PB.Adapter{
    to_proto: {__MODULE__, :to_proto},
    from_proto: {__MODULE__, :from_proto}
  }

  def to_proto(value), do: {:ok, value}
  def from_proto(value), do: {:ok, value}

  defmodule BareReturn do
    def to_proto(_value), do: %{}
    def from_proto(_value), do: %{native: true}
  end

  defmodule ErrorReturn do
    def to_proto(_value), do: {:error, :bad_to_proto}
    def from_proto(_value), do: {:error, :bad_from_proto}
  end

  defmodule TupleNativeReturn do
    def to_proto(_value), do: {:ok, {:error, :native_value}}
    def from_proto(_value), do: {:ok, {:ok, :native_value}}
  end

  test "compile accepts an adapter projection" do
    schema = PB.compile(@descriptor_set, projections: [{@message, adapter: @adapter}])

    assert schema.messages[@message].projection.adapter == @adapter
    refute Map.has_key?(schema.messages[@message], :adapter)
  end

  test "compile rejects legacy adapter shapes" do
    bare_keyword = [
      to_proto: {__MODULE__, :to_proto},
      from_proto: {__MODULE__, :from_proto}
    ]

    bare_map = %{
      to_proto: {__MODULE__, :to_proto},
      from_proto: {__MODULE__, :from_proto}
    }

    for opts <- [[adapters: [@adapter]], [representation: [messages: %{}]]] do
      assert_raise PB.OptionError, ~r/unknown option/, fn ->
        PB.compile(@descriptor_set, opts)
      end
    end

    legacy_inputs = [
      {[projections: [{@message, adapter: bare_keyword}]], ~r/must be a %PB.Adapter\{\}/},
      {[projections: [{@message, adapter: bare_map}]], ~r/must be a %PB.Adapter\{\}/},
      {[projections: [{@message, [bare_map]}]], ~r/expected a keyword list/}
    ]

    for {opts, pattern} <- legacy_inputs do
      assert_raise PB.OptionError, pattern, fn ->
        PB.compile(@descriptor_set, opts)
      end
    end
  end

  test "compile rejects projection entries without a kind" do
    assert_raise PB.OptionError, ~r/must set :adapter, :struct, :unwrap or :oneofs/, fn ->
      PB.compile(@descriptor_set, projections: [{@message, []}])
    end
  end

  test "compile rejects unknown projection options" do
    assert_raise PB.OptionError, ~r/unknown option\(s\) \[:bogus\]/, fn ->
      PB.compile(@descriptor_set,
        projections: [{@message, [adapter: @adapter, bogus: true]}]
      )
    end
  end

  test "compile rejects combining :adapter with structural options" do
    assert_raise PB.OptionError, ~r/cannot combine :adapter with/, fn ->
      PB.compile(@descriptor_set,
        projections: [{@message, [adapter: @adapter, struct: __MODULE__]}]
      )
    end
  end

  test "runtime rejects bare adapter callback returns" do
    adapter = %PB.Adapter{
      to_proto: {BareReturn, :to_proto},
      from_proto: {BareReturn, :from_proto}
    }

    assert {:error, {:adapter_error, @message, :to_proto, [:root], {:invalid_return, %{}}}} =
             PB.Runtime.Codec.adapter_to_proto(adapter, @message, :native, [:root])

    assert {:error,
            {:adapter_error, @message, :from_proto, [:root], {:invalid_return, %{native: true}}}} =
             PB.Runtime.Codec.adapter_from_proto(adapter, @message, %{}, [:root])
  end

  test "public encode reports bare adapter returns as AdapterError" do
    adapter = %PB.Adapter{
      to_proto: {BareReturn, :to_proto},
      from_proto: {BareReturn, :from_proto}
    }

    schema = PB.compile(@descriptor_set, projections: [{@message, adapter: adapter}])

    assert_error(PB.encode(:native, schema, @message),
      operation: :encode,
      message_name: @message,
      path: [],
      fqn: @message,
      direction: :to_proto,
      reason: {:invalid_return, %{}}
    )
  end

  test "runtime still accepts tagged adapter success and error returns" do
    assert {:ok, %{}} = PB.Runtime.Codec.adapter_to_proto(@adapter, @message, %{})

    assert {:error, {:adapter_error, @message, :to_proto, [:root], :bad_to_proto}} =
             PB.Runtime.Codec.adapter_to_proto(
               %PB.Adapter{
                 to_proto: {ErrorReturn, :to_proto},
                 from_proto: {ErrorReturn, :from_proto}
               },
               @message,
               :native,
               [:root]
             )
  end

  test "runtime preserves tuple-shaped native values when explicitly tagged" do
    adapter = %PB.Adapter{
      to_proto: {TupleNativeReturn, :to_proto},
      from_proto: {TupleNativeReturn, :from_proto}
    }

    assert {:ok, {:error, :native_value}} =
             PB.Runtime.Codec.adapter_to_proto(adapter, @message, :native)

    assert {:ok, {:ok, :native_value}} =
             PB.Runtime.Codec.adapter_from_proto(adapter, @message, %{})
  end
end

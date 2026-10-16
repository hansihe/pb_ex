# A provider of one message type and one enum, named by strings, whose
# payloads are maps of CEL values keyed by field name.
defmodule CEL.TestSupport.StringTypes do
  @behaviour CEL.TypeProvider

  alias CEL.Value

  @fields %{
    "a" => %CEL.Field{name: "a", type: :int, ref: "a"},
    "e" => %CEL.Field{name: "e", type: {:enum, "test.E"}, ref: "e"},
    "child" => %CEL.Field{name: "child", type: {:message, "test.Msg"}, ref: "child"}
  }

  @impl true
  def find_type(_state, "test.Msg"), do: {:ok, :message, "test.Msg"}
  def find_type(_state, "test.E"), do: {:ok, :enum, "test.E"}
  def find_type(_state, _name), do: :error

  @impl true
  def find_field(_state, "test.Msg", name), do: Map.fetch(@fields, name)

  @impl true
  def enum_value(_state, "test.E", name), do: Map.fetch(%{"X" => 1, "Y" => 2}, name)

  @impl true
  def new_message(_state, "test.Msg", fields) do
    {:ok, {:message, "test.Msg", Map.new(fields, fn {field, value} -> {field.ref, value} end)}}
  end

  @impl true
  def from_native(_state, "test.Msg", native) do
    {:ok,
     {:message, "test.Msg",
      Map.new(native, fn
        {"a", a} -> {"a", Value.int(a)}
        {"e", e} -> {"e", Value.enum("test.E", e)}
        {"child", child} -> {"child", elem(from_native(nil, "test.Msg", child), 1)}
      end)}}
  end

  @impl true
  def get_field(_state, payload, field) do
    default = %{
      "a" => Value.int(0),
      "e" => Value.enum("test.E", 0),
      "child" => {:message, "test.Msg", %{}}
    }

    {:ok, Map.get(payload, field.ref, default[field.ref])}
  end

  @impl true
  def has_field?(_state, payload, field), do: Map.has_key?(payload, field.ref)

  @impl true
  def equal?(_state, "test.Msg", left, right), do: left == right
end

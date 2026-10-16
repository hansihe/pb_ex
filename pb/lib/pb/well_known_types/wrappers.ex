defmodule PB.WellKnownTypes.Wrappers do
  @moduledoc false

  alias PB.Runtime.Errors
  alias PB.Runtime.Scalar

  @float_type quote(do: number() | :nan | :infinity | :negative_infinity)

  @wrappers [
    %{
      id: :double,
      fqn: :"google.protobuf.DoubleValue",
      type: :TYPE_DOUBLE,
      codec: :double_value,
      spec: @float_type
    },
    %{
      id: :float,
      fqn: :"google.protobuf.FloatValue",
      type: :TYPE_FLOAT,
      codec: :float_value,
      spec: @float_type
    },
    %{
      id: :int64,
      fqn: :"google.protobuf.Int64Value",
      type: :TYPE_INT64,
      codec: :int64_value,
      spec: quote(do: integer())
    },
    %{
      id: :uint64,
      fqn: :"google.protobuf.UInt64Value",
      type: :TYPE_UINT64,
      codec: :uint64_value,
      spec: quote(do: non_neg_integer())
    },
    %{
      id: :int32,
      fqn: :"google.protobuf.Int32Value",
      type: :TYPE_INT32,
      codec: :int32_value,
      spec: quote(do: integer())
    },
    %{
      id: :uint32,
      fqn: :"google.protobuf.UInt32Value",
      type: :TYPE_UINT32,
      codec: :uint32_value,
      spec: quote(do: non_neg_integer())
    },
    %{
      id: :bool,
      fqn: :"google.protobuf.BoolValue",
      type: :TYPE_BOOL,
      codec: :bool_value,
      spec: quote(do: boolean())
    },
    %{
      id: :string,
      fqn: :"google.protobuf.StringValue",
      type: :TYPE_STRING,
      codec: :string_value,
      spec: quote(do: binary())
    },
    %{
      id: :bytes,
      fqn: :"google.protobuf.BytesValue",
      type: :TYPE_BYTES,
      codec: :bytes_value,
      spec: quote(do: binary())
    }
  ]

  @projections Enum.map(@wrappers, fn wrapper ->
                 {wrapper.fqn,
                  [
                    adapter: %PB.Adapter{
                      to_proto: {__MODULE__, :"to_proto_#{wrapper.id}"},
                      from_proto: {__MODULE__, :"from_proto_#{wrapper.id}"},
                      type: wrapper.spec
                    }
                  ]}
               end)

  @doc false
  @spec projections() :: [{PB.Schema.Compiled.message_name(), keyword()}]
  def projections, do: @projections

  for wrapper <- @wrappers do
    field =
      Macro.escape(%{
        type: wrapper.type
      })

    def unquote(:"to_proto_#{wrapper.id}")(value) do
      with :ok <- Scalar.validate_encode(unquote(field), value, []) do
        {:ok, %{value: value}}
      else
        {:error, reason} -> {:error, Errors.to_error(reason)}
      end
    end

    def unquote(:"from_proto_#{wrapper.id}")(message) when is_map(message) do
      case Map.fetch(message, :value) do
        {:ok, value} -> {:ok, value}
        :error -> Scalar.default_value(unquote(field), [])
      end
    end

    def unquote(:"from_proto_#{wrapper.id}")(value) do
      {:error, {:invalid_wrapper_message, value}}
    end
  end
end

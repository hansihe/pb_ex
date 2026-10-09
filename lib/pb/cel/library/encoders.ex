defmodule PB.CEL.Library.Encoders do
  @moduledoc false

  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Runtime.Encoders, as: RuntimeEncoders

  @functions [
    %Function{
      name: "encode",
      modes: [{:namespace, "base64"}],
      overloads: [
        %Overload{
          id: "base64_encode_bytes",
          args: [:bytes],
          result: :string,
          eval: {:mfa, {RuntimeEncoders, :base64_encode}}
        }
      ],
      dynamic_overloads: [
        %Overload{
          id: "base64_encode_dyn",
          args: [:any],
          result: :string,
          eval: {:mfa, {RuntimeEncoders, :base64_encode}}
        }
      ]
    },
    %Function{
      name: "decode",
      modes: [{:namespace, "base64"}],
      overloads: [
        %Overload{
          id: "base64_decode_string",
          args: [:string],
          result: :bytes,
          eval: {:mfa, {RuntimeEncoders, :base64_decode}}
        }
      ],
      dynamic_overloads: [
        %Overload{
          id: "base64_decode_dyn",
          args: [:any],
          result: :bytes,
          eval: {:mfa, {RuntimeEncoders, :base64_decode}}
        }
      ]
    }
  ]

  @spec functions() :: [Function.t()]
  def functions, do: @functions
end

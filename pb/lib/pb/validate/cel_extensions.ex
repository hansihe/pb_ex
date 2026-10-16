defmodule PB.Validate.CELExtensions do
  @moduledoc false

  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Runtime.Math, as: RuntimeMath
  alias PB.Validate.CELExtensions.Rules
  alias PB.Validate.CELExtensions.Strings

  @string_functions [
    {"isHostname", [{"is_hostname", [:string], :bool}], [{"is_hostname_dyn", [:any], :bool}],
     :is_hostname},
    {"isEmail", [{"is_email", [:string], :bool}], [{"is_email_dyn", [:any], :bool}], :is_email},
    {"isHostAndPort", [{"is_host_and_port", [:string, :bool], :bool}],
     [{"is_host_and_port_dyn", [:any, :any], :bool}], :is_host_and_port},
    {"isIp",
     [
       {"is_ip", [:string], :bool},
       {"is_ip_version", [:string, :int], :bool}
     ],
     [
       {"is_ip_dyn", [:any], :bool},
       {"is_ip_version_dyn", [:any, :any], :bool}
     ], :is_ip},
    {"isIpPrefix",
     [
       {"is_ip_prefix", [:string], :bool},
       {"is_ip_prefix_version", [:string, :int], :bool},
       {"is_ip_prefix_strict", [:string, :bool], :bool},
       {"is_ip_prefix_version_strict", [:string, :int, :bool], :bool}
     ],
     [
       {"is_ip_prefix_dyn", [:any], :bool},
       {"is_ip_prefix_version_dyn", [:any, :any], :bool},
       {"is_ip_prefix_strict_dyn", [:any, :any], :bool},
       {"is_ip_prefix_version_strict_dyn", [:any, :any, :any], :bool}
     ], :is_ip_prefix},
    {"isUri", [{"is_uri", [:string], :bool}], [{"is_uri_dyn", [:any], :bool}], :is_uri},
    {"isUriRef", [{"is_uri_ref", [:string], :bool}], [{"is_uri_ref_dyn", [:any], :bool}],
     :is_uri_ref}
  ]

  @number_functions [
    {"isNan", "is_nan", :is_nan},
    {"isInf", "is_inf", :is_inf}
  ]

  @spec functions() :: [Function.t()]
  def functions do
    [
      get_field_function(),
      unique_function()
      | string_functions() ++ number_functions()
    ]
  end

  defp string_functions do
    Enum.map(@string_functions, fn {name, overloads, dynamic_overloads, runtime} ->
      %Function{
        name: name,
        modes: [:receiver],
        overloads: Enum.map(overloads, &overload(&1, runtime)),
        dynamic_overloads: Enum.map(dynamic_overloads, &overload(&1, runtime))
      }
    end)
  end

  defp number_functions do
    Enum.map(@number_functions, fn {name, id, runtime} ->
      %Function{
        name: name,
        modes: [:receiver],
        overloads: [
          %Overload{
            id: id,
            args: [:double],
            result: :bool,
            eval: {:mfa, {RuntimeMath, runtime}}
          }
        ],
        dynamic_overloads: [
          %Overload{
            id: id <> "_dyn",
            args: [:any],
            result: :bool,
            eval: {:mfa, {RuntimeMath, runtime}}
          }
        ]
      }
    end)
  end

  defp get_field_function do
    %Function{
      name: "getField",
      modes: [:global],
      overloads: [
        %Overload{
          id: "get_field",
          args: [:message, :string],
          result: :dyn,
          eval: {:mfa, {Rules, :get_field}},
          eval_context: [:schema]
        }
      ],
      dynamic_overloads: [
        %Overload{
          id: "get_field_dyn",
          args: [:any, :any],
          result: :dyn,
          eval: {:mfa, {Rules, :get_field}},
          eval_context: [:schema]
        }
      ]
    }
  end

  defp unique_function do
    %Function{
      name: "unique",
      modes: [:receiver, :global],
      overloads: [
        %Overload{
          id: "unique_list",
          args: [:list],
          result: :bool,
          eval: {:mfa, {Rules, :unique}},
          eval_context: [:schema]
        }
      ],
      dynamic_overloads: [
        %Overload{
          id: "unique_dyn",
          args: [:any],
          result: :bool,
          eval: {:mfa, {Rules, :unique}},
          eval_context: [:schema]
        }
      ]
    }
  end

  defp overload({id, args, result}, runtime) do
    %Overload{
      id: id,
      args: args,
      result: result,
      eval: {Strings, runtime}
    }
  end
end

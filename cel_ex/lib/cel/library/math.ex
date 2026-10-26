defmodule CEL.Library.Math do
  @moduledoc false

  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Runtime.Math, as: RuntimeMath

  import Function, only: [arg: 1]
  import CEL.Checker.TypePattern, only: [list: 1, one_of: 1, repeat: 2]

  @numeric_types [:int, :uint, :double]
  @integral_types [:int, :uint]
  @numeric_or_dyn one_of([:numeric, :dynamic])
  @integral_or_dyn one_of([:integral, :dynamic])
  @int_or_dyn one_of([:int, :dynamic])

  @extrema_functions (for {name, runtime} <- [{"greatest", :greatest}, {"least", :least}] do
                        id = "math_" <> name

                        %Function{
                          name: name,
                          modes: [{:namespace, "math"}],
                          dynamic_overloads: [
                            %Overload{
                              id: id,
                              args: [repeat(@numeric_or_dyn, min: 1)],
                              result: :dyn,
                              eval: {:mfa, {RuntimeMath, runtime}}
                            },
                            %Overload{
                              id: id,
                              args: [list(@numeric_or_dyn)],
                              result: :dyn,
                              eval: {:mfa, {RuntimeMath, runtime}}
                            }
                          ],
                          overloads:
                            for type <- @numeric_types do
                              %Overload{
                                id: id,
                                args: [repeat(type, min: 1)],
                                result: type,
                                eval: {:mfa, {RuntimeMath, runtime}}
                              }
                            end ++
                              [
                                %Overload{
                                  id: id,
                                  args: [repeat(:numeric, min: 1)],
                                  result: :dyn,
                                  eval: {:mfa, {RuntimeMath, runtime}}
                                }
                              ] ++
                              for type <- @numeric_types do
                                %Overload{
                                  id: id,
                                  args: [list(type)],
                                  result: type,
                                  eval: {:mfa, {RuntimeMath, runtime}}
                                }
                              end ++
                              [
                                %Overload{
                                  id: id,
                                  args: [list(:numeric)],
                                  result: :dyn,
                                  eval: {:mfa, {RuntimeMath, runtime}}
                                }
                              ]
                        }
                      end)

  @binary_bit_functions (for {name, runtime} <- [
                               {"bitAnd", :bit_and},
                               {"bitOr", :bit_or},
                               {"bitXor", :bit_xor}
                             ] do
                           id = "math_" <> Macro.underscore(name)

                           %Function{
                             name: name,
                             modes: [{:namespace, "math"}],
                             dynamic_overloads: [
                               %Overload{
                                 id: id,
                                 args: [@integral_or_dyn, @integral_or_dyn],
                                 result: :dyn,
                                 eval: {:mfa, {RuntimeMath, runtime}}
                               }
                             ],
                             overloads:
                               for type <- @integral_types do
                                 %Overload{
                                   id: id,
                                   args: [type, type],
                                   result: type,
                                   eval: {:mfa, {RuntimeMath, runtime}}
                                 }
                               end
                           }
                         end)

  @shift_functions (for {name, runtime} <- [
                          {"bitShiftLeft", :bit_shift_left},
                          {"bitShiftRight", :bit_shift_right}
                        ] do
                      id = "math_" <> Macro.underscore(name)

                      %Function{
                        name: name,
                        modes: [{:namespace, "math"}],
                        dynamic_overloads: [
                          %Overload{
                            id: id,
                            args: [@integral_or_dyn, @int_or_dyn],
                            result: :dyn,
                            eval: {:mfa, {RuntimeMath, runtime}}
                          }
                        ],
                        overloads:
                          for type <- @integral_types do
                            %Overload{
                              id: id,
                              args: [type, :int],
                              result: type,
                              eval: {:mfa, {RuntimeMath, runtime}}
                            }
                          end
                      }
                    end)

  @functions [
               %Function{
                 name: "isNaN",
                 modes: [{:namespace, "math"}],
                 dynamic_overloads: [
                   %Overload{
                     id: "math_is_nan",
                     args: [:dyn],
                     result: :bool,
                     eval: {:mfa, {RuntimeMath, :is_nan}}
                   }
                 ],
                 overloads: [
                   %Overload{
                     id: "math_is_nan",
                     args: [:double],
                     result: :bool,
                     eval: {:mfa, {RuntimeMath, :is_nan}}
                   }
                 ]
               },
               %Function{
                 name: "isInf",
                 modes: [{:namespace, "math"}],
                 dynamic_overloads: [
                   %Overload{
                     id: "math_is_inf",
                     args: [:dyn],
                     result: :bool,
                     eval: {:mfa, {RuntimeMath, :is_inf}}
                   }
                 ],
                 overloads: [
                   %Overload{
                     id: "math_is_inf",
                     args: [:double],
                     result: :bool,
                     eval: {:mfa, {RuntimeMath, :is_inf}}
                   }
                 ]
               },
               %Function{
                 name: "isFinite",
                 modes: [{:namespace, "math"}],
                 dynamic_overloads: [
                   %Overload{
                     id: "math_is_finite",
                     args: [:dyn],
                     result: :bool,
                     eval: {:mfa, {RuntimeMath, :is_finite}}
                   }
                 ],
                 overloads: [
                   %Overload{
                     id: "math_is_finite",
                     args: [:double],
                     result: :bool,
                     eval: {:mfa, {RuntimeMath, :is_finite}}
                   }
                 ]
               }
             ] ++
               @extrema_functions ++
               [
                 %Function{
                   name: "ceil",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_ceil",
                       args: [:dyn],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :ceil}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_ceil",
                       args: [:double],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :ceil}}
                     }
                   ]
                 },
                 %Function{
                   name: "floor",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_floor",
                       args: [:dyn],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :floor}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_floor",
                       args: [:double],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :floor}}
                     }
                   ]
                 },
                 %Function{
                   name: "round",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_round",
                       args: [:dyn],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :round}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_round",
                       args: [:double],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :round}}
                     }
                   ]
                 },
                 %Function{
                   name: "trunc",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_trunc",
                       args: [:dyn],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :trunc}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_trunc",
                       args: [:double],
                       result: :double,
                       eval: {:mfa, {RuntimeMath, :trunc}}
                     }
                   ]
                 },
                 %Function{
                   name: "abs",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_abs",
                       args: [:dynamic],
                       result: arg(0),
                       eval: {:mfa, {RuntimeMath, :abs}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_abs",
                       args: [:numeric],
                       result: arg(0),
                       eval: {:mfa, {RuntimeMath, :abs}}
                     }
                   ]
                 },
                 %Function{
                   name: "sign",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_sign",
                       args: [:dynamic],
                       result: arg(0),
                       eval: {:mfa, {RuntimeMath, :sign}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_sign",
                       args: [:numeric],
                       result: arg(0),
                       eval: {:mfa, {RuntimeMath, :sign}}
                     }
                   ]
                 }
               ] ++
               @binary_bit_functions ++
               [
                 %Function{
                   name: "bitNot",
                   modes: [{:namespace, "math"}],
                   dynamic_overloads: [
                     %Overload{
                       id: "math_bit_not",
                       args: [:dyn],
                       result: :dyn,
                       eval: {:mfa, {RuntimeMath, :bit_not}}
                     }
                   ],
                   overloads: [
                     %Overload{
                       id: "math_bit_not",
                       args: [:int],
                       result: :int,
                       eval: {:mfa, {RuntimeMath, :bit_not}}
                     },
                     %Overload{
                       id: "math_bit_not",
                       args: [:uint],
                       result: :uint,
                       eval: {:mfa, {RuntimeMath, :bit_not}}
                     }
                   ]
                 }
               ] ++
               @shift_functions

  @spec functions() :: [Function.t()]
  def functions, do: @functions
end

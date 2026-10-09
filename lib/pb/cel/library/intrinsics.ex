defmodule PB.CEL.Library.Intrinsics do
  @moduledoc false

  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Runtime.Core, as: RuntimeCore
  alias PB.CEL.Runtime.Optional, as: RuntimeOptional

  import PB.CEL.Checker.TypePattern, only: [list: 1, map: 2, optional: 1, param: 1]

  @a param(:a)
  @k param(:k)
  @v param(:v)

  @matcher_suffixes %{
    bool: "bool",
    int: "int64",
    uint: "uint64",
    double: "double",
    string: "string",
    bytes: "bytes",
    timestamp: "timestamp",
    duration: "duration"
  }

  @numeric_types [:int, :uint, :double]
  @add_types [:int, :uint, :double, :string, :bytes]
  @ordered_types [:bool, :int, :uint, :double, :string, :bytes, :timestamp, :duration]

  @equality_functions (for {name, id, runtime} <- [
                             {"_==_", "_equals_", :equals},
                             {"_!=_", "_not_equals_", :not_equals}
                           ] do
                         %Function{
                           name: name,
                           modes: [:intrinsic],
                           dynamic_overloads: [
                             %Overload{
                               id: id <> "_dyn",
                               args: [:dyn, :any],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime]
                             },
                             %Overload{
                               id: id <> "_dyn",
                               args: [:any, :dyn],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime]
                             }
                           ],
                           overloads: [
                             %Overload{
                               id: id,
                               args: [:null, :any],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime]
                             },
                             %Overload{
                               id: id,
                               args: [:any, :null],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime]
                             },
                             %Overload{
                               id: id,
                               args: [{:type, :any}, {:type, :any}],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime]
                             },
                             %Overload{
                               id: id,
                               args: [optional(:any), optional(:any)],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime]
                             },
                             %Overload{
                               id: id,
                               args: [@a, @a],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}},
                               eval_context: [:schema, :message_runtime],
                               on_dyn: :fallback
                             }
                           ]
                         }
                       end)

  @relation_functions (for {name, prefix, runtime} <- [
                             {"_<_", "less", :less},
                             {"_<=_", "less_equals", :less_equals},
                             {"_>_", "greater", :greater},
                             {"_>=_", "greater_equals", :greater_equals}
                           ] do
                         %Function{
                           name: name,
                           modes: [:intrinsic],
                           dynamic_overloads: [
                             %Overload{
                               id: name <> "_dyn",
                               args: [:dyn, :any],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}}
                             },
                             %Overload{
                               id: name <> "_dyn",
                               args: [:any, :dyn],
                               result: :bool,
                               eval: {:mfa, {RuntimeCore, runtime}}
                             }
                           ],
                           overloads:
                             for type <- @ordered_types do
                               %Overload{
                                 id: prefix <> "_" <> Map.fetch!(@matcher_suffixes, type),
                                 args: [type, type],
                                 result: :bool,
                                 eval: {:mfa, {RuntimeCore, runtime}}
                               }
                             end
                         }
                       end)

  @base_functions [
    %Function{
      name: "!_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "logical_not",
          args: [:dyn],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :logical_not}}
        }
      ],
      overloads: [
        %Overload{
          id: "logical_not",
          args: [:bool],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :logical_not}}
        }
      ]
    },
    %Function{
      name: "@not_strictly_false",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "not_strictly_false",
          args: [:dyn],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :not_strictly_false}},
          strict: false
        }
      ],
      overloads: [
        %Overload{
          id: "not_strictly_false",
          args: [:bool],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :not_strictly_false}},
          strict: false
        }
      ]
    },
    %Function{
      name: "_&&_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{id: "logical_and", args: [:bool, :dyn], result: :bool, eval: :intrinsic},
        %Overload{id: "logical_and", args: [:dyn, :bool], result: :bool, eval: :intrinsic},
        %Overload{id: "logical_and", args: [:dyn, :dyn], result: :bool, eval: :intrinsic}
      ],
      overloads: [
        %Overload{id: "logical_and", args: [:bool, :bool], result: :bool, eval: :intrinsic}
      ]
    },
    %Function{
      name: "_||_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{id: "logical_or", args: [:bool, :dyn], result: :bool, eval: :intrinsic},
        %Overload{id: "logical_or", args: [:dyn, :bool], result: :bool, eval: :intrinsic},
        %Overload{id: "logical_or", args: [:dyn, :dyn], result: :bool, eval: :intrinsic}
      ],
      overloads: [
        %Overload{id: "logical_or", args: [:bool, :bool], result: :bool, eval: :intrinsic}
      ]
    },
    %Function{
      name: "_[_]",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_[_]_dyn",
          args: [:dyn, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :index}}
        },
        %Overload{
          id: "_[_]_dyn",
          args: [:any, :dyn],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :index}}
        },
        %Overload{
          id: "optional_index_dyn",
          args: [optional(:dyn), :any],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_index}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_index",
          args: [optional(:null), :any],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_index}}
        },
        %Overload{
          id: "index",
          args: [list(@a), :int],
          result: @a,
          eval: {:mfa, {RuntimeCore, :index}},
          on_dyn: :fallback
        },
        %Overload{
          id: "index",
          args: [map(@k, @v), @k],
          result: @v,
          eval: {:mfa, {RuntimeCore, :index}},
          on_dyn: :fallback
        },
        %Overload{
          id: "optional_index",
          args: [optional(list(@a)), :int],
          result: optional(@a),
          eval: {:mfa, {RuntimeCore, :optional_index}},
          on_dyn: :fallback
        },
        %Overload{
          id: "optional_index",
          args: [optional(map(@k, @v)), @k],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_index}},
          on_dyn: :fallback
        }
      ]
    },
    %Function{
      name: "_[?_]",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_[?_]_dyn",
          args: [:dyn, :any],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_index}}
        },
        %Overload{
          id: "_[?_]_dyn",
          args: [:any, :dyn],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_index}}
        },
        %Overload{
          id: "optional_index_dyn",
          args: [optional(:dyn), :any],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_index}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_index",
          args: [optional(:null), :any],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_index}}
        },
        %Overload{
          id: "optional_index",
          args: [list(@a), :int],
          result: optional(@a),
          eval: {:mfa, {RuntimeCore, :optional_index}},
          on_dyn: :fallback
        },
        %Overload{
          id: "optional_index",
          args: [map(@k, @v), @k],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_index}},
          on_dyn: :fallback
        },
        %Overload{
          id: "optional_index",
          args: [optional(list(@a)), :int],
          result: optional(@a),
          eval: {:mfa, {RuntimeCore, :optional_index}},
          on_dyn: :fallback
        },
        %Overload{
          id: "optional_index",
          args: [optional(map(@k, @v)), @k],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_index}},
          on_dyn: :fallback
        }
      ]
    },
    %Function{
      name: "_?._",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "optional_select",
          args: [:dyn, :string],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [optional(:dyn), :string],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [map(:dyn, @v), :string],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [optional(map(:dyn, @v)), :string],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_select",
          args: [:null, :string],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [:message, :string],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [map(:string, @v), :string],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [optional(:null), :string],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [optional(:message), :string],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        },
        %Overload{
          id: "optional_select",
          args: [optional(map(:string, @v)), :string],
          result: optional(@v),
          eval: {:mfa, {RuntimeCore, :optional_select}}
        }
      ]
    },
    %Function{
      name: "@in",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "@in_dyn",
          args: [:dyn, :any],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :contains}}
        },
        %Overload{
          id: "@in_dyn",
          args: [:any, :dyn],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :contains}}
        }
      ],
      overloads: [
        %Overload{
          id: "in_list",
          args: [@a, list(@a)],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :contains}},
          on_dyn: :fallback
        },
        %Overload{
          id: "in_map",
          args: [@k, map(@k, @v)],
          result: :bool,
          eval: {:mfa, {RuntimeCore, :contains}},
          on_dyn: :fallback
        }
      ]
    },
    %Function{
      name: "_+_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_+__dyn",
          args: [:any, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :add}}
        }
      ],
      overloads:
        for type <- @add_types do
          %Overload{
            id: "add_" <> Map.fetch!(@matcher_suffixes, type),
            args: [type, type],
            result: type,
            eval: {:mfa, {RuntimeCore, :add}}
          }
        end ++
          [
            %Overload{
              id: "add_timestamp_duration",
              args: [:timestamp, :duration],
              result: :timestamp,
              eval: {:mfa, {RuntimeCore, :add}}
            },
            %Overload{
              id: "add_duration_timestamp",
              args: [:duration, :timestamp],
              result: :timestamp,
              eval: {:mfa, {RuntimeCore, :add}}
            },
            %Overload{
              id: "add_duration_duration",
              args: [:duration, :duration],
              result: :duration,
              eval: {:mfa, {RuntimeCore, :add}}
            },
            %Overload{
              id: "add_list",
              args: [list(@a), list(@a)],
              result: list(@a),
              eval: {:mfa, {RuntimeCore, :add}},
              combine: :common,
              on_dyn: :fallback
            },
            %Overload{
              id: "add_map",
              args: [map(@k, @v), map(@k, @v)],
              result: map(@k, @v),
              eval: {:mfa, {RuntimeCore, :add}},
              combine: :common,
              on_dyn: :fallback
            }
          ]
    },
    %Function{
      name: "-_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_negate__dyn",
          args: [:dyn],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :negate}}
        }
      ],
      overloads: [
        %Overload{
          id: "negate_int64",
          args: [:int],
          result: :int,
          eval: {:mfa, {RuntimeCore, :negate}}
        },
        %Overload{
          id: "negate_double",
          args: [:double],
          result: :double,
          eval: {:mfa, {RuntimeCore, :negate}}
        }
      ]
    },
    %Function{
      name: "_-_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_-__dyn",
          args: [:any, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :subtract}}
        }
      ],
      overloads:
        for type <- @numeric_types do
          %Overload{
            id: "subtract_" <> Map.fetch!(@matcher_suffixes, type),
            args: [type, type],
            result: type,
            eval: {:mfa, {RuntimeCore, :subtract}}
          }
        end ++
          [
            %Overload{
              id: "subtract_timestamp_timestamp",
              args: [:timestamp, :timestamp],
              result: :duration,
              eval: {:mfa, {RuntimeCore, :subtract}}
            },
            %Overload{
              id: "subtract_timestamp_duration",
              args: [:timestamp, :duration],
              result: :timestamp,
              eval: {:mfa, {RuntimeCore, :subtract}}
            },
            %Overload{
              id: "subtract_duration_duration",
              args: [:duration, :duration],
              result: :duration,
              eval: {:mfa, {RuntimeCore, :subtract}}
            }
          ]
    },
    %Function{
      name: "_*_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_*__dyn",
          args: [:any, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :multiply}}
        }
      ],
      overloads:
        for type <- @numeric_types do
          %Overload{
            id: "multiply_" <> Map.fetch!(@matcher_suffixes, type),
            args: [type, type],
            result: type,
            eval: {:mfa, {RuntimeCore, :multiply}}
          }
        end
    },
    %Function{
      name: "_/_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_/__dyn",
          args: [:any, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :divide}}
        }
      ],
      overloads:
        for type <- @numeric_types do
          %Overload{
            id: "divide_" <> Map.fetch!(@matcher_suffixes, type),
            args: [type, type],
            result: type,
            eval: {:mfa, {RuntimeCore, :divide}}
          }
        end
    },
    %Function{
      name: "_%_",
      modes: [:intrinsic],
      dynamic_overloads: [
        %Overload{
          id: "_%__dyn",
          args: [:any, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeCore, :modulo}}
        }
      ],
      overloads:
        for type <- [:int, :uint] do
          %Overload{
            id: "modulo_" <> Map.fetch!(@matcher_suffixes, type),
            args: [type, type],
            result: type,
            eval: {:mfa, {RuntimeCore, :modulo}}
          }
        end
    },
    %Function{
      name: "_?_:_",
      modes: [:intrinsic],
      overloads: [
        %Overload{
          id: "conditional",
          args: [:bool, @a, @a],
          result: @a,
          eval: :intrinsic,
          combine: :common
        }
      ]
    },
    %Function{
      name: "none",
      modes: [{:namespace, "optional"}],
      overloads: [
        %Overload{
          id: "optional_none",
          args: [],
          result: optional(@a),
          eval: {:mfa, {RuntimeOptional, :none}}
        }
      ]
    },
    %Function{
      name: "of",
      modes: [{:namespace, "optional"}],
      overloads: [
        %Overload{
          id: "optional_of",
          args: [@a],
          result: optional(@a),
          eval: {:mfa, {RuntimeOptional, :of}}
        }
      ]
    },
    %Function{
      name: "ofNonZeroValue",
      modes: [{:namespace, "optional"}],
      overloads: [
        %Overload{
          id: "optional_of_non_zero_value",
          args: [@a],
          result: optional(@a),
          eval: {:mfa, {RuntimeOptional, :of_non_zero_value}}
        }
      ]
    },
    %Function{
      name: "unwrap",
      modes: [{:namespace, "optional"}],
      dynamic_overloads: [
        %Overload{
          id: "optional_unwrap",
          args: [:dyn],
          result: :dyn,
          eval: {:mfa, {RuntimeOptional, :unwrap}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_unwrap",
          args: [optional(@a)],
          result: @a,
          eval: {:mfa, {RuntimeOptional, :unwrap}}
        }
      ]
    },
    %Function{
      name: "hasValue",
      modes: [:receiver],
      dynamic_overloads: [
        %Overload{
          id: "optional_has_value",
          args: [:dyn],
          result: :bool,
          eval: {:mfa, {RuntimeOptional, :has_value}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_has_value",
          args: [optional(@a)],
          result: :bool,
          eval: {:mfa, {RuntimeOptional, :has_value}}
        }
      ]
    },
    %Function{
      name: "value",
      modes: [:receiver],
      dynamic_overloads: [
        %Overload{
          id: "optional_value",
          args: [:dyn],
          result: :dyn,
          eval: {:mfa, {RuntimeOptional, :value}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_value",
          args: [optional(@a)],
          result: @a,
          eval: {:mfa, {RuntimeOptional, :value}}
        }
      ]
    },
    %Function{
      name: "or",
      modes: [:receiver],
      dynamic_overloads: [
        %Overload{
          id: "optional_or",
          args: [:dyn, optional(@a)],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeOptional, :or}}
        },
        %Overload{
          id: "optional_or",
          args: [optional(@a), :dyn],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeOptional, :or}}
        },
        %Overload{
          id: "optional_or",
          args: [:dyn, :dyn],
          result: optional(:dyn),
          eval: {:mfa, {RuntimeOptional, :or}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_or",
          args: [optional(@a), optional(@a)],
          result: optional(@a),
          eval: {:mfa, {RuntimeOptional, :or}},
          combine: :common
        }
      ]
    },
    %Function{
      name: "orValue",
      modes: [:receiver],
      dynamic_overloads: [
        %Overload{
          id: "optional_or_value",
          args: [:dyn, :any],
          result: :dyn,
          eval: {:mfa, {RuntimeOptional, :or_value}}
        }
      ],
      overloads: [
        %Overload{
          id: "optional_or_value",
          args: [optional(@a), @a],
          result: @a,
          eval: {:mfa, {RuntimeOptional, :or_value}},
          combine: :common
        }
      ]
    }
  ]

  @functions @base_functions ++ @equality_functions ++ @relation_functions

  @spec functions() :: [Function.t()]
  def functions, do: @functions
end

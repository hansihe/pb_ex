defmodule PB.TestSupport.Fixtures do
  @moduledoc false

  def person_descriptor_set do
    %{
      file: [
        %{
          name: "test.proto",
          package: :test,
          syntax: :proto3,
          message_type: [
            %{
              name: :Person,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{name: :id, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                %{
                  name: :phones,
                  number: 4,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"test.PhoneNumber"
                },
                %{
                  name: :role,
                  number: 5,
                  type: :TYPE_ENUM,
                  label: :LABEL_OPTIONAL,
                  type_name: :"test.Role"
                },
                %{
                  name: :scores,
                  number: 6,
                  type: :TYPE_INT32,
                  label: :LABEL_REPEATED
                },
                %{
                  name: :pet,
                  number: 7,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"test.Pet",
                  oneof_index: 0
                },
                %{
                  name: :fish,
                  number: 8,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"test.Fish",
                  oneof_index: 0
                },
                %{
                  name: :tags,
                  number: 9,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"test.Person.TagsEntry"
                }
              ],
              oneof_decl: [%{name: :companion}],
              nested_type: [
                %{
                  name: :TagsEntry,
                  options: %{map_entry: true},
                  field: [
                    %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                    %{name: :value, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                  ]
                }
              ],
              enum_type: []
            },
            %{
              name: :PhoneNumber,
              field: [
                %{name: :number, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            },
            %{
              name: :Pet,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            },
            %{
              name: :Fish,
              field: [
                %{name: :species, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: [
            %{
              name: :Role,
              value: [
                %{name: :UNKNOWN, number: 0},
                %{name: :ADMIN, number: 1},
                %{name: :USER, number: 2}
              ]
            }
          ]
        }
      ]
    }
  end

  def binding_descriptor_set do
    %{
      file: [
        %{
          name: "binding.proto",
          package: :bind,
          syntax: :proto3,
          message_type: [
            %{
              name: :Event,
              field: [
                %{name: :title, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{
                  name: :note,
                  number: 2,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"bind.Note"
                },
                %{
                  name: :notes,
                  number: 3,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"bind.Note"
                },
                %{
                  name: :labels,
                  number: 4,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_REPEATED,
                  type_name: :"bind.Event.LabelsEntry"
                },
                %{
                  name: :role,
                  number: 5,
                  type: :TYPE_ENUM,
                  label: :LABEL_OPTIONAL,
                  type_name: :"bind.Role"
                }
              ],
              nested_type: [
                %{
                  name: :LabelsEntry,
                  options: %{map_entry: true},
                  field: [
                    %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                    %{
                      name: :value,
                      number: 2,
                      type: :TYPE_MESSAGE,
                      label: :LABEL_OPTIONAL,
                      type_name: :"bind.Note"
                    }
                  ]
                }
              ]
            },
            %{
              name: :Note,
              field: [
                %{name: :text, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            },
            %{
              name: :Other,
              field: [
                %{name: :id, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: [
            %{
              name: :Role,
              value: [
                %{name: :UNKNOWN, number: 0},
                %{name: :ADMIN, number: 1}
              ]
            }
          ]
        }
      ]
    }
  end

  def grpc_schema_fixture do
    descriptor_set = %{
      file: [
        %{
          name: "greeter.proto",
          package: "grpct",
          syntax: "proto3",
          message_type: [
            %{name: "HelloRequest", field: [%{name: "name", number: 1, type: :TYPE_STRING}]},
            %{name: "HelloReply", field: [%{name: "message", number: 1, type: :TYPE_STRING}]}
          ],
          service: [
            %{
              name: "Greeter",
              method: [
                %{
                  name: "SayHello",
                  input_type: ".grpct.HelloRequest",
                  output_type: ".grpct.HelloReply"
                }
              ]
            }
          ]
        }
      ]
    }

    %{schema: PB.compile(descriptor_set)}
  end
end

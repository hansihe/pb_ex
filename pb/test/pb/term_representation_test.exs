defmodule PB.TermRepresentationTest do
  use ExUnit.Case

  import PB.TestSupport.Assertions

  alias PB.TestSupport.Fixtures

  defmodule PersonTerm do
    defstruct name: nil,
              id: nil,
              phones: [],
              role: nil,
              scores: [],
              companion: nil,
              tags: %{}
  end

  defmodule PhoneTerm do
    defstruct number: nil
  end

  defmodule PetTerm do
    defstruct name: nil
  end

  defmodule FishTerm do
    defstruct species: nil
  end

  defmodule SkipDropTerm do
    defstruct name: nil
  end

  defmodule SkipKeepTerm do
    defstruct name: nil, _unknown_fields: []
  end

  defmodule ExtBaseTerm do
    defstruct name: nil
  end

  defmodule OptionPersonTerm do
    defstruct name: nil, companion: nil
  end

  defmodule OptionPetTerm do
    defstruct name: nil
  end

  describe "T9b - term representation" do
    setup do
      schema =
        PB.compile(Fixtures.person_descriptor_set(),
          projections: [
            {:"test.Person",
             struct: PersonTerm, oneofs: [companion: [representation: :identity]]},
            {:"test.PhoneNumber", struct: PhoneTerm},
            {:"test.Pet", struct: PetTerm},
            {:"test.Fish", struct: FishTerm}
          ]
        )

      %{schema: schema}
    end

    test "struct messages decode and encode in the existing runtime passes", %{schema: schema} do
      person = %PersonTerm{
        name: "Alice",
        id: 123,
        phones: [%PhoneTerm{number: "555"}],
        companion: %PetTerm{name: "Rex"},
        tags: %{"age" => 42}
      }

      {:ok, encoded} = PB.encode(person, schema, :"test.Person")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(encoded), schema, :"test.Person")

      assert decoded == person
    end

    test "ProtoJSON decode matches wire decode for struct + identity-oneof projections", %{
      schema: schema
    } do
      person = %PersonTerm{
        name: "Alice",
        id: 123,
        phones: [%PhoneTerm{number: "555"}],
        companion: %PetTerm{name: "Rex"},
        tags: %{"age" => 42}
      }

      {:ok, wire} = PB.encode(person, schema, :"test.Person")
      {:ok, via_wire} = PB.decode(IO.iodata_to_binary(wire), schema, :"test.Person")

      {:ok, json} = PB.JSON.to_term(person, schema, :"test.Person")
      {:ok, via_json} = PB.JSON.from_term(json, schema, :"test.Person")

      # Representation is a property of the schema, not the call: JSON must yield
      # the same native term as the wire codec — including the identity-oneof's
      # bare-struct form (`companion: %PetTerm{}`, not `{:pet, %PetTerm{}}`).
      assert via_json == via_wire
      assert via_json == person
    end

    test "schema consumers read represented structs through a proto field view", %{
      schema: schema
    } do
      person = %PersonTerm{
        name: "Alice",
        companion: %PetTerm{name: "Rex"}
      }

      assert PB.message_equal?(person, person, schema, :"test.Person")
    end

    test "identity oneofs reject values that do not identify a member", %{schema: schema} do
      assert_error(PB.encode(%PersonTerm{companion: "Rex"}, schema, :"test.Person"),
        operation: :encode,
        kind: :invalid_oneof,
        message_name: :"test.Person",
        path: [:companion],
        reason: :expected_member_struct
      )
    end

    test "single-field unwrap messages decode and encode as their field value" do
      schema =
        PB.compile(Fixtures.person_descriptor_set(),
          projections: [
            {:"test.PhoneNumber", unwrap: :number}
          ]
        )

      {:ok, encoded} = PB.encode("555", schema, :"test.PhoneNumber")

      assert {:ok, "555"} =
               PB.decode(IO.iodata_to_binary(encoded), schema, :"test.PhoneNumber")

      assert {:ok, nil} = PB.decode(<<>>, schema, :"test.PhoneNumber")
    end

    test "ProtoJSON matches wire decode for unwrap projections" do
      schema =
        PB.compile(Fixtures.person_descriptor_set(),
          projections: [{:"test.PhoneNumber", unwrap: :number}]
        )

      {:ok, json} = PB.JSON.to_term("555", schema, :"test.PhoneNumber")
      assert {:ok, "555"} = PB.JSON.from_term(json, schema, :"test.PhoneNumber")
    end

    test "struct representation drops unknown wire fields by default" do
      full = PB.compile(skip_full_descriptor())

      partial =
        PB.compile(skip_partial_descriptor(),
          projections: [{:"skip.Msg", struct: SkipDropTerm}]
        )

      {:ok, encoded} = PB.encode(%{name: "test", id: 42}, full, :"skip.Msg")

      assert {:ok, %SkipDropTerm{name: "test"}} =
               PB.decode(IO.iodata_to_binary(encoded), partial, :"skip.Msg")
    end

    test "struct representation can store unknown wire fields explicitly" do
      full = PB.compile(skip_full_descriptor())

      partial =
        PB.compile(skip_partial_descriptor(),
          projections: [
            {:"skip.Msg",
             struct: SkipKeepTerm, preserved_unknown_fields: {:field, :_unknown_fields}}
          ]
        )

      {:ok, encoded} = PB.encode(%{name: "test", id: 42}, full, :"skip.Msg")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(encoded), partial, :"skip.Msg")

      assert %SkipKeepTerm{
               name: "test",
               _unknown_fields: [
                 %PB.UnknownField{number: 2, wire_type: 0, raw: <<16, 42>>}
               ]
             } = decoded

      {:ok, reencoded} = PB.encode(decoded, partial, :"skip.Msg")
      assert IO.iodata_to_binary(reencoded) == IO.iodata_to_binary(encoded)
    end

    test "struct representation can reject unknown wire fields" do
      full = PB.compile(skip_full_descriptor())

      partial =
        PB.compile(skip_partial_descriptor(),
          projections: [{:"skip.Msg", struct: SkipDropTerm, preserved_unknown_fields: :reject}]
        )

      {:ok, encoded} = PB.encode(%{name: "test", id: 42}, full, :"skip.Msg")

      assert_error(PB.decode(IO.iodata_to_binary(encoded), partial, :"skip.Msg"),
        operation: :decode,
        kind: :unknown_wire_fields,
        message_name: :"skip.Msg",
        path: []
      )
    end

    test "struct representation rejects known extensions unless they have storage" do
      assert_raise PB.SchemaError, ~r/needs extensions: \{:field, name\}/, fn ->
        PB.compile(extension_descriptor(),
          projections: [{:"extrep.Msg", struct: ExtBaseTerm}]
        )
      end
    end

    test "message and oneof representation can come from descriptor options" do
      schema = PB.compile(representation_option_descriptor())

      person = %OptionPersonTerm{
        name: "Alice",
        companion: %OptionPetTerm{name: "Rex"}
      }

      {:ok, encoded} = PB.encode(person, schema, :"option_rep.Person")

      assert PB.decode(IO.iodata_to_binary(encoded), schema, :"option_rep.Person") ==
               {:ok, person}
    end

    test "compile-time representation overrides conflict with proto options" do
      assert_raise PB.SchemaError, ~r/conflicting projections/, fn ->
        PB.compile(representation_option_descriptor(),
          projections: [{:"option_rep.Person", struct: PersonTerm}]
        )
      end
    end

    test "proto-source representation option without :struct or :unwrap is rejected" do
      assert_raise PB.SchemaError, ~r/for :"aux_only.Msg": must set :struct or :unwrap/, fn ->
        PB.compile(aux_only_representation_option_descriptor())
      end
    end

    @tag :protoc
    test "Elixir representation proto options compile from protoc descriptors" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "pb-representation-options-#{System.unique_integer()}")

      File.mkdir_p!(tmp_dir)

      try do
        proto_path = Path.join(tmp_dir, "option_rep.proto")
        out_path = Path.join(tmp_dir, "option_rep.binpb")

        File.write!(proto_path, representation_option_proto())

        {output, status} =
          System.cmd(
            "protoc",
            [
              "-I",
              "proto",
              "-I",
              tmp_dir,
              "--include_imports",
              "--descriptor_set_out=#{out_path}",
              proto_path
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        schema =
          out_path
          |> File.read!()
          |> PB.decode_descriptor_set!()
          |> PB.compile()

        person = %OptionPersonTerm{
          name: "Alice",
          companion: %OptionPetTerm{name: "Rex"}
        }

        {:ok, encoded} = PB.encode(person, schema, :"option_rep.Person")

        assert PB.decode(IO.iodata_to_binary(encoded), schema, :"option_rep.Person") ==
                 {:ok, person}
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  defp skip_full_descriptor do
    %{
      file: [
        %{
          name: "skip.proto",
          package: :skip,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{name: :id, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }
  end

  defp skip_partial_descriptor do
    %{
      file: [
        %{
          name: "skip.proto",
          package: :skip,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }
  end

  defp extension_descriptor do
    %{
      file: [
        %{
          name: "extrep.proto",
          package: :extrep,
          syntax: :proto2,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ],
              extension_range: [%{start: 100, end: 200}]
            }
          ],
          extension: [
            %{
              name: :extra,
              number: 100,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
              extendee: ".extrep.Msg"
            }
          ]
        }
      ]
    }
  end

  defp representation_option_descriptor do
    extensions = :__extensions__

    %{
      file: [
        %{
          name: "option_rep.proto",
          package: :option_rep,
          syntax: :proto3,
          message_type: [
            %{
              name: :Person,
              options: %{
                extensions => %{
                  :"elixir.pb.v1.message" => %{
                    struct: "PB.TermRepresentationTest.OptionPersonTerm"
                  }
                }
              },
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{
                  name: :pet,
                  number: 2,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"option_rep.Pet",
                  oneof_index: 0
                }
              ],
              oneof_decl: [
                %{
                  name: :companion,
                  options: %{
                    extensions => %{
                      :"elixir.pb.v1.oneof" => %{representation: :IDENTITY}
                    }
                  }
                }
              ]
            },
            %{
              name: :Pet,
              options: %{
                extensions => %{
                  :"elixir.pb.v1.message" => %{
                    struct: "PB.TermRepresentationTest.OptionPetTerm"
                  }
                }
              },
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }
  end

  defp aux_only_representation_option_descriptor do
    extensions = :__extensions__

    %{
      file: [
        %{
          name: "aux_only.proto",
          package: :aux_only,
          syntax: :proto3,
          message_type: [
            %{
              name: :Msg,
              options: %{
                extensions => %{
                  :"elixir.pb.v1.message" => %{
                    preserved_unknown_fields: %{policy: {:drop, true}}
                  }
                }
              },
              field: [
                %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            }
          ]
        }
      ]
    }
  end

  defp representation_option_proto do
    """
    syntax = "proto3";

    package option_rep;

    import "elixir/pb/v1/options.proto";

    message Person {
      option (elixir.pb.v1.message).struct = "PB.TermRepresentationTest.OptionPersonTerm";

      string name = 1;

      oneof companion {
        option (elixir.pb.v1.oneof).representation = IDENTITY;

        Pet pet = 2;
      }
    }

    message Pet {
      option (elixir.pb.v1.message).struct = "PB.TermRepresentationTest.OptionPetTerm";

      string name = 1;
    }
    """
  end
end

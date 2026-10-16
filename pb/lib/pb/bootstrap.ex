defmodule PB.Bootstrap do
  @moduledoc false

  # Minimal hardcoded schema for the subset of descriptor.proto needed to
  # bootstrap: decode a FileDescriptorSet binary so we can compile it into
  # a full schema. This solves the chicken-and-egg problem.
  #
  # At compile time we use this to decode priv/bootstrap.binpb, then compile
  # that into a richer decode schema. We decode bootstrap.binpb once more with
  # the richer schema so any bundled extensions are visible to the schema
  # embedded as a module attribute. That schema can then decode normal
  # FileDescriptorSet values with typed bundled extensions.

  @minimal_schema (
                    f = fn fields, opts ->
                      by_name = Map.new(fields, &{&1.name, &1})

                      %{
                        kind: :message,
                        fields_by_name: by_name,
                        oneofs: Map.get(opts, :oneofs, %{}),
                        extension_ranges: [],
                        extensions_by_name: %{},
                        map_entry: Map.get(opts, :map_entry, false),
                        syntax: :proto2
                      }
                    end

                    str = fn name, num ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_STRING,
                        wire_type: 2,
                        cardinality: :singular,
                        presence: :explicit,
                        encoding: :scalar,
                        source: %{label: :LABEL_OPTIONAL}
                      }
                    end

                    int32 = fn name, num ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_INT32,
                        wire_type: 0,
                        cardinality: :singular,
                        presence: :explicit,
                        encoding: :scalar,
                        source: %{label: :LABEL_OPTIONAL}
                      }
                    end

                    bool_f = fn name, num ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_BOOL,
                        wire_type: 0,
                        cardinality: :singular,
                        presence: :explicit,
                        encoding: :scalar,
                        source: %{label: :LABEL_OPTIONAL}
                      }
                    end

                    msg = fn name, num, tn ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_MESSAGE,
                        wire_type: 2,
                        cardinality: :singular,
                        presence: :explicit,
                        encoding: :length_prefixed,
                        source: %{label: :LABEL_OPTIONAL},
                        type_name: tn
                      }
                    end

                    rep_str = fn name, num ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_STRING,
                        wire_type: 2,
                        cardinality: :repeated,
                        presence: :none,
                        encoding: :expanded,
                        source: %{label: :LABEL_REPEATED}
                      }
                    end

                    rep_msg = fn name, num, tn ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_MESSAGE,
                        wire_type: 2,
                        cardinality: :repeated,
                        presence: :none,
                        encoding: :length_prefixed,
                        source: %{label: :LABEL_REPEATED},
                        type_name: tn
                      }
                    end

                    enum_f = fn name, num, tn ->
                      %{
                        name: name,
                        number: num,
                        type: :TYPE_ENUM,
                        wire_type: 0,
                        cardinality: :singular,
                        presence: :explicit,
                        encoding: :scalar,
                        source: %{label: :LABEL_OPTIONAL},
                        type_name: tn
                      }
                    end

                    %{
                      messages: %{
                        :"google.protobuf.FileDescriptorSet" =>
                          f.([rep_msg.(:file, 1, :"google.protobuf.FileDescriptorProto")], %{}),
                        :"google.protobuf.FileDescriptorProto" =>
                          f.(
                            [
                              str.(:name, 1),
                              str.(:package, 2),
                              rep_str.(:dependency, 3),
                              rep_msg.(:message_type, 4, :"google.protobuf.DescriptorProto"),
                              rep_msg.(:enum_type, 5, :"google.protobuf.EnumDescriptorProto"),
                              str.(:syntax, 12)
                            ],
                            %{}
                          ),
                        :"google.protobuf.DescriptorProto" =>
                          f.(
                            [
                              str.(:name, 1),
                              rep_msg.(:field, 2, :"google.protobuf.FieldDescriptorProto"),
                              rep_msg.(:nested_type, 3, :"google.protobuf.DescriptorProto"),
                              rep_msg.(:enum_type, 4, :"google.protobuf.EnumDescriptorProto"),
                              msg.(:options, 7, :"google.protobuf.MessageOptions"),
                              rep_msg.(:oneof_decl, 8, :"google.protobuf.OneofDescriptorProto")
                            ],
                            %{}
                          ),
                        :"google.protobuf.FieldDescriptorProto" =>
                          f.(
                            [
                              str.(:name, 1),
                              int32.(:number, 3),
                              enum_f.(:label, 4, :"google.protobuf.FieldDescriptorProto.Label"),
                              enum_f.(:type, 5, :"google.protobuf.FieldDescriptorProto.Type"),
                              str.(:type_name, 6),
                              msg.(:options, 8, :"google.protobuf.FieldOptions"),
                              int32.(:oneof_index, 9),
                              bool_f.(:proto3_optional, 17)
                            ],
                            %{}
                          ),
                        :"google.protobuf.EnumDescriptorProto" =>
                          f.(
                            [
                              str.(:name, 1),
                              rep_msg.(:value, 2, :"google.protobuf.EnumValueDescriptorProto")
                            ],
                            %{}
                          ),
                        :"google.protobuf.EnumValueDescriptorProto" =>
                          f.([str.(:name, 1), int32.(:number, 2)], %{}),
                        :"google.protobuf.OneofDescriptorProto" => f.([str.(:name, 1)], %{}),
                        :"google.protobuf.FieldOptions" => f.([bool_f.(:packed, 2)], %{}),
                        :"google.protobuf.MessageOptions" => f.([bool_f.(:map_entry, 7)], %{})
                      },
                      enums: %{
                        :"google.protobuf.FieldDescriptorProto.Type" => %{
                          by_name: %{
                            TYPE_DOUBLE: 1,
                            TYPE_FLOAT: 2,
                            TYPE_INT64: 3,
                            TYPE_UINT64: 4,
                            TYPE_INT32: 5,
                            TYPE_FIXED64: 6,
                            TYPE_FIXED32: 7,
                            TYPE_BOOL: 8,
                            TYPE_STRING: 9,
                            TYPE_GROUP: 10,
                            TYPE_MESSAGE: 11,
                            TYPE_BYTES: 12,
                            TYPE_UINT32: 13,
                            TYPE_ENUM: 14,
                            TYPE_SFIXED32: 15,
                            TYPE_SFIXED64: 16,
                            TYPE_SINT32: 17,
                            TYPE_SINT64: 18
                          },
                          by_number: %{
                            1 => :TYPE_DOUBLE,
                            2 => :TYPE_FLOAT,
                            3 => :TYPE_INT64,
                            4 => :TYPE_UINT64,
                            5 => :TYPE_INT32,
                            6 => :TYPE_FIXED64,
                            7 => :TYPE_FIXED32,
                            8 => :TYPE_BOOL,
                            9 => :TYPE_STRING,
                            10 => :TYPE_GROUP,
                            11 => :TYPE_MESSAGE,
                            12 => :TYPE_BYTES,
                            13 => :TYPE_UINT32,
                            14 => :TYPE_ENUM,
                            15 => :TYPE_SFIXED32,
                            16 => :TYPE_SFIXED64,
                            17 => :TYPE_SINT32,
                            18 => :TYPE_SINT64
                          },
                          default: :TYPE_DOUBLE
                        },
                        :"google.protobuf.FieldDescriptorProto.Label" => %{
                          by_name: %{
                            LABEL_OPTIONAL: 1,
                            LABEL_REQUIRED: 2,
                            LABEL_REPEATED: 3
                          },
                          by_number: %{
                            1 => :LABEL_OPTIONAL,
                            2 => :LABEL_REQUIRED,
                            3 => :LABEL_REPEATED
                          },
                          default: :LABEL_OPTIONAL
                        }
                      },
                      services: %{},
                      extensions_by_name: %{}
                    }
                    |> PB.Schema.Prepare.prepare()
                  )

  bootstrap_path = Path.join(:code.priv_dir(:pb), "bootstrap.binpb")

  @external_resource bootstrap_path

  # Bootstrap at compile time:
  # 1. Decode bootstrap.binpb using the minimal schema. This learns the full
  #    descriptor.proto message shape, but file-level extension declarations are
  #    still unknown.
  # 2. Compile that into an intermediate decode schema.
  # 3. Decode bootstrap.binpb again with the intermediate schema, so bundled
  #    extension declarations are now ordinary fields.
  # 4. Compile the final bootstrap descriptor schema.
  @descriptor_binpb File.read!(bootstrap_path)

  {:ok, minimal_descriptor_set} =
    PB.decode(@descriptor_binpb, @minimal_schema, :"google.protobuf.FileDescriptorSet")

  @bootstrap_decode_schema PB.compile(minimal_descriptor_set)

  {:ok, descriptor_set} =
    PB.decode(
      @descriptor_binpb,
      @bootstrap_decode_schema,
      :"google.protobuf.FileDescriptorSet"
    )

  @descriptor_schema PB.compile(descriptor_set)

  @doc """
  Returns the minimal bootstrap schema. This is only useful for
  bootstrapping — prefer `descriptor_schema/0` for all other uses.
  """
  @spec minimal_schema() :: PB.schema()
  def minimal_schema, do: @minimal_schema

  @doc """
  Returns the full compiled schema for `google.protobuf.descriptor.proto`.

  This schema can decode any `FileDescriptorSet` with complete fidelity,
  including services, methods, options, source code info, etc.
  """
  @spec descriptor_schema() :: PB.schema()
  def descriptor_schema, do: @descriptor_schema
end

defmodule PB.CEL.CheckerTest do
  # The schema-backed half of CEL's checker tests; the rest are cel_ex's.
  use ExUnit.Case, async: true

  alias CEL.Error
  alias CEL.Checked
  alias PB.CEL.ProtoCodec
  alias CEL.ProtoType
  alias CEL.Checker.Types, as: CType

  # A provider whose state wraps PB.CEL.Types' own.
  defmodule WrappedTypes do
    @behaviour CEL.TypeProvider

    for {name, arity} <- CEL.TypeProvider.behaviour_info(:callbacks) do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      @impl true
      def unquote(name)({:wrapped, schema}, unquote_splicing(args)),
        do: PB.CEL.Types.unquote(name)(schema, unquote_splicing(args))
    end
  end

  test "uses schema-backed protobuf field types" do
    msg_type = CType.message("cel.expr.conformance.proto3.TestAllTypes")

    checked =
      CEL.check!(
        "msg.single_int64",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.int()
    assert ref(checked, checked.expr.id).overload_id == ["select_message"]

    %{expr_kind: {:select_expr, %{operand: operand}}} = checked.expr

    assert Checked.op(checked, checked.expr) ==
             {:select,
              %{
                kind: :message_field,
                field: "single_int64",
                receiver_id: operand.id,
                test_only: false,
                overload_id: "select_message",
                message: :"cel.expr.conformance.proto3.TestAllTypes",
                cel_field: %CEL.Field{
                  name: "single_int64",
                  type: :int,
                  kind: :singular,
                  ref: {:field, :"cel.expr.conformance.proto3.TestAllTypes", :single_int64}
                }
              }}

    checked =
      CEL.check!(
        "msg.map_int32_int64[1]",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.int()

    checked =
      CEL.check!(
        "msg.oneof_type.payload.single_int64",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.int()

    checked =
      CEL.check!(
        "[msg.single_int64_wrapper, msg.single_int64]",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.list(CType.wrapper(:int))
    assert Checked.proto_type(checked, checked.expr) == ProtoType.list(ProtoType.wrapper(:INT64))

    checked =
      CEL.check!(
        "[msg.single_timestamp, null][0]",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert Checked.proto_type(checked, checked.expr) == ProtoType.timestamp()

    assert {:error, %Error{phase: :check, message: "no such field \"missing\""}} =
             CEL.check(
               "msg.missing",
               env(
                 vars: %{"msg" => msg_type},
                 types: PB.CEL.types(PB.TestSupport.TestSchema)
               )
             )

    checked =
      CEL.check!(
        "has(msg.single_int64)",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.bool()

    %{expr_kind: {:select_expr, %{operand: operand}}} = checked.expr

    assert Checked.op(checked, checked.expr) ==
             {:select,
              %{
                kind: :presence_test,
                field: "single_int64",
                receiver_id: operand.id,
                test_only: true,
                overload_id: "select_message",
                message: :"cel.expr.conformance.proto3.TestAllTypes",
                cel_field: %CEL.Field{
                  name: "single_int64",
                  type: :int,
                  kind: :singular,
                  ref: {:field, :"cel.expr.conformance.proto3.TestAllTypes", :single_int64}
                }
              }}

    assert {:error, %Error{phase: :check, message: "no such field \"missing\""}} =
             CEL.check(
               "has(msg.missing)",
               env(
                 vars: %{"msg" => msg_type},
                 types: PB.CEL.types(PB.TestSupport.TestSchema)
               )
             )
  end

  test "uses the configured type provider and its state" do
    msg_type = CType.message("cel.expr.conformance.proto3.TestAllTypes")

    checked =
      CEL.check!(
        "msg.single_int64",
        env(
          vars: %{"msg" => msg_type},
          types: {WrappedTypes, {:wrapped, PB.TestSupport.TestSchema}}
        )
      )

    assert root_type(checked) == CType.int()
    assert ref(checked, checked.expr.id).overload_id == ["select_message"]
  end

  test "uses schema-backed protobuf field refs for optional selects" do
    msg_type = CType.message("cel.expr.conformance.proto3.TestAllTypes")

    checked =
      CEL.check!(
        "msg.?single_int64",
        env(
          vars: %{"msg" => msg_type},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.optional(CType.int())
    assert ref(checked, checked.expr.id) == %{name: "_?._", overload_id: ["optional_select"]}

    %{expr_kind: {:call_expr, %{args: [operand, _field]}}} = checked.expr

    assert Checked.op(checked, checked.expr) ==
             {:select,
              %{
                kind: :optional_field,
                name: "_?._",
                field: "single_int64",
                receiver_id: operand.id,
                test_only: false,
                overload_id: "optional_select",
                message: :"cel.expr.conformance.proto3.TestAllTypes",
                cel_field: %CEL.Field{
                  name: "single_int64",
                  type: :int,
                  kind: :singular,
                  ref: {:field, :"cel.expr.conformance.proto3.TestAllTypes", :single_int64}
                }
              }}

    checked =
      CEL.check!(
        "maybe_msg.single_int64",
        env(
          vars: %{"maybe_msg" => CType.optional(msg_type)},
          types: PB.CEL.types(PB.TestSupport.TestSchema)
        )
      )

    assert root_type(checked) == CType.optional(CType.int())

    assert {:select, op} = Checked.op(checked, checked.expr)
    assert op.kind == :optional_field

    assert op.message == :"cel.expr.conformance.proto3.TestAllTypes"
    assert %CEL.Field{name: "single_int64", type: :int} = op.cel_field
  end

  test "resolves schema-backed enum names" do
    opts =
      env(
        container: "cel.expr.conformance.proto3",
        types: PB.CEL.types(PB.TestSupport.TestSchema)
      )

    checked = CEL.check!("GlobalEnum.GAZ", opts)

    assert root_type(checked) == CType.message(:"cel.expr.conformance.proto3.GlobalEnum")

    assert ref(checked, checked.expr.id) == %{
             name: "cel.expr.conformance.proto3.GlobalEnum.GAZ",
             overload_id: [],
             value: %{
               kind: {:enum_value, %{type: "cel.expr.conformance.proto3.GlobalEnum", value: 2}}
             }
           }

    assert Checked.op(checked, checked.expr) ==
             {:ident,
              %{
                kind: :enum_value,
                name: "cel.expr.conformance.proto3.GlobalEnum.GAZ",
                value: {:enum, :"cel.expr.conformance.proto3.GlobalEnum", 2}
              }}

    checked = CEL.check!("GlobalEnum", opts)

    assert root_type(checked) ==
             CType.type(CType.message(:"cel.expr.conformance.proto3.GlobalEnum"))

    assert Checked.op(checked, checked.expr) ==
             {:ident,
              %{
                kind: :type,
                name: "cel.expr.conformance.proto3.GlobalEnum",
                denotation: CEL.ProtoType.message(:"cel.expr.conformance.proto3.GlobalEnum")
              }}

    assert root_type(CEL.check!("type(GlobalEnum.GOO)", opts)) ==
             CType.type(CType.message(:"cel.expr.conformance.proto3.GlobalEnum"))

    assert root_type(CEL.check!("int(GlobalEnum.GAZ)", opts)) == CType.int()

    assert root_type(CEL.check!("TestAllTypes.NestedEnum(2)", opts)) ==
             CType.message(:"cel.expr.conformance.proto3.TestAllTypes.NestedEnum")
  end

  test "checked expressions export to generated CEL proto codecs" do
    checked = CEL.check!("x + 1", env(vars: %{x: :int}))
    proto = Checked.to_proto(checked)

    assert {:ok, iodata} = ProtoCodec.encode_checked_expr(proto)
    assert {:ok, decoded} = ProtoCodec.decode_checked_expr(IO.iodata_to_binary(iodata))

    assert decoded == proto
  end

  defp env(opts), do: CEL.Env.build(opts)
  defp root_type(checked), do: checked.root_type
  defp ref(checked, expr_or_id), do: Checked.ref(checked, expr_or_id)
end

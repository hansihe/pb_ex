defmodule PB.ProtovalidateProbeTest do
  use ExUnit.Case, async: true

  @extensions :__extensions__

  @binpb_path "test/fixtures/schema/protovalidate_probe.binpb"
  @field_extension :"buf.validate.field"

  setup_all do
    {:ok, binpb: File.read!(@binpb_path)}
  end

  defp locate_probe_field(descriptor_set) do
    file =
      Enum.find(descriptor_set.file, fn f ->
        f.name == "proto/protovalidate_probe.proto"
      end)

    [msg] = file.message_type
    [field] = msg.field
    {file, msg, field}
  end

  test "decode_descriptor_set/1 leaves buf.validate.field an unknown field",
       %{binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    {_file, _msg, field} = locate_probe_field(descriptor_set)
    options = field.options

    refute Map.has_key?(options, @extensions),
           "pb's bundled schema should know no buf.validate extensions"

    assert [%PB.UnknownField{number: 1159}] = options[PB.UnknownField.key()]
  end

  test "the bundled validate schema decodes buf.validate.field as an extension",
       %{binpb: binpb} do
    {:ok, descriptor_set} =
      PB.__decode_descriptor_set_with_schema__(binpb, PB.Validate.BundledSchema)

    {_file, _msg, field} = locate_probe_field(descriptor_set)
    options = field.options

    assert is_map(options[@extensions]),
           "expected extension map on FieldOptions for the bundled schema decode path"

    assert field_rules = options[@extensions][@field_extension],
           "expected buf.validate.field to be decoded into the extension map"

    assert %{type: {:string, %{min_len: 3}}} = field_rules
  end

  test "Schema.Compiler.compile/1 carries raw :options on the constrained field",
       %{binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    intermediate = PB.Schema.Compiler.compile(descriptor_set)
    msg = intermediate.messages[:"protovalidate_probe.Probe"]
    [field] = Map.values(msg.fields_by_name)

    assert is_map(field.options),
           "Phase 1 should leave raw FieldOptions on the compiled field entry"

    assert %{type: {:string, %{min_len: 3}}} =
             field.options[@extensions][@field_extension]
  end

  test "PB.compile/1 keeps materialized :options on the final field entry",
       %{binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    compiled = PB.compile(descriptor_set)
    msg = compiled.messages[:"protovalidate_probe.Probe"]
    field = msg.fields_by_number[1]

    assert %{type: {:string, %{min_len: 3}}} = field.options[@extensions][@field_extension]
  end
end

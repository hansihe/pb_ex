# Builds a FileDescriptorSet for a root .proto file out of the files of an
# existing set, without buf.
#
# Usage, from pb/:
#
#     mix run scripts/subset_descriptor_set.exs INPUT ROOT OUTPUT [options]
#
# OUTPUT gets the files of INPUT that ROOT imports, directly or not, byte for
# byte and in INPUT's order, followed by ROOT. ROOT is a file name such as
# `proto/main.proto`. Options:
#
#   * `--proto-dir DIR` - compile ROOT from `DIR/ROOT` with protoc, with the
#     files of INPUT (other than ROOT itself) as its imports. Without it, ROOT
#     is taken from INPUT as it is.
#   * `--exclude-source-info` - with `--proto-dir`, leave out ROOT's source
#     info, as for sets built without it, like `priv/bootstrap.binpb`.
#   * `--drop FILE` - leave FILE out of OUTPUT, as though the set were built
#     without it. May be given more than once.
#
# With INPUT built by buf from the same buf dependencies, OUTPUT is what
# `buf build ROOT --as-file-descriptor-set` writes, so this stands in for buf
# when the dependencies are not at hand.
#
# The library split built these sets with it (run from pb/), from copies of the
# pre-split `pb/priv/main.binpb`, `pb/priv/bootstrap.binpb` and
# `pb/test/fixtures/schema/test.binpb` in /tmp, as buf's dependencies were not
# at hand. Each project's `build_protos.sh` rebuilds them with buf. The
# pre-split files are at the split's base commit, as in
# `git show 24d3d9b:pb/priv/main.binpb > /tmp/main.binpb`.
#
#     mix run scripts/subset_descriptor_set.exs /tmp/main.binpb proto/main.proto priv/main.binpb --proto-dir .
#     mix run scripts/subset_descriptor_set.exs /tmp/bootstrap.binpb proto/bootstrap.proto priv/bootstrap.binpb --proto-dir . --exclude-source-info
#     mix run scripts/subset_descriptor_set.exs /tmp/test.binpb proto/test.proto test/fixtures/schema/test.binpb --proto-dir .
#     mix run scripts/subset_descriptor_set.exs /tmp/main.binpb proto/cel.proto ../pb_cel/priv/cel.binpb --proto-dir ../pb_cel
#     mix run scripts/subset_descriptor_set.exs /tmp/test.binpb proto/test.proto ../pb_cel/test/fixtures/schema/test.binpb --proto-dir ../pb_cel
#     mix run scripts/subset_descriptor_set.exs /tmp/main.binpb proto/validate.proto ../pb_validate/priv/validate.binpb --proto-dir ../pb_validate
#     mix run scripts/subset_descriptor_set.exs /tmp/test.binpb proto/test.proto ../pb_validate/test/fixtures/schema/test.binpb --proto-dir ../pb_validate
#
# pb_validate's build_protos.sh also uses it, with `--drop`, for its fixtures
# of descriptor sets built without `--include_imports`.

defmodule SubsetDescriptorSet do
  # Files are kept as their raw bytes, so only the set's `file` field and a
  # file's `name` and `dependency` fields are decoded.
  @raw_schema PB.compile(%{
                file: [
                  %{
                    name: "raw.proto",
                    package: "raw",
                    syntax: "proto3",
                    message_type: [
                      %{
                        name: "Set",
                        field: [
                          %{name: "file", number: 1, label: :LABEL_REPEATED, type: :TYPE_BYTES}
                        ]
                      },
                      %{
                        name: "File",
                        field: [
                          %{name: "name", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_STRING},
                          %{
                            name: "dependency",
                            number: 3,
                            label: :LABEL_REPEATED,
                            type: :TYPE_STRING
                          }
                        ]
                      }
                    ]
                  }
                ]
              })

  def main(argv) do
    {opts, args} =
      OptionParser.parse!(argv,
        strict: [proto_dir: :string, exclude_source_info: :boolean, drop: :keep]
      )

    [input, root, output] =
      case args do
        [_input, _root, _output] = args -> args
        _other -> raise "usage: INPUT ROOT OUTPUT [--proto-dir DIR] [--exclude-source-info] [--drop FILE]"
      end

    files = input |> File.read!() |> files()
    {roots, imports} = Enum.split_with(files, &(&1.name == root))

    root_file =
      case {opts[:proto_dir], roots} do
        {nil, [root_file]} -> root_file
        {nil, []} -> raise "#{root} is not in the input set"
        {dir, _roots} -> compile_root(imports, dir, root, !opts[:exclude_source_info])
      end

    dropped = Keyword.get_values(opts, :drop)
    needed = closure(root_file.dependency, Map.new(imports, &{&1.name, &1}), MapSet.new())

    kept =
      Enum.filter(imports, &(MapSet.member?(needed, &1.name) and &1.name not in dropped)) ++
        [root_file]

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, encode(kept))

    IO.puts("Wrote #{output}:")
    Enum.each(kept, &IO.puts("  #{&1.name}"))
  end

  defp files(binary) do
    %{file: raws} = PB.decode!(binary, @raw_schema, :"raw.Set")

    Enum.map(raws, fn raw ->
      file = PB.decode!(raw, @raw_schema, :"raw.File")
      %{name: file.name, dependency: Map.get(file, :dependency, []), raw: raw}
    end)
  end

  defp encode(files) do
    %{file: Enum.map(files, & &1.raw)}
    |> PB.encode!(@raw_schema, :"raw.Set")
    |> IO.iodata_to_binary()
  end

  defp compile_root(imports, proto_dir, root, source_info?) do
    tmp = Path.join(System.tmp_dir!(), "subset_descriptor_set_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      imports_path = Path.join(tmp, "imports.binpb")
      root_path = Path.join(tmp, "root.binpb")
      File.write!(imports_path, encode(imports))

      args =
        ["--descriptor_set_in=#{imports_path}", "--proto_path=.", "--descriptor_set_out=#{root_path}"] ++
          if(source_info?, do: ["--include_source_info"], else: []) ++ [root]

      case System.cmd("protoc", args, cd: proto_dir, stderr_to_stdout: true) do
        {_output, 0} -> root_path |> File.read!() |> files() |> hd()
        {output, status} -> raise "protoc exited with #{status}:\n#{output}"
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp closure([], _files, needed), do: needed

  defp closure([name | rest], files, needed) do
    cond do
      MapSet.member?(needed, name) ->
        closure(rest, files, needed)

      Map.has_key?(files, name) ->
        closure(files[name].dependency ++ rest, files, MapSet.put(needed, name))

      true ->
        raise "#{name} is not in the input set"
    end
  end
end

SubsetDescriptorSet.main(System.argv())

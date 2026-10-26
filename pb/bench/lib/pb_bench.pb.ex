defmodule Bench.Role do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :UNKNOWN, 0
  field :ADMIN, 1
  field :USER, 2
end

defmodule Bench.PhoneNumber do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :number, 1, type: :string
end

defmodule Bench.Pet do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :name, 1, type: :string
end

defmodule Bench.Fish do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :species, 1, type: :string
end

defmodule Bench.Person.TagsEntry do
  @moduledoc false

  use Protobuf, map: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :int32
end

defmodule Bench.Person do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  oneof :companion, 0

  field :name, 1, type: :string
  field :id, 2, type: :int32
  field :phones, 4, repeated: true, type: Bench.PhoneNumber
  field :role, 5, type: Bench.Role, enum: true
  field :scores, 6, repeated: true, type: :int32
  field :pet, 7, type: Bench.Pet, oneof: 0
  field :fish, 8, type: Bench.Fish, oneof: 0
  field :tags, 9, repeated: true, type: Bench.Person.TagsEntry, map: true
end

defmodule Bench.Scalars do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :f_double, 1, type: :double, json_name: "fDouble"
  field :f_float, 2, type: :float, json_name: "fFloat"
  field :f_int64, 3, type: :int64, json_name: "fInt64"
  field :f_uint64, 4, type: :uint64, json_name: "fUint64"
  field :f_int32, 5, type: :int32, json_name: "fInt32"
  field :f_fixed64, 6, type: :fixed64, json_name: "fFixed64"
  field :f_fixed32, 7, type: :fixed32, json_name: "fFixed32"
  field :f_bool, 8, type: :bool, json_name: "fBool"
  field :f_string, 9, type: :string, json_name: "fString"
  field :f_bytes, 10, type: :bytes, json_name: "fBytes"
  field :f_uint32, 11, type: :uint32, json_name: "fUint32"
  field :f_sfixed32, 12, type: :sfixed32, json_name: "fSfixed32"
  field :f_sfixed64, 13, type: :sfixed64, json_name: "fSfixed64"
  field :f_sint32, 14, type: :sint32, json_name: "fSint32"
  field :f_sint64, 15, type: :sint64, json_name: "fSint64"
end

defmodule Bench.Packed do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :ints, 1, repeated: true, type: :int32
  field :sint64s, 2, repeated: true, type: :sint64
  field :doubles, 3, repeated: true, type: :double
  field :bools, 4, repeated: true, type: :bool
end
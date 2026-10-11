defmodule PB.Schema.Compiled do
  @moduledoc false

  # Types for PB's prepared compiled schema.
  #
  # `PB.compile/2` returns this schema shape after descriptor compilation,
  # annotation, projection application, and final preparation. Runtime
  # encode/decode, validation, JSON, CEL, and message equality consume these
  # resolved structures directly instead of re-deriving descriptor semantics on
  # hot paths.

  @typedoc "Prepared compiled PB schema."
  @type t :: %{
          required(:messages) => %{optional(message_name()) => message()},
          required(:enums) => %{optional(enum_name()) => enum()},
          required(:services) => %{optional(service_name()) => service()},
          required(:extensions_by_name) => %{optional(extension_name()) => field()},
          optional(:roots) => [message_name()],
          optional(:root_names) => %{optional(message_name()) => atom()}
        }

  @typedoc "Fully-qualified protobuf message name."
  @type message_name :: atom()

  @typedoc "Fully-qualified protobuf enum name."
  @type enum_name :: atom()

  @typedoc "Fully-qualified protobuf service name."
  @type service_name :: atom()

  @typedoc "Fully-qualified protobuf extension field name."
  @type extension_name :: atom()

  @typedoc "Field name atom as it appears in PB message maps."
  @type field_name :: atom()

  @typedoc "Protobuf field number."
  @type field_number :: pos_integer()

  @typedoc "Resolved protobuf field type used by runtime encode/decode."
  @type field_type ::
          :TYPE_DOUBLE
          | :TYPE_FLOAT
          | :TYPE_INT64
          | :TYPE_UINT64
          | :TYPE_INT32
          | :TYPE_FIXED64
          | :TYPE_FIXED32
          | :TYPE_BOOL
          | :TYPE_STRING
          | :TYPE_MESSAGE
          | :TYPE_BYTES
          | :TYPE_UINT32
          | :TYPE_ENUM
          | :TYPE_SFIXED32
          | :TYPE_SFIXED64
          | :TYPE_SINT32
          | :TYPE_SINT64

  @typedoc "Resolved field cardinality in a compiled schema."
  @type cardinality :: :singular | :repeated | :map

  @typedoc "Resolved protobuf presence semantics in a compiled schema."
  @type presence :: :implicit | :explicit | :required | :oneof | :none

  @typedoc "Resolved wire encoding strategy in a compiled schema."
  @type encoding :: :scalar | :expanded | :packed | :length_prefixed | :delimited

  @typedoc "Compiled protobuf enum metadata."
  @type enum :: %{
          required(:by_name) => %{optional(atom()) => integer()},
          required(:by_number) => %{optional(integer()) => atom()},
          required(:default) => atom() | integer(),
          required(:features) => map()
        }

  @typedoc "Compiled protobuf oneof metadata."
  @type oneof :: %{
          required(:name) => field_name(),
          required(:fields) => [field_name()],
          optional(:term_by_struct) => %{optional(module()) => field_name()}
        }

  @typedoc "Compiled extension range metadata."
  @type extension_range :: %{
          required(:start) => integer(),
          required(:end) => integer()
        }

  @typedoc "Compiled protobuf field metadata."
  @type field :: %{
          required(:name) => field_name() | extension_name(),
          required(:number) => field_number(),
          required(:type) => field_type(),
          required(:wire_type) => 0..5,
          required(:cardinality) => cardinality(),
          required(:presence) => presence(),
          required(:encoding) => encoding(),
          required(:features) => map(),
          required(:source) => map(),
          required(:tag) => iodata(),
          optional(:kind) => :extension,
          optional(:local_name) => field_name(),
          optional(:extendee) => message_name(),
          optional(:type_name) => message_name() | enum_name(),
          optional(:default) => term(),
          optional(:json_name) => binary(),
          optional(:oneof_index) => non_neg_integer(),
          optional(:map_entry) => message(),
          optional(:map_key) => field(),
          optional(:map_value) => field(),
          optional(:adapter) => PB.Adapter.t(),
          optional(:enum) => enum(),
          optional(:packed_tag) => iodata(),
          optional(:validate) => term()
        }

  @typedoc "Compiled protobuf message metadata."
  @type message :: %{
          required(:kind) => :message,
          required(:fields_by_name) => %{optional(field_name()) => field()},
          required(:fields_by_number) => %{optional(field_number()) => field()},
          required(:oneofs) => %{optional(non_neg_integer()) => oneof()},
          required(:oneofs_by_name) => %{optional(field_name()) => oneof()},
          required(:oneof_field_names) => %{optional(field_name()) => true},
          required(:map_entry) => boolean(),
          required(:extension_ranges) => [extension_range()],
          required(:extensions_by_name) => %{optional(extension_name()) => field()},
          required(:extensions_by_number) => %{optional(field_number()) => field()},
          required(:required_fields) => [{field_name(), field_type()}],
          required(:default_fields) => [field()],
          required(:syntax) => atom(),
          required(:edition) => atom() | nil,
          required(:source) => map(),
          required(:features) => map(),
          optional(:reserved_names) => [binary()],
          optional(:reserved_ranges) => [extension_range()],
          optional(:projection) => PB.Schema.Projection.t(),
          optional(:validate) => term()
        }

  @typedoc "Compiled protobuf service method metadata."
  @type service_method :: %{
          required(:input_type) => message_name(),
          required(:output_type) => message_name(),
          required(:client_streaming) => boolean(),
          required(:server_streaming) => boolean()
        }

  @typedoc "Compiled protobuf service metadata."
  @type service :: %{
          required(:methods) => %{optional(atom()) => service_method()}
        }
end

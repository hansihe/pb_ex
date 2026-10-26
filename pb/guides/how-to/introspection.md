# Introspecting a schema

If you are building on top of PB — a gRPC/Connect framework, a code generator, a
schema explorer — you need to enumerate and inspect the messages, enums, services,
and extensions in a schema. `PB.Schema` provides stable introspection helpers that
return names from `list_*` calls and `PB.Schema.Info` structs from lookup calls.

> The map returned by `PB.compile/1` is an internal representation. Its structure
> is not part of the public API and may change without notice. Always go through
> the introspection helpers rather than reaching into the compiled map.

## Messages, enums, extensions

```elixir
PB.Schema.list_messages(schema)                   # => [:"my.pkg.Person", ...]
PB.Schema.fetch_message(schema, :"my.pkg.Person")  # => {:ok, info} | :error
PB.Schema.message!(schema, :"my.pkg.Person")       # => info | raises

PB.Schema.list_enums(schema)                       # => [:"my.pkg.Role", ...]
PB.Schema.fetch_enum(schema, :"my.pkg.Role")
PB.Schema.enum!(schema, :"my.pkg.Role")

PB.Schema.list_extensions(schema)                  # => [:"my.pkg.priority", ...]
PB.Schema.fetch_extension(schema, :"my.pkg.priority")
PB.Schema.extension!(schema, :"my.pkg.priority")
```

Each helper accepts either a compiled schema map or a `use PB.Schema` module.
The `list_*` helpers return sorted fully-qualified name atoms; use the
`fetch_*` or bang helpers when you need the corresponding `PB.Schema.Info`
struct.

A message's fields are `PB.Schema.Info.Field` structs carrying name, number,
type, cardinality, presence, and the message-level `:projection` (see
`PB.Schema.Projection`). Field types are tagged tuples like `{:scalar, :int32}`,
`{:message, name}`, `{:enum, name}`, or `{:map, key_type, value_type}`.

## Services and methods

Service definitions are extracted by `PB.compile/1` and exposed the same way,
including method input/output types and streaming flags — useful for RPC
frameworks:

```elixir
PB.Schema.list_services(schema)
PB.Schema.fetch_service(schema, :"my.pkg.Greeter")
PB.Schema.service!(schema, :"my.pkg.Greeter")
```

See `PB.Schema.Info.Service`, `PB.Schema.Info.Method` for the struct shapes.

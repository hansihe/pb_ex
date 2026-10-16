# Extensions and unknown fields

PB preserves data the current schema does not have a declared field for, rather
than dropping or rejecting it. Both live under
[reserved dunder keys](../reference/data-representation.md#reserved-metadata-keys)
so they cannot collide with real `.proto` field names.

## Unknown wire fields

Wire fields the schema does not recognise are preserved under
`:__unknown_fields__` as a list of `PB.UnknownField` structs, in observed order:

```elixir
%{
  name: "Alice",
  __unknown_fields__: [%PB.UnknownField{...}]
}
```

They round-trip: supply them back on encode and PB emits the preserved raw wire
bytes. Unknown fields are not schema-modeled, so most applications can ignore
them. Struct representations **drop** them by default — see the
`preserved_unknown_fields:` policy in
[Decoding into structs](structs-and-representation.md#auxiliary-data-policies).

## Extensions

Known extension values are resolved through the schema and stored under
`:__extensions__`, keyed by fully-qualified extension name:

```elixir
%{
  __extensions__: %{:"my.pkg.priority" => 5}
}
```

Once resolved, extensions behave like declared fields. Enumerate the extensions a
schema knows with `PB.Schema.list_extensions/1` and look them up with
`PB.Schema.fetch_extension/2` / `PB.Schema.extension!/2` (see
[Introspection](introspection.md)).

Because extensions are schema-modeled data, a struct representation that has
nowhere to put them **rejects** them at compile time by default. Opt into an
explicit storage field when you need to carry them — see the `extensions:` policy
in [Decoding into structs](structs-and-representation.md#auxiliary-data-policies).

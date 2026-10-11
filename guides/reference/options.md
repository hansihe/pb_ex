# Options reference

A consolidated list of the options each public entry point accepts. Unknown
options are rejected (they raise or return a `PB.OptionError`) rather than being
silently ignored.

## `PB.compile/2`

| Option | Values | Default | Notes |
|--------|--------|---------|-------|
| `:projections` | list of `{fqn, opts}` | `[]` | Message-level adapters and structural representation. See below. |

Each `:projections` entry pairs a fully-qualified message name with a keyword
list. `adapter:` is mutually exclusive with the structural keys:

| Key | Values | Notes |
|-----|--------|-------|
| `adapter:` | `%PB.Adapter{}` | App/proto conversion spec. |
| `struct:` | `Module` | Project the message to a struct. |
| `unwrap:` | `field_name \| true` | Project to the single field's value. |
| `preserved_unknown_fields:` | `:drop \| :reject \| {:field, atom}` | Unknown-field policy (struct/unwrap). Default `:drop`. |
| `extensions:` | `:reject \| {:field, atom}` | Extension policy (struct). Default `:reject`. |
| `oneofs:` | `[{oneof_name, [representation: :identity]}]` | Identity-projected oneofs. |

See [Decoding into structs](../how-to/structs-and-representation.md) and
[Adapters and well-known types](../how-to/adapters-and-well-known-types.md).

## `PB.encode/4` / `PB.encode!/4` / `PB.encode_iodata/4`

| Option | Values | Default | Notes |
|--------|--------|---------|-------|
| `:unknown_fields` | `:error \| :ignore` | `:error` | How unknown map keys are handled. |

## `PB.decode/4` / `PB.decode!/4`

| Option | Values | Default | Notes |
|--------|--------|---------|-------|
| `:defaults` | `boolean` | `false` | Populate missing scalar/enum/repeated/map fields with proto3 defaults. Singular messages and oneofs are never populated. |
| `:message_names` | `nil \| :root` | `nil` | Annotate the root decoded map with `:__message_name__`. |

## `PB.JSON` encode (`encode/4`, `encode_iodata/4`, `to_term/4`)

| Option | Values | Default |
|--------|--------|---------|
| `:emit_defaults` | `boolean` | `false` |
| `:use_proto_names` | `boolean` | `false` |
| `:enums_as_ints` | `boolean` | `false` |

## `PB.JSON` decode (`decode/4`, `from_term/4`)

| Option | Values | Default |
|--------|--------|---------|
| `:ignore_unknown` | `boolean` | `false` |

## `PB.TextFormat` decode (`decode/4`)

| Option | Values | Default |
|--------|--------|---------|
| `:ignore_unknown` | `boolean` | `false` |

## `PB.Validate.validate/4`

| Option | Values | Notes |
|--------|--------|-------|
| `:context` | `keyword \| map \| %PB.Validate.Context{}` | Runtime context for CEL evaluation. |
| `:now` | `integer \| DateTime.t() \| {:timestamp, unix_nanoseconds}` | Value bound to the `now` variable in CEL rules when `:context` is not supplied. |

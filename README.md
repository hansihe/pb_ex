# pb_ex

This repository hosts several Elixir libraries, each in its own directory:

- [`cel_ex/`](cel_ex/README.md): the Common Expression Language (CEL) for
  Elixir, with no protobuf dependency.
- [`pb/`](pb/README.md): data-driven protobuf toolkit for Elixir, with no
  dependencies.
- [`pb_cel/`](pb_cel/README.md): CEL over protobuf messages, a `cel_ex` type
  provider for `pb` schemas.
- [`pb_validate/`](pb_validate/README.md): protovalidate validation for `pb`,
  as a schema plugin; it depends on `pb_cel` for its CEL rules.

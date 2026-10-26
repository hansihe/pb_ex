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

## Development

`pb_cel` and `pb_validate` depend on their siblings from Hex unless
`PB_EX_LOCAL=1`, which makes them use the checkouts in this repository.
`mise.toml` sets it, so with [mise](https://mise.jdx.dev) activated nothing
needs doing; otherwise export it yourself.

## Releasing

The four libraries are released together at one version.

1. Set `@version` in each `mix.exs` to the new version.
2. Run `scripts/publish.sh` to build every package without publishing.
3. Push a `vX.Y.Z` tag. The `Publish` workflow runs the tests and then
   `scripts/publish.sh --yes`, which publishes in dependency order (`cel_ex`,
   `pb`, `pb_cel`, `pb_validate`) and skips any that are already on Hex.

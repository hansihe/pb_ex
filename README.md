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

The four libraries are released together at one version. Each has a
`CHANGELOG.md`; note changes under its `## Unreleased` heading as they land.

1. Run `scripts/bump_version.sh X.Y.Z`. It sets `@version` in each `mix.exs`
   and moves each changelog's unreleased entries under `## vX.Y.Z (date)`.
2. Review the changelogs, then run `scripts/publish.sh` to build every package
   without publishing.
3. Commit, and push a `vX.Y.Z` tag on that commit. The `Publish` workflow runs
   CI and then `scripts/publish.sh --yes`. That publishes the packages in
   dependency order (`cel_ex`, `pb`, `pb_cel`, `pb_validate`), skipping any
   already on Hex. It refuses to publish if the tag doesn't match the version or
   a changelog has no section for it.

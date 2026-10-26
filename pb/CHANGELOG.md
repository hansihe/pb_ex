# Changelog

The library is still changing quickly. Until it settles, this changelog lists
releases and only their most important changes.

## Unreleased

- CEL and protovalidate support moved out into their own packages. The CEL
  evaluator is now `cel_ex`, with modules renamed from `PB.CEL.*` to `CEL.*`.
  `pb_cel` provides `PB.CEL` for CEL over pb messages. `pb_validate` provides
  `PB.Validate`, which you now enable as a schema plugin with
  `plugins: [PB.Validate]`.

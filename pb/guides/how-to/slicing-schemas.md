# Slicing and projecting large schemas

> **Maintainer note:** this guide is not currently wired into the published docs
> (`mix.exs` `extras`). The public `PB.slice/2` entry point was removed during an
> in-flight refactor; re-add this guide to `extras` once slicing has a settled
> public API and update the `PB.slice/2` references below to match.

A descriptor set often contains far more than the handful of root messages an
application actually encodes or decodes. `PB.slice/2` narrows a compiled schema to
a set of roots and the messages reachable from them.

```elixir
schema =
  descriptor_set
  |> PB.compile(projections: PB.WellKnownTypes.projections([:time]))
  |> PB.slice(roots: [:"mypackage.Person"])
```

The result contains `mypackage.Person` and its inline reachable closure, and
nothing else.

## Slicing is pure narrowing

`PB.slice/2` only removes. It never adds projections and never re-expands a
schema that was already sliced. Apply projections during `PB.compile/2` first,
then slice — the slice keeps whatever projections survived for the retained
messages.

## When to use it

- **Smaller, faster schemas.** Fewer messages mean smaller lookup tables.
- **Embedding a focused schema module.** Combine with `use PB.Schema` to ship
  only the roots a given module owns.
- **Materialized typespec views** (planned) are scoped per root set, so slicing
  defines that boundary cleanly.

# Fleet.Conflict — domain card

**Date**: 2026-09-04
**Last revised**: 2026-09-04
**Status**: active — deterministic conflict classifier and trivial-merge engine (foundation, `deps: []`)
**Referenced by**: `lib/fleet/conflict.ex` (the facade), `Fleet.Pilot.ConflictProbe` / `ConflictApply`

Pure text in, classification and (when trivial) merged text out. No git, no I/O, no process: the
pilot triages a merge conflict with it BEFORE spending a producer round or escalating to a human,
and every verdict carries a DecisionTrace that says WHY.

**This file is a map, not the contract.** Each module owns its contract in its own `@moduledoc`
— read those (`h Fleet.Conflict` in IEx, or `lib/`). Nothing here is restated, only pointed at.

## Modules

**Engine**
- `Fleet.Conflict` — the facade: `resolve/2` → `%Fleet.Conflict.Report{}`; the "safe to write
  back" signal (`merged` non-nil) and the writable-types judgement live here.
- `Fleet.Conflict.Parser` — conflict markers → hunks (`{:error, {:unterminated_conflict, …}}`
  when they do not close).
- `Fleet.Conflict.Classifier` — the pattern registry: priority order, `requires` filter, first
  `detect?/1` wins; builds the DecisionTrace.
- `Fleet.Conflict.Assemble` — textual merge per conflict type; `:skip` for what the engine does
  not settle.
- `Fleet.Conflict.Diff` — LCS and three-way non-overlapping merge primitives.
- `Fleet.Conflict.Score` — the single authority for composite confidence and its label.
- `Fleet.Conflict.ConfidenceScore` / `Report` and the other structs of `conflict/types.ex` —
  the wire shapes (`Report.stats` carries `writable`).

**Patterns** (`Fleet.Conflict.Pattern` is the behaviour; `Patterns.Utils` the shared helpers)
- `Patterns.SameChange`, `OneSideChange`, `DeleteNoChange`, `NonOverlapping`,
  `InsertionAtBoundary`, `ReorderOnly`, `WhitespaceOnly`, `ValueOnlyChange` — the trivial
  patterns, each with its confidence and its diff2/diff3 requirement.
- `Patterns.Complex` — the total-function fallback: always matches, never resolves.

## Config & deps

- No config key. Origin credited at the repository root (`THIRD_PARTY_NOTICES.md`).
- Deps: `deps: []` — a foundation primitive; the facade's `use Boundary` is the declaration.

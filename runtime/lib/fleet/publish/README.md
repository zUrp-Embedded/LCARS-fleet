# Fleet.Publish — domain card

**Date**: 2026-09-04
**Last revised**: 2026-09-04
**Status**: active — one zero-dependency fact: "this pod has a publish in flight"
**Referenced by**: `Fleet.Spawner.Pod.Publishing` (marks), the deadline recovery (reads)

**This file is a map, not the contract.** The module owns its contract in its `@moduledoc`
(`h Fleet.Publish.InFlight`). Nothing here is restated, only pointed at.

## Modules

- `Fleet.Publish.InFlight` — per-pod in-flight mark protecting a live publish from deadline
  recovery's destructive workspace reset; `while_publishing/2` clears it in an `after`.

## Config & deps

- No config key. `use Boundary, deps: [], exports: []` — the boundary IS the module.

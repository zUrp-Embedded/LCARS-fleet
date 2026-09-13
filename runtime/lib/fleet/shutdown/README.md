# Fleet.Shutdown — domain card

**Date**: 2026-09-04
**Last revised**: 2026-09-04
**Status**: active — the daemon quiescence primitive (flags and counters, no policy)
**Referenced by**: `Fleet.Application` (`init_busy!/0` at boot), `Fleet.Admiral.Shutdown` (the policy)

**This file is a map, not the contract.** The module owns its contract in its `@moduledoc`
(`h Fleet.Shutdown.Quiesce`). Nothing here is restated, only pointed at.

## Modules

- `Fleet.Shutdown.Quiesce` — persistent quiescence flags and activity counters: admission and
  respawn paths refuse new work while finalizers drain current work. Policy stays in
  `Fleet.Admiral`.

## Config & deps

- No config key. `use Boundary, deps: [], exports: []` — the boundary IS the module.

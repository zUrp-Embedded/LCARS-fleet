# Fleet.Application — domain card

**Date**: 2026-09-04
**Last revised**: 2026-09-04
**Status**: active — the OTP root and the catalogue lifecycle it owns
**Referenced by**: `lib/fleet/application.ex` (the root), `bin/lcars` (`catalogue` doors)

The ONE `Application` callback of `:lcars_fleet`: it verifies the catalogue, freezes the two
images, and starts the domain supervisors in the order the boot invariant requires (F8). The
catalogue LIFECYCLE lives here too because it is a boot-and-forge fact, not a pod fact.

**This file is a map, not the contract.** Each module owns its contract in its own `@moduledoc`
— read those (`h Fleet.Application.CatalogueLifecycle` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules

- `Fleet.Application` — the OTP root: catalogue verification, image freezes, the children list
  (its ORDER is the boot invariant, held by the `boot.order_f8` wall), `prep_stop/1`.
- `Fleet.Application.CatalogueDeposits` — which catalogues the forge carries as DEPOSITS (the
  `available` half of the lifecycle).
- `Fleet.Application.CatalogueLifecycle` — the state of every catalogue this forge knows about
  (`available`, `installed`, `updatable`) and the release doors `lcars catalogue …` read.
- `Fleet.Application.CatalogueVerify` — standalone proof of one catalogue root with the daemon's
  own boot checks, without starting a fleet (`mix lcars.catalogue.verify`).
- `Fleet.Roster` (`lib/fleet/roster.ex`, its own boundary, a dep of the root — not boot code) —
  the forge roster a catalogue implies: role logins and the five provisioning lists tofu reads
  (`tfvars/1`).

## Config & deps

- The children order and the two image freezes are locked by `boot.order_f8`,
  `boot.catalogue_before_freeze` and `boot.event_registry_before_children`
  (`lcars.contracts.check`).
- Deps: the root's `use Boundary` declaration (`lib/fleet/application.ex`) — this card points at
  it and does not copy it.

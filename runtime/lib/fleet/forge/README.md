# Fleet.Forge — domain card

**Date**: 2026-08-09
**Last revised**: 2026-09-04
**Status**: active — the fleet's single HTTP exit toward its git forge
**Referenced by**: `lib/fleet/pilot/README.md` (the driver that drives it)

Everything that speaks to the forge over the wire: issues, labels, comments, pulls, reviews,
merges, files, and the branch/PR vocabulary those calls are built from.

**This file is a map, not the contract.** Each module owns its contract in its own `@moduledoc` —
read those (`h Fleet.Forge.Client` in IEx). Nothing here is restated, only pointed at.

## Why it is a domain and not a corner of `Fleet.Pilot`

`Req` and `Req.Response` are declared by THIS boundary and by no other. Declared by a business
domain, *"a single forge HTTP exit"* is a **convention** — true only as long as nobody adds a call
somewhere in the driver. Here the invariant is **compiled**: the wire libraries are fenced to this
boundary and a reference from anywhere else does not build.

What the domain depends on is `Fleet.Labels`, `Fleet.Workflow` and `Fleet.Credentials`, plus the
foundation. `Fleet.Forge.WriteSpacing` lives here because its subject IS the forge: the pilot calls
it exactly where the pilot writes to the forge.

## Modules

- `Fleet.Forge` — facade, boundary anchor, and the authority on the Finch pool name
  (`finch_name/0`: the supervisor that starts the pool and the transport that sends through it must
  not each hold a literal).
- `Fleet.Forge.Client` — the surface the rest of the fleet calls. Sub-modules, one per concern:
  `Jury` (PR review state), `Repo` (repo provisioning), `Files` (contents API), `Labels` (protocol
  labels: set, create on demand), `Merge` (attempt, refusal diagnosis, retry, cleanup), `CI` (a
  commit's CI state reduced from the forge's contexts), `Actions` (trigger a workflow outside a
  push), `Signing` (who may write a marker the runtime re-reads), `UrlSafe` (path-segment encoding).
- `Fleet.Forge.Client.Transport` — the ONLY module that performs HTTP. Pagination, retries, error
  shapes.
- `Fleet.Forge.Payload` — reading the forge's payloads: ONE path per fact, declared here and nowhere
  else; calibrated against the real captures in `test/fixtures/forge/`.
- `Fleet.Forge.Protocol` — pure wire vocabulary (branch names, PR titles, step_run formats). The
  LOCK-label vocabulary is not here: it lives at the foundation (`Fleet.Labels`), because the labels
  are protocol between fleet components, not between the fleet and the forge.

## Seam

`:forge_client` (an OPTS keyword, `Keyword.get(opts, :forge_client, …)`) injects the client module.
It is a TEST seam: `Fleet.MCP` declares a plain compile dep on this domain (`lib/fleet/mcp.ex`),
so the seam buys stub injection, not a boundary crossing. The behaviour the stubs implement is
`Fleet.MCP.PodTools.Delegation.ForgeClient` (13 callbacks), whose default is this client and
whose `conforming/2` check is what keeps a stub honest.

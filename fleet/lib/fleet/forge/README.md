# Fleet.Forge — domain card

**Date**: 2026-08-09
**Last revised**: 2026-08-09
**Status**: active — the fleet's single HTTP exit toward its git forge
**Referenced by**: `lib/fleet/pilot/README.md` (the driver that used to contain it)

Everything that speaks to the forge over the wire: issues, labels, comments, pulls, reviews,
merges, files, and the branch/PR vocabulary those calls are built from.

**This file is a map, not the contract.** Each module owns its contract in its own `@moduledoc` —
read those (`h Fleet.Forge.Client` in IEx). Nothing here is restated, only pointed at.

## Why it is a domain and not a corner of `Fleet.Pilot`

It lived under the pilot, and the cost was visible in one line of the pilot's boundary: `Req` and
`Req.Response` were declared there. The business domain imported the HTTP library, so *"a single
forge HTTP exit"* was a **convention** — true only as long as nobody added a call somewhere else in
2 400 lines of driver. Here that invariant is **compiled**: the wire libraries are fenced to this
boundary and a reference from anywhere else does not build.

It was never derived from the pilot either, only placed there. Outside its own modules it touched
the pilot three times (`WriteSpacing`, `Opts`, and prose about `ProjectOnboard`); what it actually
depends on is `Fleet.Labels`, `Fleet.Workflow` and `Fleet.Credentials`. The extraction moved the
two real attachments to where they belong rather than dragging them along:

- `Fleet.Forge.WriteSpacing` — the gap between distinct forge writes. Its subject IS the forge; the
  pilot called it exactly where the pilot writes to the forge.
- `Fleet.Opts` — two pure keyword helpers, no deps, no subject: foundation.

## Modules

- `Fleet.Forge` — facade, boundary anchor, and the authority on the Finch pool name
  (`finch_name/0`: the supervisor that starts the pool and the transport that sends through it must
  not each hold a literal).
- `Fleet.Forge.Client` — the surface the rest of the fleet calls. Sub-modules
  `{Transport, UrlSafe, Jury, Repo, Files}`.
- `Fleet.Forge.Client.Transport` — the ONLY module that performs HTTP. Pagination, retries, error
  shapes.
- `Fleet.Forge.Protocol` — pure wire vocabulary (branch names, PR titles, step_run formats). The
  LOCK-label vocabulary is not here: it lives at the foundation (`Fleet.Labels`), because the labels
  are protocol between fleet components, not between the fleet and the forge.

## Seam

`:forge_client` (app env `:fleet_pilot` / `:fleet_mcp`) injects the client module — test stubs, and
the upward `mcp → pilot` runtime seam this extraction is expected to retire (MCP can now declare a
plain compile dep on this domain). **Not retired yet**: the behaviour and its 12 callbacks still
live in `Fleet.MCP.PodTools.Delegation.ForgeClient`, and removing them is a separate gesture with
its own test consequences.

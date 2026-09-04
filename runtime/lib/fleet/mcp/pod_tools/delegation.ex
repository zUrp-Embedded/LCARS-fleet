defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Architect's "forge delegation" domain + authorization gate — extracted from
  `Fleet.MCP.PodTools` (which keeps the `handle_tool_call/3` routing table and the MCP content
  format). Named after the code's vocabulary ("DELEGATION channel", `delegation_org`,
  `delegation_target`): these tools form the channel through which the architect delegates work to
  the fleet and tracks it.

  CE MODULE NE PORTE AUCUNE FONCTION : il porte le contrat de la famille — les deux gates, les
  seams, et la carte des canaux ci-dessous.

  ⚠ NO TOOL LIST HERE, for the reason `Fleet.MCP.PodTools` states about its own: the authority is
  the `deftool` set over there, read BY THE AST by five walls (`mcp.tools_gated`,
  `mcp.tool_effects`, `mcp.wire_inputschema`, `mcp.seam_surface_declared`,
  `mcp.required_for_real_backend`). Ce qui suit nomme les MODULES de cette famille, pas les outils
  d'un autre fichier : chaque canal porte son contrat dans son propre `@moduledoc`.

  ## La famille

    * `Delegation.Issues` — DELEGATION / TRACKING / READ : poser un ticket pour le poller, puis
      relire ce qu'il est devenu.
    * `Delegation.IssuePR` — retrouver la PR d'une issue, et refuser un geste dont l'etat cible
      ne peut pas etre etabli.
    * `Delegation.Dependencies` — les aretes de dependance entre tickets.
    * `Delegation.Retirement` — sortir un ticket : retire, supersede, ou balaye avec le projet.
    * `Delegation.Portfolio` — ONBOARDING : les verbes du portefeuille (create / import / open /
      close / delete / adopt) et les verbes de carte.
    * `Delegation.Deposits` — DEPOT : publier un projet, et le lien vers la forge d'origine.
    * `Delegation.Escalations` — ESCALATION : la boite de l'architecte.
    * `Delegation.Scratchpad` — SCRATCHPAD : les notes courantes sur un projet.
    * `Delegation.Toolchain` — TOOLCHAIN : la demande de changement sur l'outillage de la fleet.
    * `Delegation.Gate` — le socle : les deux gates, l'identite, la conformance de seam.
    * `Delegation.Render` — les deux ecritures de rendu partagees par tous les canaux.
    * `Delegation.Workshop` — la racine de la face atelier et le workspace d'un lot.

  Les cinq behaviours de seam (`ForgeClient`, `EscalationForge`, `DependencyForge`, `ForgeWriter`,
  `ProjectOnboard`) vivent dans la meme famille et portent chacun leur contrat.

  ## Two server-side gates

  The barrier is server-side: the role is resolved from the CHANNEL identity (`state.pod_id`, carried by
  the socket acceptor — NOT a wire field), then asked for a CAPABILITY. Two heads, two capabilities,
  and neither gate knows a role name — which role carries which is the catalogue's business:

    * **ONBOARDING gate** (`Gate.require_onboarder/1`) — the PORTFOLIO head. Admits any role
      carrying `onboarder`. Refusal → `:forbidden_not_onboarder`.
    * **DELEGATION gate** (`Gate.require_architect/1`) — the per-project head. Admits the role
      carrying `project_delegate`, and additionally requires a repo binding — delegating outside a
      project is not a thing. Refusal → `:forbidden_not_architect`.

  Which head a given tool sits behind is not listed here either: its function calls one of the two
  in its own body, first thing, and that call is the answer.

  The two are DISJOINT in the bundled catalogue and that is a catalogue fact, not a law here: enrolling
  a project happens from outside any project, delegating happens inside one. A role declaring a
  capability whose tools it does not carry is caught by `roles.capabilities_exercisable`, because such
  a declaration reads as a granted permission and grants nothing.

  A pod whose role carries neither, a nil/unknown role, or a pod absent from the registry → REFUSAL on
  both. Fail-closed end to end: no case falls back onto an authorized access. (The tool-visibility
  filter is SERVER-side too — the acceptor's `tools/list` lists only this role's tools, F-C138; the
  bridge forwards blindly. That filter is a second barrier; the authorization lives HERE.)

  Every function takes the MCP `state` as its last argument and reads ONLY `pod_id` from it (the gate) —
  never an identity from the wire arguments.

  ## Seams (app-env `:lcars_fleet`, keys prefixed `mcp_*`) — test injection, not boundary crossings

  `Fleet.Forge` and `Fleet.Project` are compile deps of this domain (`lib/fleet/mcp.ex`); the seams
  exist so a test injects a stub, and each behaviour's `Gate.conforming/2` keeps a stub honest.

    * `:mcp_forge_client` (default `Fleet.Forge.Client`). FOUR declared behaviours over the SAME
      seam module (DR-012): `Delegation.ForgeClient` (DELEGATION/TRACKING surface),
      `Delegation.EscalationForge` (ESCALATION surface), `Delegation.DependencyForge` (the edges)
      and `Delegation.ForgeWriter` (branch/file/PR) — each an inspectable contract, resolved
      through `ForgeClient.resolved/0`.
    * `:mcp_project_onboard` (default `Fleet.Project.Onboard`) — onboarding sequence. CONTRACT =
      behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
    * `:mcp_pod_resolver` (default `PodResolver.default/1` over `Fleet.Spawner.pod_info/1`) —
      resolution of the pod's role and repo binding.
    * `:mcp_pod_reaper` (default `Fleet.Pilot.PodReaper`) — the one UPWARD seam: MCP may not
      reference Pilot.

  The forge org of an onboarded project is the `catalogue` argument (`Gate.resolve_org/1`),
  required and never inferred: the poller discovers on installed catalogue orgs only.
  """
end

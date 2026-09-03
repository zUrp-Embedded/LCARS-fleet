defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Architect's "forge delegation" domain + authorization gate — extracted from
  `Fleet.MCP.PodTools` (which keeps the `handle_tool_call/3` routing table and the
  MCP content format). CE MODULE NE PORTE PLUS DE FONCTION : il porte le contrat de la famille
  — les deux gates, les seams, et la carte des canaux ci-dessous. Named after the code's vocabulary ("DELEGATION channel",
  `delegation_org`, `delegation_target`): these tools form the channel through which
  the architect delegates work to the fleet and tracks it.

  ## Les canaux — un module chacun

    * `Delegation.Issues` — DELEGATION / TRACKING / READ : poser un ticket pour le poller, puis
      relire ce qu'il est devenu.
    * `Delegation.IssueBody` — ce qui compose le CORPS d'un ticket (pointeur, criteres, lot,
      supersede, marqueur d'idempotence), assemble avant que la forge ne soit touchee.
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
    * `Delegation.Render` / `Delegation.Workshop` — les deux ecritures de rendu partagees, et la
      racine de la face atelier.

  Les cinq behaviours de seam (`ForgeClient`, `EscalationForge`, `DependencyForge`, `ForgeWriter`,
  `ProjectOnboard`) vivent dans la meme famille et portent chacun leur contrat.

  ## Two server-side gates (reorg 2026-07-19, cf. DESIGN-carte-des-roles §9)

  The barrier is server-side: the role is resolved from the CHANNEL identity (`state.pod_id`, carried by
  the socket acceptor — NOT a wire field), then asked for a CAPABILITY. Two heads, two capabilities,
  and neither gate knows a role name — which role carries which is the catalogue's business:

    * **ONBOARDING gate** (`require_onboarder/1`) — `project_create` / `project_install` /
      `project_open` / `project_close` / `project_delete` / `project_revise_card` /
      `card_list` / `catalogue_list`: the PORTFOLIO head. Admits any role carrying `onboarder`.
      Refusal → `:forbidden_not_onboarder`.
    * **DELEGATION gate** (`require_architect/1`) — `issue_create` / `issue_status` / `escalation_list` /
      `issue_list` / `issue_get` / `issue_comment`: the per-project head. Admits the role carrying
      `project_delegate`, and additionally requires a repo binding — delegating outside a project is
      not a thing. Refusal → `:forbidden_not_architect`.

  The two are DISJOINT in the bundled catalogue and that is a catalogue fact, not a law here: enrolling
  a project happens from outside any project, delegating happens inside one. A role declaring a
  capability whose tools it does not carry is caught by `roles.capabilities_exercisable`, because such
  a declaration reads as a granted permission and grants nothing.

  A pod whose role carries neither, a nil/unknown role, or a pod absent from the registry → REFUSAL on
  both. Fail-closed end to end: no case falls back onto an authorized access. (The tool-visibility filter
  now lives SERVER-side — the acceptor's `tools/list` lists only this role's tools, F-C138; the bridge
  forwards blindly. A UX convenience, but the authorization has always lived HERE.)

  Every function takes the MCP `state` as its last argument and reads ONLY `pod_id` from it (the gate) —
  never an identity from the wire arguments.

  ## Seams (app-env `:lcars_fleet`, keys prefixed `mcp_*`)

    * `:forge_client` (default `Fleet.Forge.Client`) — forge client, runtime
      dispatch (no compile-time dep on fleet_pilot). TWO declared behaviours over the SAME seam module
      (DR-012): `Delegation.ForgeClient` (DELEGATION/TRACKING surface: create_issue/add_label/get_issue/…)
      and `Delegation.EscalationForge` (ESCALATION surface: list_org_repos/list_open_issues/list_comments/
      post_comment) — each an inspectable contract with its own `resolved/0`, no hidden ad-hoc op list.
    * `:project_onboard` (default `Fleet.Project.Onboard`) — onboarding
      sequence. CONTRACT = behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
    * `:pod_resolver` (default runtime dispatch `Fleet.Spawner.pod_info/1`) — resolution
      of the pod's role.
    * `:delegation_org` — forge org of onboarded projects. OPTIONAL override: by default the org
      is the one the poller DISCOVERS on (`:lcars_fleet, :pilot_fleet_org`, default `"fleet"`), because
      onboarding into an org nobody scans is a silently dead rail.
  """
end

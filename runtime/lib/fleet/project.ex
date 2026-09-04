defmodule Fleet.Project do
  @moduledoc """
  Project-lifecycle domain — what a PROJECT is, outside the step rail that drives it.

  Boundary anchor; the contract lives in each module's `@moduledoc`: `Fleet.Project.Onboard`
  (create / import / adopt / open / close / delete, and the card revision), `Fleet.Project.Roles`
  (which role plays which part on a given project), `Fleet.Project.Declaration` (the engraved
  criticality declaration), `Fleet.Project.Architect` (the per-project architect's identity and
  its ensure-spawn), `Fleet.Project.WorktreeSync` (realigning a face's host clone after a merge),
  `Fleet.Project.GitOps` (the git verbs those need).

  ## Two natures, and why they are not one facade

  `Fleet.Pilot` opens with *"Reactive: Poller tick + Bus consumers — nobody calls into pilot except
  the api and the operator"*. That is true of the rail and false here: onboarding is called
  IMPERATIVELY, from outside, on demand — an architect asks for a project and waits for the answer.
  One facade over both would describe one nature and leave the other undocumented in the one place
  a reader looks first.

  ## Why the whole cluster and not the one file

  `Onboard` alone does not come out: it reaches four other modules (`Declaration`, `Architect`,
  `WorktreeSync`, `Roles`) and `GitOps` — and `Roles` and `Declaration` call EACH OTHER. Pulling
  one out means duplicating primitives or leaving a cycle across a boundary, which does not
  compile.

  So the cut follows where the code actually separates: these seven modules have **zero** call into
  the rail (`Poller`, `StepDispatcher`, `StepRunConsumer`, `StepRunCompleter`, `MergeAndPromote`,
  `IncidentRegistry`, `ReviewLifecycle`, `ArchWake`, `ArchFeed` — measured). The traffic is entirely
  the other way: the rail asks this domain who the jury is, what the card says, where the architect
  lives. `Roles`/`Declaration` calling each other is fine INSIDE one boundary — it is only a problem
  with a line drawn between them.

  ## The `:project_onboard` seam is a TEST seam

  `Fleet.MCP` declares `Fleet.Project` in its boundary deps (`lib/fleet/mcp.ex`), so the call is
  an ordinary compile-checked edge. The seam stays because it is how a test injects a stub: the
  behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard` carries 13 callbacks, and its
  `conforming/2` wrapper is what keeps a stub from lying about the contract.
  """

  # COMPILED domain boundary. `deps` is the measured graph: everything here is what a project's
  # lifecycle needs to exist, and none of it is the rail that drives the project afterwards.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Opts,
      Fleet.Labels,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.EventRouter,
      Fleet.CapProfile,
      Fleet.Credentials,
      Fleet.Spawner,
      Fleet.Workflow,
      Fleet.Forge,
      Fleet.ReceptionFilter,
      Fleet.Conflict,
      # Ce domaine porte des portes RELEASE (`eval_reconcile`, `eval_migrate`) dont stdout est lu
      # par un appelant shell. La regle qui rend cette sortie fiable est une primitive de
      # foundation, partagee avec les portes de `Fleet.Application` — la recopier ferait deux
      # exemplaires d'un meme contrat dans deux domaines.
      Fleet.ReleaseDoor
    ],
    exports: [
      Onboard,
      Onboard.Scaffold,
      Roles,
      Declaration,
      Architect,
      WorktreeSync,
      GitOps
    ]
end

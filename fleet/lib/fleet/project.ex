defmodule Fleet.Project do
  @moduledoc """
  Project-lifecycle domain — what a PROJECT is, outside the step rail that drives it.

  Boundary anchor; the contract lives in each module's `@moduledoc`: `Fleet.Project.Onboard`
  (create / import / adopt / open / close / delete, and the card revision), `Fleet.Project.Roles`
  (which role plays which part on a given project), `Fleet.Project.Intensity` (the engraved
  criticality declaration), `Fleet.Project.Architect` (the per-project architect's identity and
  its ensure-spawn), `Fleet.Project.WorktreeSync` (realigning a face's host clone after a merge),
  `Fleet.Project.GitOps` (the git verbs those need).

  ## Two natures were living under one facade, and only one was described

  `Fleet.Pilot` opens with *"Reactive: Poller tick + Bus consumers — nobody calls into pilot except
  the api and the operator"*. That is true of the rail and false of what is now here: onboarding is
  called IMPERATIVELY, from outside, on demand — an architect asks for a project and waits for the
  answer. A facade that describes one of its two natures leaves the other undocumented in the one
  place a reader looks first.

  ## Why the whole cluster and not the one file

  Extracting `Onboard` alone was the plan. Measured, it reaches four other pilot modules
  (`Intensity`, `Architect`, `WorktreeSync`, `Roles`) and `GitOps` — and `Roles` and `Intensity`
  call EACH OTHER. Pulling one out would have meant duplicating primitives or leaving a cycle
  across a boundary, which does not compile.

  So the cut follows where the code actually separates: these seven modules have **zero** call into
  the rail (`Poller`, `StepDispatcher`, `StepRunConsumer`, `StepRunCompleter`, `GatekeeperSeal`,
  `IncidentRegistry`, `ReviewLifecycle`, `ArchWake`, `ArchFeed` — measured at extraction). The
  traffic is entirely the other way: the rail asks this domain who the jury is, what the card says,
  where the architect lives. `Roles`/`Intensity` calling each other is fine INSIDE one boundary —
  it was only a problem while the line was drawn between them.

  ## What it MAKES POSSIBLE — and what is not done yet

  The `:project_onboard` seam exists for ONE reason: `fleet_pilot` sits above `fleet_mcp`, so
  `mcp → pilot` is an upward edge boundary refuses, and the module has to be resolved at runtime
  through app-env. This domain sits below both, so that edge could now be an ordinary compile dep
  the compiler checks — where a seam can only be checked by a test that remembered to.

  ⚠ **The seam is still there.** Removing it is a gesture of its own: the behaviour carries ten
  callbacks and eight call sites, and its `conforming/2` wrapper is what keeps a test stub from
  lying about the contract. Deleting it without replacing that check would trade a real guarantee
  for a tidier graph. The extraction is the precondition, not the removal.
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
      Intensity,
      Architect,
      WorktreeSync,
      GitOps,
      TemplateSync
    ]
end

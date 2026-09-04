# Fleet.Project — domain card

**Date**: 2026-09-04
**Last revised**: 2026-09-04
**Status**: active — project lifecycle: what a PROJECT is, outside the step rail that drives it
**Referenced by**: —

Onboarding verbs (create / import / adopt / deposit / open / close / delete, card revision, CI rail
reset), the per-project architect, the engraved criticality declaration, the structural roles a
catalogue resolves, and the realignment of the three local faces after a merge.

**This file is a map, not the contract.** Each module owns its contract in its own `@moduledoc` —
read those (`h Fleet.Project.Onboard` in IEx, or `lib/`). Nothing here is restated, only pointed at.

## Modules

- `Fleet.Project` — facade, boundary anchor; explains why the cluster is one domain and why the
  `:project_onboard` seam is a TEST seam (`Fleet.MCP` has the compile dep)
- `Fleet.Project.Onboard` — the seam surface: re-exports the 13 verbs the
  `Delegation.ProjectOnboard` behaviour names plus the `eval_*` doors a shell script names; the
  common admission (`admit/3`, `required_org/1`, `catalogue_not_installed/1`)
- `Fleet.Project.Onboard.Create` — `onboard/2` (creates the repo) and `import/2` (adopts a repo
  already in a catalogue org), with compensation on both exits
- `Fleet.Project.Onboard.Adopt` — `adopt_project/2`: publishes a disk-only project, per-face
  classification (built vs pre-existing) drives the compensation
- `Fleet.Project.Onboard.Import` — `import_external/3` (GitHub/GitLab, adoption gate),
  `import_deposit/3` (a human's personal space → a catalogue org), `deposit_candidates/2`
- `Fleet.Project.Onboard.Lifecycle` — `open`, `list_projects`, `list_stoppable_issues`,
  `close_project` (parked marker issue = the closed state), `delete_project` (proof-based removal)
- `Fleet.Project.Onboard.Card` — `revise_card/2` and `reset_ci_rail/2` through a system-only
  protection lift on `main`
- `Fleet.Project.Onboard.Migration` — `migrate/3` (forge transfer + local repoint),
  `reconcile/2` and its release doors `eval_migrate/2`, `eval_reconcile/1`,
  `reconcile_main_protection/2`
- `Fleet.Project.Onboard.Faces` — the three local faces (`code`, `ops`, `workshop`) and their git
  gestures; `protect_main/2` and `main_status_check_contexts/0` (the `CI / *` glob authority)
- `Fleet.Project.Onboard.Repo` — what onboarding asks the FORGE: org, repo, labels, URL, origin;
  the forge seams `repo_mod/1`, `files_mod/1`
- `Fleet.Project.Onboard.Refute` — refuses to treat a catalogue's STORE as a project
- `Fleet.Project.Onboard.Scaffold` — projection of `priv/catalogue/project_template` (own
  catalogue first, bundled fallback announced); CI workflows added or reset
- `Fleet.Project.Declaration` — single owner of `<project>/.lcars.json` (`declaration`):
  written at onboarding, read at the workflow-map burn; `declarable_card/3`
- `Fleet.Project.Roles` — the structural roles RESOLVED by capability (producer, gatekeeper,
  conflict resolver, project delegate), the card's jury / CI policy / verdict policy
- `Fleet.Project.Architect` — pod-id authority of the per-project architect, idempotent
  `ensure/2`, cheap `ensure_alive/2` for the poller's keeper pass
- `Fleet.Project.WorktreeSync` — serialized post-merge realignment of the face clones (reset on
  `code`, rebase with autostash on the writer faces); `fetch_issue_refs/3`
- `Fleet.Project.GitOps` — bounded `Shell.git` adapter: forge auth in env, commit identity,
  typed failures
- `Fleet.Project.Incidents` — producer of `project.card_failed` / `project.declaration_invalid`
  on the bus (downward, never an upward seam)

## Config & deps
- Knobs `:lcars_fleet, :pilot_producer_role`, `:pilot_gatekeeper_role`,
  `:pilot_conflict_resolver_role`, `:pilot_project_delegate_role` — overrides read by `Roles`
  before capability resolution (they keep their `pilot_` prefix: renaming a key at the edge of a
  move is how an operator's env file stops being read).
- Forge access: `:lcars_fleet, :pilot_forge` (`base_url`), read by `Onboard.Repo.repo_url/2` and
  by the forge client the verbs call.
- Opts seams (tests): `:forge_repo`, `:forge_files`, `:forge_users`, `:forge_issues`,
  `:ensure_labels` (forge), `:spawner`, `:forge_client`, `:loader` (`Architect`),
  `:ensure_architect`, `:incident_fun`, `:sync_showcase`, `:url_gate`, and the face roots
  `:code_root` / `:ops_root` / `:workshop_root` (defaults from `Fleet.Layout`).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/project.ex`).

defmodule Fleet.Project.Architect do
  @moduledoc """
  The PER-PROJECT architect — pod-id AUTHORITY + idempotent `ensure/2`. ONE architect per repo, and
  not one for the fleet: project-bound identity (numeric repo id in its deterministic UUID → a
  stable Desktop slot per project), spawned ON-OPEN (create/import/open) and ON-DEMAND (escalation
  rail).

  ## No clone — the three faces, and one of them only in reading

  The arch is NOT a producer of code: a work clone (frozen at spawn, forge-blind so never fetched)
  is the wrong window for it. Its world = three DYNAMIC mounts derived from the project name, one
  per face:

    * `/home/projects/<name>` **RO** — read the code to frame briefs (the host-side dir, the same
      view the human has). Read-only and HARD: a typo fixed by hand here is a change nobody
      reviewed, and an actor with a pen uses it where nobody is looking;
    * `/home/projects.workshop/<name>` **RW** — this IS its producing face. The documentation is written
      here, with the human, at the terminal — which is the bulk of what actually happens — and a
      scribe enriches it through the ordinary pipeline.

      A DRAFT SPACE, AND DELIBERATELY SO (user arbitration): only the `scratch` tool pushes this
      face (notes, an orphan branch that ships nothing), and nothing written here enters the
      project as-is. What the human and the arch produce
      together is MATTER, not a deliverable — a scribe ticket carries it through the ordinary
      pipeline, judged and sealed like any other, even when the pass is only an eval. The pod is
      told this in its own words, because a pod that believes it published fills the gap the same
      way one that cannot see its deliverable does;
    * `/home/projects.ops/<name>` **RO** — the record: briefs, verdicts, provenance. The arch is
      the ONLY pod that mounts it, and reading it is its function — following the work and
      reporting it to the human. **Read-only, and the mode is the point**: it is the party being
      judged, and a judged party that can rewrite the tree it is judged on is not judged at all.

  The in-flight work view (branches, PRs) is the FORGE via its MCP tools (`issue_status`),
  never git — neither a frozen clone nor a mount shows branches born after spawn.

  ## Idempotent ensure (open = relaunch = crash-recovery)

  `ensure/2` is the SINGLE entry for "this project must have its architect": deterministic
  `pod_id` (`<delegate-role>-<name>`) → alive = `{:already_started}` no-op; dead/never = fresh spawn
  (context back via the slot sidecar). Callers: `Fleet.Project.Onboard` (on-open, best-effort),
  `ArchWake` (on-demand when an escalation arrives), the `project_open` tool (human-driven
  relaunch). A project NOT on the machine (`/home/projects/<name>` absent) is REFUSED
  (`:not_onboarded`) — an architect without its project world would be an empty box.

  ## Seams (keyword opts, defaults = real)

    * `:spawner` — default `Fleet.Spawner` (the `spawn_pod/3` provider).
    * `:forge_client` — default `Fleet.Forge.Client` (numeric repo id for the UUID).
    * `:loader` — default `Fleet.CapProfile` (load + compose with default modops).
    * `:code_root` / `:ops_root` / `:workshop_root` — FS roots (defaults `Fleet.Layout`), same
      keys as `Fleet.Project.Onboard` (the onboard opts thread through unchanged).
  """

  require Logger

  alias Fleet.Layout

  @doc """
  THE pod-id authority for a project's delegate: `<delegate-role>-<name>` (`name` = the repo's name
  segment). Accepts a `owner/name` full_name or a bare name. Every consumer (ArchWake, ArchFeed,
  open_project) derives through here — never a rebuilt literal.

  ⚠ THE PREFIX IS RESOLVED, NEVER THE LITERAL `architect-`. Closing the literals of role RESOLUTION
  alone leaves this one: a catalogue naming its delegate `tech-lead` then gets the right role and a
  pod called `architect-<project>`, while `CLAUDE.md` and that same pod's SP both read `tech-lead`.
  The operator sees the wrong name in `lcars list`, in the logs and in tmux; an agent reading that
  trace sees a role its catalogue does not have. *« Tout ce qu'il voit passer EST du poison si c'est
  pas instantanement vrai. »*

  Deterministic per project and NOT `permanent-*`: the delegate is not a fleet permanent
  (PermanentWarden must not respawn it — the escalation rail and the open verbs do, on demand).

  It RESOLVES, so it can raise on a catalogue with zero or several delegates — and that is not a new
  failure mode: since the delegate joined `resolve_structural_roles!/0`, such a catalogue does not
  reach readiness at all. The boot guard is what makes this call total in a running fleet.
  """
  @spec pod_id_for(String.t()) :: String.t()
  def pod_id_for(repo_or_name) when is_binary(repo_or_name),
    do:
      Fleet.Project.Roles.project_delegate_role() <>
        "-" <> Layout.project_name(repo_or_name)

  @doc """
  Ensures the architect of `repo` is up, CHEAPLY when it already is — the form a periodic keeper
  can afford to call on every project on every tick.

  `ensure/2` is idempotent but not free: it reads the repo id off the forge and resolves the
  cap-profile BEFORE discovering `{:already_started, _}` at the spawn. Paid once per project per
  tick that is a real cost for an answer that is almost always "it is there". This asks the cheap
  question first — does its tmux session exist — and only pays the rest when the answer is no.

  WHY A KEEPER AT ALL, AND IT IS NOT AN OPTIMISATION. The architect declares `lifetime_scope:
  forever`, and the two other ensure sites (project-open, escalation wake) cannot hold it: a fleet
  restart or a crash would leave the project with no architect until something happens to need
  one. A human who opens their project's terminal in between finds nothing there — and the human is
  the one interlocutor that cannot be scheduled. `forever` has to be someone's job.

  The liveness read is the TMUX SESSION, not the Registry: a registered pod whose session is gone is
  a corpse the Registry still answers for, and the fleet then re-briefs nothing for as long as
  nobody looks.

  ## It KEEPS, it never CREATES — and that distinction is the whole point

  A keeper that also creates is not a keeper, it is a second onboarding path with no human in it.
  Its only caller is the poller, which iterates the ORG SCAN: every repo of the fleet org, whether
  or not the human running this fleet ever asked for it. On a box with two humans, one who created
  a single project ends up running a delegate for a project SOMEBODY ELSE created and that he never
  opened — as many architects as the org has repos, most of them wanted by nobody.

  The org scan cannot answer "did MY human ask for this". Nothing on the forge records the asker,
  and the ops directory that gated this call is SHARED (`/home/projects.ops/<name>`) — so its
  presence proves *someone* onboarded, never *this* human. The test was only ever valid one way:
  absence proves nobody asked, presence proves nothing.

  So the record consulted here is the one the box already keeps, per human, on disk: the pod
  snapshot written at spawn, under the running human's own home. It exists because `ensure/2` ran
  for THIS human — which happens on the four deliberate verbs (`create`, `import`, `open`,
  `project_adopt`) and nowhere else. A fleet restart or a crash leaves it in place, which is
  exactly the case this keeper exists for; a deliberate kill clears it, and then not resurrecting
  is the correct answer.
  """
  @spec ensure_alive(String.t(), keyword()) ::
          {:ok, String.t() | :alive | :not_ours} | {:error, term()}
  def ensure_alive(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    tmux = Keyword.get(opts, :pod_tmux, Fleet.Spawner.PodTmux)
    recorded? = Keyword.get(opts, :on_record, &on_record?/2)
    pod_id = pod_id_for(repo)

    cond do
      # The cheapest question, and the one that decides whether this fleet has any business here:
      # one `File.dir?` on a local path, before any tmux call and long before any forge call.
      not recorded?.(repo, opts) -> {:ok, :not_ours}
      tmux.alive?(pod_id) -> {:ok, :alive}
      true -> ensure(repo, opts)
    end
  end

  @doc """
  Whether THIS box holds an architect on record for `repo` — the durable pod snapshot the spawner
  writes under the running human's home. Per-human by construction: the BEAM runs as the human, so
  the state root resolves in their own `~/.lcars`, and no other human's record is reachable from it.

  Silent `false` on an unreadable root: a keeper that resurrects on a failed read would spawn
  exactly the pods this predicate exists to refuse.
  """
  @spec on_record?(String.t(), keyword()) :: boolean()
  def on_record?(repo, opts \\ []) when is_binary(repo) and is_list(opts),
    do: Fleet.Spawner.snapshot_on_record?(pod_id_for(repo), opts)

  @doc """
  Ensures the per-project architect of `repo` (`owner/name`) is up — idempotent (alive → no-op).
  `{:ok, pod_id}` | `{:error, reason}`. Best-effort at every call site: a failure is logged and
  never fatal to the caller (the project exists; ensure can be retried on the next trigger).
  """
  @spec ensure(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    forge_opts = Keyword.take(opts, [:token, :base_url])

    name = Layout.project_name(repo)
    proj_dir = Path.join(Keyword.get(opts, :code_root, Layout.code_root()), name)
    work_dir = Path.join(Keyword.get(opts, :ops_root, Layout.ops_root()), name)
    doc_dir = Path.join(Keyword.get(opts, :workshop_root, Layout.workshop_root()), name)
    repo_id_result = Fleet.Forge.repo_id(forge, repo, forge_opts)

    cond do
      # EVERY mounted face must exist, because bwrap binds STRICTLY: a missing source is not an
      # empty mount, it is a launcher that dies. Checking only the code face let a project whose
      # doc face never landed pass this door and fail at the bind, with an error naming bwrap
      # instead of the onboarding that never completed.
      missing = Enum.find([proj_dir, work_dir, doc_dir], &(not File.dir?(&1))) ->
        {:error, {:not_onboarded, missing}}

      match?({:error, _}, repo_id_result) ->
        {:error, reason} = repo_id_result

        Logger.error(
          "Project.Architect: repo id unresolved for #{repo} (#{inspect(reason)}) — arch NOT ensured"
        )

        {:error, {:repo_id_unresolved, repo, reason}}

      true ->
        {:ok, repo_id} = repo_id_result

        # The role is RESOLVED by the `project_delegate` capability, never named — same source as
        # the gate that admits the call (`Delegation.require_architect/1`, B-03). Naming it here
        # would gate correctly on a renamed delegate and then ensure a role the catalogue lacks.
        case Fleet.CapProfile.resolve(loader, Fleet.Project.Roles.project_delegate_role()) do
          {:ok, cap} ->
            pod_id = pod_id_for(name)

            spawn_opts = [
              pod_id: pod_id,
              # The repo the pod is BOUND to — exposed by `pod_info` so the MCP delegation tools
              # resolve "the project" from the channel identity (the arch never names it).
              repo: repo,
              repo_id: repo_id,
              rc_name: Layout.pod_label(name, "architect"),
              project_slug: name,
              # The arch's world (moduledoc): live host dirs, not a frozen clone. ONE writable
              # face and it is `workshop` — the face it produces on. `ops` is the record it is judged
              # against, so it reads it and cannot touch it; `code` goes through the pipeline like
              # everyone else's.
              #
              # ORDER MATTERS HERE. `pod_cwd/3` falls back to the FIRST rw mount for a pod with no
              # project remap, and `pod_mounts_env/3` keeps the FIRST occurrence of a path. Putting
              # the two read-only faces ahead of the writable one is therefore not cosmetic.
              mounts: [
                %{"mode" => "ro", "path" => proj_dir},
                %{"mode" => "ro", "path" => work_dir},
                %{"mode" => "rw", "path" => doc_dir}
              ]
            ]

            case spawner.spawn_pod(cap, pod_id, spawn_opts) do
              {:ok, _pid} ->
                Logger.info(
                  "Project.Architect: architect ensured for #{repo} (pod #{pod_id}, spawned)"
                )

                {:ok, pod_id}

              {:error, {:already_started, _pid}} ->
                {:ok, pod_id}

              {:error, reason} = err ->
                Logger.error(
                  "Project.Architect: architect spawn for #{repo} FAILED (#{inspect(reason)}) — " <>
                    "retried on the next open/escalation trigger"
                )

                err
            end

          {:error, reason} = err ->
            Logger.error(
              "Project.Architect: architect cap-profile load/compose failed (#{inspect(reason)})"
            )

            err
        end
    end
  end
end

defmodule Fleet.Pilot.ProjectOnboard do
  @moduledoc """
  Onboarding of a project (Rail 1 firmware-as-a-service, 2026-06-14): « idea → the project exists ».

  Replicates the dual-dir architecture of LCARS itself (one repo, **two worktrees**):

    * `/home/projects/<name>`       → worktree branch `main`     (the deliverable, push origin)
    * `/home/projects.work/<name>`  → worktree branch `work/ops` (orphan: plans, backlog, ops)

  It is a **mechanical rail** (structural compliance): the arch *triggers* via the MCP
  tool `create_project`, the SYSTEM *executes* this deterministic sequence — the arch never types git.

  Sequence (F-C084: FAIL-LOUD if the repo already exists on the forge — onboard CREATES, it must NOT
  scaffold over a pre-existing `main`; `import/2` is the safe adopt-an-existing-repo path — and fails
  clearly if the local folder already exists):

    1. `ForgeClient.create_repo` (org `fleet`, `auto_init` → `main` cloneable) — 409 ⇒ `{:error, {:repo_already_exists, _}}`
    2. `git clone --branch main` → `/home/projects/<name>`
    3. scaffold `main` (README, .gitignore, .editorconfig, docs/spec.md)
    4. commit (author=`lcars-system`, committer=git config runtime = the human) + push `main`
    5. `git worktree add --orphan -b work/ops` → `/home/projects.work/<name>`
    6. scaffold `work/ops` (backlog.md, scratchpad.md, plans/)
    7. commit + push `-u work/ops`

  Identity (decision 2026-06-14 — onboarding is an act of system INFRA, not creative work):
  `author=lcars-system` (the SYSTEM generates the scaffold from templates; the arch writes no file,
  it **relays** `name`+`pitch` — it is transparent in the git attribution, its trace lives in the request),
  `committer`=the human (git config runtime = **the user who initiated the project → traced**),
  `pusher`=`lcars-system` (`ForgeAuth.git_env`, fleet-wide owner). All avatared (emails → Gitea accounts).
  No GenServer (Iron Law — I/O orchestration without shared state).

  ⚠ CROSS CONTRACT (seam `fleet_mcp`): `onboard/2` is the REAL impl (default) of the behaviour
  `Fleet.MCP.PodTools.Delegation.ProjectOnboard`. It CANNOT be adopted as `@behaviour`:
  `fleet_pilot` does not depend on `fleet_mcp` and the compile reference would create a new edge
  (`allowed_graph.yaml` would go red). Duck-typed impl — any evolution of the signature/of the
  `result()` shape MUST be reflected on the behaviour's `@callback` (and vice-versa).
  """

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.GitOps
  alias Fleet.Pilot.Roles

  # Content + writing of the scaffold (pure templates, dual-dir main / work-ops) — extracted:
  # no dependency on the orchestration, onboard calls it at the right moments of its sequence.
  alias Fleet.Pilot.ProjectOnboard.Scaffold

  require Logger

  # H1/H3: derived from the single authority of the container layout (Fleet.Layout, R0).
  @projects_root Fleet.Layout.projects_root()
  @work_root Fleet.Layout.work_root()
  # onboarding author = the system (it GENERATES the scaffold) — not the arch (mere relay), not the user
  # (wrote nothing). committer = the human (git config) traces who initiated (2026-06-14).
  # System identity: SINGLE AUTHORITY = Fleet.Credentials.ForgeIdentity.system_identity/0
  # (H2 2026-07-04: the name/email was retyped here hardcoded — a divergence in the making with the gate).
  defp onboard_author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @type result :: %{repo: String.t(), project_dir: Path.t(), work_dir: Path.t()}

  @doc """
  Onboard the project `name` (kebab-case slug). `opts`:

    * `:org`           — forge org (default `"fleet"`)
    * `:description`   — repo description (default `""`)
    * `:pitch`         — pitch phrase (README/spec scaffold; default = description)
    * `:projects_root` / `:work_root` — FS roots (defaults: `/home/projects`, `/home/projects.work`)
    * `:base_url` / `:token` — forge override (otherwise config `:fleet_pilot, :forge`)

  Returns `{:ok, %{repo, project_dir, work_dir}}` or `{:error, term()}` (fail-fast, no auto
  rollback: a mid-way failure leaves partial state — the operator cleans up before re-run).
  """
  @spec onboard(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def onboard(name, opts \\ []) when is_binary(name) do
    org = Keyword.get(opts, :org, "fleet")
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    # Anti-tie gaps (Fleet.Pilot.WriteSpacing, SHARED with StepRunCompleter): the sequence runs
    # LOCALLY (git), near-instantaneous — without a gap, create_repo/push main/push work/ops fall in the
    # SAME Gitea second and the activity feed displays them in an ARBITRARY order (observed live:
    # "push main" appeared BEFORE "repo created"). A gap after create_repo (the repo IS created before any
    # push) and one after push main (main IS pushed before work/ops) suffice for the 3 visible events.
    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- refute_existing(proj_dir, work_dir),
         {:ok, full_name} <- create_repo(name, org, opts),
         :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         {:ok, url} <- repo_url(full_name, opts),
         :ok <- clone_main(url, proj_dir),
         :ok <- Scaffold.main(proj_dir, name, opts),
         :ok <- commit(proj_dir, "chore(onboard): scaffold initial du projet"),
         :ok <- push(proj_dir, "main", false),
         :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         :ok <- add_work_ops(proj_dir, work_dir),
         :ok <- Scaffold.work(work_dir, name, opts),
         :ok <- commit(work_dir, "chore(onboard): init work/ops"),
         :ok <- push(work_dir, "work/ops", true),
         :ok <- lock_main(full_name, opts) do
      Logger.info("ProjectOnboard: #{full_name} ready — main=#{proj_dir}, work/ops=#{work_dir}")
      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir}}
    end
  end

  @doc """
  Imports an EXISTING repo `full_name` (`"owner/name"`, e.g. `"fleet/deja-la"`) into the agent machine —
  WS4. Output contract IDENTICAL to `onboard/2` (dual-dir + forge-enforced gate), but **neither creates nor
  scaffolds `main`**: the repo content stays INTACT (that is the whole point of an import — a repo that
  already exists, pushed outside-fleet or by a human). `opts`: same keys as `onboard/2` (`:projects_root`/
  `:work_root`/`:base_url`/`:token`) — no `:org`/`:description`/`:pitch` (nothing to create).

  Preconditions (fail-loud, none bypassed blindly):
    * `full_name` starts with `"<org>/"` (default `"fleet"`, override `opts[:org]`) — WS3: admission
      = org-membership, so a repo outside-org would NEVER be discovered by the poller after import.
      Import does NOT TRANSFER ownership (out-of-scope V1): the repo must already be in the org (move it
      via the forge first).
    * the repo's default branch IS `main` (same convention as `onboard`/`protect_main`, which assume it
      everywhere) — otherwise `{:error, {:unexpected_default_branch, ...}}`.

  Idempotent on `work/ops`: if the branch already exists (re-imported repo, or already onboarded), we do
  NOT overwrite it — only `lock_main` is re-applied (idempotent on the Gitea side, re-PUT = same rule).
  """
  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import(full_name, opts \\ []) when is_binary(full_name) do
    org = Keyword.get(opts, :org, "fleet")
    name = full_name |> String.split("/") |> List.last()
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- refute_existing(proj_dir, work_dir),
         :ok <- require_org_membership(full_name, org),
         :ok <- require_default_branch_main(full_name, opts),
         {:ok, url} <- repo_url(full_name, opts),
         :ok <- clone_main(url, proj_dir),
         :ok <- ensure_work_ops(full_name, url, proj_dir, work_dir, name, opts),
         :ok <- lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported — main=#{proj_dir}, work/ops=#{work_dir}"
      )

      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir}}
    end
  end

  # WS3 admission = org-membership: an outside-org import would never be discovered by the poller. Check
  # at STRING-level (the Gitea full_name IS "<owner>/<name>" — not one more forge call to re-verify
  # what the name already says).
  defp require_org_membership(full_name, org) do
    if String.starts_with?(full_name, "#{org}/"),
      do: :ok,
      else: {:error, {:not_in_org, full_name, org}}
  end

  defp require_default_branch_main(full_name, opts) do
    case ForgeClient.Repo.default_branch(full_name, fc_opts(opts)) do
      {:ok, "main"} -> :ok
      {:ok, other} -> {:error, {:unexpected_default_branch, other}}
      {:error, _} = err -> err
    end
  end

  # work/ops idempotent: present (re-import, or repo already onboarded) → we DO NOT OVERWRITE it (skip). Absent
  # (the nominal case of an external repo) → same sequence as onboard (steps 5-7): orphan branch + scaffold
  # + commit + push.
  defp ensure_work_ops(full_name, url, proj_dir, work_dir, name, opts) do
    if ForgeClient.Repo.branch_exists?(full_name, "work/ops", fc_opts(opts)) do
      File.mkdir_p!(Path.dirname(work_dir))
      GitOps.run(["clone", "--branch", "work/ops", url, work_dir], cd: nil, auth: true)
    else
      with :ok <- add_work_ops(proj_dir, work_dir),
           :ok <- Scaffold.work(work_dir, name, opts),
           :ok <- commit(work_dir, "chore(import): init work/ops"),
           :ok <- push(work_dir, "work/ops", true) do
        :ok
      end
    end
  end

  # ── DISCOVERABILITY — WS3: nothing to post. The repo is created IN the org `fleet` (create_repo `org:`) → it
  # is de facto discovered by the poller (`list_org_repos`: org-membership = admission). No more mutable
  # topic nor seal to engrave: the org IS the frontier of the trust group (set upstream by the admin).
  # Role access comes from the tofu teams (include_all); the human is read via the `humans` team. Per-human
  # scoping is done at the issue (`assigned_by`), not at the repo. ── `main` lock below. ──

  # ── `main` lock: the new repo is born READY for the agent workflow with a forge-enforced GATE ──
  # The role accounts (producer/judges/gatekeeper) ALREADY have **write** on any repo of the org via the
  # tofu teams (`writers`/`judges`, `include_all_repositories`) → no more redundant per-repo grant here (their
  # reviews count at the gate + the gatekeeper merges). LEFT is THE gesture: protect `main` — N approvals (= nb of
  # judges) + dismiss-stale (re-review on rework) + block-on-rejected (a REQUEST_CHANGES blocks) + no direct
  # push (merge via PR). Mechanical (this step, not a human action) → every onboarded project has the arbiter on the
  # FORGE side. `work/ops` + feature-branches NOT protected (zones of direct system movement).
  defp lock_main(full_name, opts), do: protect_main(full_name, opts)

  defp protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      required_approvals: length(Roles.reviewer_roles(opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false
    }

    case ForgeClient.Repo.protect_branch(repo, rule, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
  end

  defp fc_opts(opts), do: Keyword.get(opts, :forge_opts, [])

  # F2 (Z7c migration, débrief architecte 2026-07-12) — preflight fail-loud AVANT toute
  # création : un humain OS sans compte forge ou hors team `humans` produisait des 422
  # OPAQUES en aval (« Assignee does not exist » au premier create_issue — vécu e2e,
  # débloqué à la main). On échoue ICI avec les gestes admin EXACTS dans l'erreur.
  # DOCTRINE CONSERVÉE : l'admission org/team est gérée EN AMONT par l'humain admin
  # (cf. ForgeClient.Repo « managed UPSTREAM ») — le runtime VÉRIFIE (lecture seule),
  # il ne provisionne PAS (auto-provision = capability admin que le runtime n'a pas ;
  # arbitrage A-04 du chantier migration si l'user la veut un jour).
  # États : absent PROUVÉ (404) → gestes admin ; forge en PANNE → :forge_preflight_failed
  # SANS instructions (ne jamais envoyer l'opérateur créer un compte sur une panne réseau) ;
  # NON-VÉRIFIABLE (403 sur la lecture team, token non org-admin) → dégrade + procède (cf.
  # clause 403 plus bas — bricole vécue e2e migration 2026-07-12 : le garde bloquait un
  # humain PROVISIONNÉ faute de droit de lecture). Seam `:forge_users` (défaut
  # ForgeClient.Repo) : stub en test, pas de flip de config.
  defp ensure_human_provisioned(org, opts) do
    users = Keyword.get(opts, :forge_users, ForgeClient.Repo)
    human = Keyword.get(opts, :human) || Fleet.Credentials.Human.current!()
    fc = fc_opts(opts)

    case users.user_exists?(human, fc) do
      {:ok, false} ->
        {:error, {:human_not_provisioned, human, provisioning_gestures(:account, human, org)}}

      {:error, reason} ->
        {:error, {:forge_preflight_failed, reason}}

      {:ok, true} ->
        case users.team_member?(org, "humans", human, fc) do
          {:ok, true} ->
            :ok

          {:ok, false} ->
            {:error, {:human_not_provisioned, human, provisioning_gestures(:team, human, org)}}

          # QUATRIÈME état (≠ le tri-état ci-dessus) : 403 = le token runtime n'a pas le
          # DROIT de LIRE l'appartenance team. Le compte de service est un simple membre
          # d'org (ni owner, ni membre de `humans`) → Gitea refuse GET /teams/<id>/members/<u>.
          # « Ne PEUT PAS vérifier » ≠ « humain ABSENT » (404) : fail-closer ici briquerait
          # TOUT onboarding sur une forge où le token n'est pas org-admin — alors que
          # create_repo/issue/PR, eux, marchent avec ce même token. On DÉGRADE (warning +
          # on procède) : le garde F2 protège là où il PEUT lire ; là où il ne peut pas,
          # create_issue en aval reste le filet (le 422 forge explicite d'avant F2). NE PAS
          # convertir en :ok muet — le warning est load-bearing (dit POURQUOI le garde saute).
          {:error, {:http, 403, _}} ->
            Logger.warning(
              "ProjectOnboard: preflight team-check `humans` NON VÉRIFIABLE pour #{human} " <>
                "(403 — le token runtime ne peut pas lire l'appartenance team) → on procède " <>
                "sans le garde team (create_issue en aval reste le filet)."
            )

            :ok

          {:error, reason} ->
            {:error, {:forge_preflight_failed, reason}}
        end
    end
  end

  # Les gestes admin exacts, dans l'erreur elle-même : l'opérateur (ou l'architecte qui
  # relaie) n'a RIEN à chercher. Formulés API Gitea — la forme stable, UI/CLI équivalents.
  defp provisioning_gestures(:account, human, org) do
    "le compte forge '#{human}' n'existe pas — gestes admin (token admin requis) : " <>
      "1) POST /api/v1/admin/users {\"username\":\"#{human}\",\"email\":\"#{human}@lcars.local\"," <>
      "\"password\":\"<initial>\",\"must_change_password\":true} ; " <>
      "2) l'ajouter à la team 'humans' de l'org '#{org}' (cf. geste :team). " <>
      "Puis relancer l'onboarding."
  end

  defp provisioning_gestures(:team, human, org) do
    "le compte '#{human}' existe mais n'est PAS membre de la team 'humans' de l'org '#{org}' — " <>
      "geste admin : GET /api/v1/orgs/#{org}/teams → id de 'humans', puis " <>
      "PUT /api/v1/teams/<id>/members/#{human}. Puis relancer l'onboarding."
  end

  # ── slug / preconditions ─────────────────────────────────────────────────

  # Path-safe slug (kebab-case, ≥2 char, no border dash) — same contract as skill v1 /new-project.
  defp validate_name(name) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, name),
      do: :ok,
      else: {:error, {:invalid_name, name}}
  end

  defp refute_existing(proj_dir, work_dir) do
    cond do
      File.exists?(proj_dir) -> {:error, {:already_exists, proj_dir}}
      File.exists?(work_dir) -> {:error, {:already_exists, work_dir}}
      true -> :ok
    end
  end

  # ── forge + git ──────────────────────────────────────────────────────────

  defp create_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")
    result = ForgeClient.Repo.create_repo(name, Keyword.merge(opts, org: org, description: desc))
    classify_create_repo(result, org, name)
  end

  @doc false
  # F-C084 — a PRE-EXISTING repo is NOT a safe `onboard` target: onboard CREATES (it scaffolds `main` +
  # pushes over it). `{:ok, :already_exists}` (create_repo 409) → the repo pre-existed → we FAIL-LOUD
  # instead of scaffolding OVER it (which would CLOBBER a real repo's `main` — a human's repo onboarded by
  # mistake, or a completed project re-onboarded). The operator uses `import_project` (ADOPTS an existing
  # repo, content INTACT) or deletes the stale/partial repo — consistent with this module's own doctrine
  # (« no auto rollback: a mid-way failure leaves partial state — the operator cleans up before re-run »).
  # A GENUINE create (`{:ok, full_name}`) proceeds: onboard owns the fresh repo it just made.
  @spec classify_create_repo(
          {:ok, String.t() | :already_exists} | {:error, term()},
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def classify_create_repo({:ok, full_name}, _org, _name) when is_binary(full_name),
    do: {:ok, full_name}

  def classify_create_repo({:ok, :already_exists}, org, name),
    do: {:error, {:repo_already_exists, "#{org}/#{name}"}}

  def classify_create_repo({:error, _} = err, _org, _name), do: err

  defp repo_url(full_name, opts) do
    base =
      Keyword.get(opts, :base_url) || Application.get_env(:fleet_pilot, :forge, [])[:base_url]

    case base do
      b when is_binary(b) and b != "" ->
        {:ok, String.trim_trailing(b, "/") <> "/" <> full_name <> ".git"}

      _ ->
        {:error, {:config, {:missing, :base_url}}}
    end
  end

  defp clone_main(url, proj_dir) do
    File.mkdir_p!(Path.dirname(proj_dir))
    GitOps.run(["clone", "--branch", "main", url, proj_dir], cd: nil, auth: true)
  end

  defp add_work_ops(proj_dir, work_dir) do
    File.mkdir_p!(Path.dirname(work_dir))

    # git 2.43: --orphan -b <branch> <path> → linked worktree, orphan branch (empty merge-base).
    GitOps.run(["-C", proj_dir, "worktree", "add", "--orphan", "-b", "work/ops", work_dir],
      auth: false
    )
  end

  defp commit(dir, message) do
    with :ok <- GitOps.run(["-C", dir, "add", "-A"], auth: false) do
      # author = lcars-system (the system generates the scaffold, GIT_AUTHOR forced); committer = git config
      # runtime (= the human who initiated → traced, avatar) (2026-06-14).
      GitOps.run(["-C", dir, "commit", "-m", message], auth: false, author: onboard_author())
    end
  end

  defp push(dir, branch, set_upstream?) do
    args =
      ["-C", dir, "push"] ++
        if(set_upstream?, do: ["-u"], else: []) ++ ["origin", branch]

    GitOps.run(args, auth: true)
  end
end

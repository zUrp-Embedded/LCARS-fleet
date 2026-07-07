defmodule Fleet.Pilot.ProjectOnboard do
  @moduledoc """
  Onboarding d'un projet (Rail 1 firmware-as-a-service, 2026-06-14) : « idée → le projet existe ».

  Réplique l'archi dual-dir de LCARS lui-même (un repo, **deux worktrees**) :

    * `/home/projects/<name>`       → worktree branche `main`     (le livrable, push origin)
    * `/home/projects.work/<name>`  → worktree branche `work/ops` (orphan : plans, backlog, ops)

  C'est un **rail mécanique** (compliance structurelle) : l'arch *déclenche* via le tool
  MCP `create_project`, le SYSTÈME *exécute* cette séquence déterministe — l'arch ne tape jamais de git.

  Séquence (idempotence repo via `create_repo` 409 ; échoue clair si le dossier local existe déjà) :

    1. `ForgeClient.create_repo` (org `fleet`, `auto_init` → `main` clonable)
    2. `git clone --branch main` → `/home/projects/<name>`
    3. scaffold `main` (README, .gitignore, .editorconfig, docs/spec.md)
    4. commit (author=`Architect`, committer=git config runtime = l'humain) + push `main`
    5. `git worktree add --orphan -b work/ops` → `/home/projects.work/<name>`
    6. scaffold `work/ops` (backlog.md, scratchpad.md, plans/)
    7. commit + push `-u work/ops`

  Identité (décision 2026-06-14 — l'onboarding est un acte d'INFRA système, pas du travail créatif) :
  `author=lcars-system` (le SYSTÈME génère le scaffold depuis des templates ; l'arch n'écrit aucun fichier,
  il **relaie** `name`+`pitch` — il est transparent dans l'attribution git, sa trace vit dans la demande),
  `committer`=l'humain (git config runtime = **l'user qui a initié le projet → tracé**),
  `pusher`=`lcars-system` (`ForgeAuth.git_env`, owner fleet-wide). Tout avataré (emails → comptes Gitea).
  Pas de GenServer (Iron Law — orchestration d'I/O sans état partagé).

  ⚠ CONTRAT CROISÉ (seam `fleet_mcp`) : `onboard/2` est l'impl RÉELLE (défaut) du behaviour
  `Fleet.MCP.PodTools.Delegation.ProjectOnboard`. On ne peut PAS l'adopter en `@behaviour` :
  `fleet_pilot` ne dépend pas de `fleet_mcp` et la référence compile créerait une arête nouvelle
  (`allowed_graph.yaml` rougirait). Impl duck-typée — toute évolution de la signature/du shape
  `result()` DOIT être répercutée sur le `@callback` du behaviour (et inversement).
  """

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.GitOps
  alias Fleet.Pilot.Roles

  # Contenu + écriture du scaffold (templates purs, dual-dir main / work-ops) — extrait :
  # aucune dépendance à l'orchestration, l'onboard l'appelle aux bons moments de sa séquence.
  alias Fleet.Pilot.ProjectOnboard.Scaffold

  require Logger

  # H1/H3 : derive de l'autorite unique du layout container (Fleet.Layout, R0).
  @projects_root Fleet.Layout.projects_root()
  @work_root Fleet.Layout.work_root()
  # author de l'onboarding = le système (il GÉNÈRE le scaffold) — pas l'arch (simple relais), pas l'user
  # (n'a rien écrit). committer = l'humain (git config) trace qui a initié (2026-06-14).
  # Identité système : AUTORITÉ UNIQUE = Fleet.Credentials.ForgeIdentity.system_identity/0
  # (H2 2026-07-04 : le name/email était retapé ici en dur — divergence en germe avec la gate).
  defp onboard_author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @type result :: %{repo: String.t(), project_dir: Path.t(), work_dir: Path.t()}

  @doc """
  Onboard le projet `name` (slug kebab-case). `opts` :

    * `:org`           — org forge (défaut `"fleet"`)
    * `:description`   — description du repo (défaut `""`)
    * `:pitch`         — phrase de pitch (scaffold README/spec ; défaut = description)
    * `:projects_root` / `:work_root` — racines FS (défauts : `/home/projects`, `/home/projects.work`)
    * `:base_url` / `:token` — override forge (sinon config `:fleet_pilot, :forge`)

  Retourne `{:ok, %{repo, project_dir, work_dir}}` ou `{:error, term()}` (fail-fast, pas de rollback
  auto : un échec à mi-chemin laisse l'état partiel — l'opérateur nettoie avant re-run).
  """
  @spec onboard(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def onboard(name, opts \\ []) when is_binary(name) do
    org = Keyword.get(opts, :org, "fleet")
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    with :ok <- validate_name(name),
         :ok <- refute_existing(proj_dir, work_dir),
         {:ok, full_name} <- create_repo(name, org, opts),
         {:ok, url} <- repo_url(full_name, opts),
         :ok <- clone_main(url, proj_dir),
         :ok <- Scaffold.main(proj_dir, name, opts),
         :ok <- commit(proj_dir, "chore(onboard): scaffold initial du projet"),
         :ok <- push(proj_dir, "main", false),
         :ok <- add_work_ops(proj_dir, work_dir),
         :ok <- Scaffold.work(work_dir, name, opts),
         :ok <- commit(work_dir, "chore(onboard): init work/ops"),
         :ok <- push(work_dir, "work/ops", true),
         :ok <- register_for_fleet(full_name, opts),
         :ok <- lock_main(full_name, opts) do
      Logger.info("ProjectOnboard: #{full_name} prêt — main=#{proj_dir}, work/ops=#{work_dir}")
      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir}}
    end
  end

  # ── MULTI-PROJET — rend le repo neuf DÉCOUVRABLE + ACCESSIBLE par la fleet de l'humain ──
  # 1. TOPIC `lcars-fleet-<human>` (source UNIQUE `Fleet.Pilot.Poller.fleet_topic/1`, partagée avec le
  #    poller qui DÉCOUVRE par `search_repos_by_topic`) → un humain ne voit QUE ses projets (isolation REPO ;
  #    l'axe ISSUE `assigned_by` est la ceinture). 2. COLLABORATEUR write = l'humain initiateur (les
  #    comptes-rôles, eux, sont ajoutés par `grant_fleet_roles` dans `lock_main`). `my_human` = l'user OS du
  #    runtime — l'onboarding tourne dans SA BEAM (MCP `create_project`), donc `Human.current!()` EST l'humain
  #    qui a initié → cohérent avec le scoping du poller (même source). Fail-loud si l'user est irrésoluble
  #    (un repo taggé pour le mauvais humain ne serait jamais découvert).
  defp register_for_fleet(repo, opts) do
    my_human = Fleet.Credentials.Human.current!()
    topic = Fleet.Pilot.Poller.fleet_topic(my_human)

    # Le topic rend le repo DÉCOUVRABLE mais ne l'ADMET pas : il est mutable (un propriétaire de repo
    # peut le poser lui-même). L'admission exige le SCEAU système — `post_onboard_marker` ouvre une issue
    # `[lcars-onboarded:<human>]` SOUS le compte du token (= le bot système, `fc_opts` porte `FORGE_TOKEN`).
    # Le poller n'admet un repo que s'il porte ce marqueur bot-authored (`ForgeClient.admitted?`) : un
    # humain ne peut pas le forger faute du token système. Posé ICI, à l'onboarding système, en même temps
    # que le topic — découvrabilité ET admission scellées par le même acte d'infra système.
    # PAS de write per-repo à l'humain : il produit RIEN directement sur la forge (décision user). Il est
    # read via la team `humans` du tofu (include_all_repositories) → il voit + commente, ne relabellise ni
    # ne pousse. S'il veut toucher du code, il fork HORS fleet + pose une PR cross-repo → le système la gate
    # comme un livrable d'agent (pipeline reviews-driven, agent-agnostique). Read sur l'origin suffit au fork.
    with :ok <- ForgeClient.Repo.add_topic(repo, topic, fc_opts(opts)),
         {:ok, _} <- ForgeClient.Repo.post_onboard_marker(repo, my_human, fc_opts(opts)) do
      :ok
    else
      {:error, reason} -> {:error, {:register_for_fleet, reason}}
    end
  end

  # ── Verrou de `main` : le repo neuf naît PRÊT pour le workflow d'agents avec GATE forge-enforcé ──
  # 1. Les comptes de rôle (engineer/qualifier/reviewer/gatekeeper) reçoivent le **write** — sinon
  #    leurs reviews ne comptent pas au gate ET le gatekeeper ne peut pas merger (la protection
  #    deadlockerait). 2. `main` est protégée : N approvals (= nb de juges) + dismiss-stale (re-review
  #    au rework) + block-on-rejected (un REQUEST_CHANGES bloque) + pas de push direct (merge via PR).
  # Mécanique (ce step, pas une action humaine) → tout projet onboardé a l'arbitre côté FORGE.
  # `work/ops` + feature-branches NON protégées (zones de mouvement direct du système).
  defp lock_main(full_name, opts) do
    with :ok <- grant_fleet_roles(full_name, opts),
         :ok <- protect_main(full_name, opts) do
      :ok
    end
  end

  defp grant_fleet_roles(repo, opts) do
    Enum.reduce_while(fleet_roles(opts), :ok, fn role, :ok ->
      case ForgeClient.Repo.add_collaborator(repo, role, "write", fc_opts(opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_role, role, reason}}}
      end
    end)
  end

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

  # Comptes de rôle qui agissent sur un repo = producteur + juges + gatekeeper. Les trois viennent de
  # l'AUTORITÉ UNIQUE `Fleet.Pilot.Roles` (config + overrides opts) — plus de défaut `engineer`/`gatekeeper`
  # réécrit ici.
  defp fleet_roles(opts),
    do: [Roles.producer_role(opts)] ++ Roles.reviewer_roles(opts) ++ [Roles.gatekeeper_role(opts)]

  defp fc_opts(opts), do: Keyword.get(opts, :forge_opts, [])

  # ── slug / pré-conditions ────────────────────────────────────────────────

  # Slug path-safe (kebab-case, ≥2 char, pas de tiret bordure) — même contrat que skill v1 /new-project.
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

    case ForgeClient.Repo.create_repo(name, Keyword.merge(opts, org: org, description: desc)) do
      {:ok, full_name} when is_binary(full_name) -> {:ok, full_name}
      {:ok, :already_exists} -> {:ok, "#{org}/#{name}"}
      {:error, _} = err -> err
    end
  end

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

    # git 2.43 : --orphan -b <branch> <path> → worktree lié, branche orpheline (merge-base vide).
    GitOps.run(["-C", proj_dir, "worktree", "add", "--orphan", "-b", "work/ops", work_dir],
      auth: false
    )
  end

  defp commit(dir, message) do
    with :ok <- GitOps.run(["-C", dir, "add", "-A"], auth: false) do
      # author = lcars-system (le système génère le scaffold, GIT_AUTHOR forcé) ; committer = git config
      # runtime (= l'humain qui a initié → tracé, avatar) (2026-06-14).
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

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
  """

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Credentials.ForgeAuth

  require Logger

  @projects_root "/home/projects"
  @work_root "/home/projects.work"
  # author de l'onboarding = le système (il GÉNÈRE le scaffold) — pas l'arch (simple relais), pas l'user
  # (n'a rien écrit). committer = l'humain (git config) trace qui a initié (2026-06-14).
  @onboard_author %{name: "lcars-system", email: "lcars-system@lcars.local"}

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
         :ok <- scaffold_main(proj_dir, name, opts),
         :ok <- commit(proj_dir, "chore(onboard): scaffold initial du projet"),
         :ok <- push(proj_dir, "main", false),
         :ok <- add_work_ops(proj_dir, work_dir),
         :ok <- scaffold_work(work_dir, name, opts),
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
  #    l'axe TICKET `assigned_by` est la ceinture). 2. COLLABORATEUR write = l'humain initiateur (les
  #    comptes-rôles, eux, sont ajoutés par `grant_fleet_roles` dans `lock_main`). `my_human` = l'user OS du
  #    runtime — l'onboarding tourne dans SA BEAM (MCP `create_project`), donc `Human.current!()` EST l'humain
  #    qui a initié → cohérent avec le scoping du poller (même source). Fail-loud si l'user est irrésoluble
  #    (un repo taggé pour le mauvais humain ne serait jamais découvert).
  defp register_for_fleet(repo, opts) do
    my_human = Fleet.Credentials.Human.current!()
    topic = Fleet.Pilot.Poller.fleet_topic(my_human)

    with :ok <- ForgeClient.add_topic(repo, topic, fc_opts(opts)),
         :ok <- ForgeClient.add_collaborator(repo, my_human, "write", fc_opts(opts)) do
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
      case ForgeClient.add_collaborator(repo, role, "write", fc_opts(opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_role, role, reason}}}
      end
    end)
  end

  defp protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      required_approvals: length(reviewer_roles(opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false
    }

    case ForgeClient.protect_branch(repo, rule, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
  end

  # Comptes de rôle qui agissent sur un repo = producteur + juges + gatekeeper (config, data catalogue).
  defp fleet_roles(opts),
    do: [producer_role(opts)] ++ reviewer_roles(opts) ++ [gatekeeper_role(opts)]

  defp producer_role(opts),
    do:
      Keyword.get(opts, :producer_role) ||
        Application.get_env(:fleet_pilot, :producer_role, "engineer")

  defp reviewer_roles(opts),
    do:
      Keyword.get(opts, :reviewer_roles) ||
        Application.get_env(:fleet_pilot, :reviewer_roles, ["qualifier", "reviewer"])

  defp gatekeeper_role(opts),
    do:
      Keyword.get(opts, :gatekeeper_role) ||
        Application.get_env(:fleet_pilot, :gatekeeper_role, "gatekeeper")

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

    case ForgeClient.create_repo(name, Keyword.merge(opts, org: org, description: desc)) do
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
    git(["clone", "--branch", "main", url, proj_dir], cd: nil, auth: true)
  end

  defp add_work_ops(proj_dir, work_dir) do
    File.mkdir_p!(Path.dirname(work_dir))

    # git 2.43 : --orphan -b <branch> <path> → worktree lié, branche orpheline (merge-base vide).
    git(["-C", proj_dir, "worktree", "add", "--orphan", "-b", "work/ops", work_dir], auth: false)
  end

  defp commit(dir, message) do
    with :ok <- git(["-C", dir, "add", "-A"], auth: false) do
      # author = lcars-system (le système génère le scaffold, GIT_AUTHOR forcé) ; committer = git config
      # runtime (= l'humain qui a initié → tracé, avatar) (2026-06-14).
      git(["-C", dir, "commit", "-m", message], auth: false, author: @onboard_author)
    end
  end

  defp push(dir, branch, set_upstream?) do
    args =
      ["-C", dir, "push"] ++
        if(set_upstream?, do: ["-u"], else: []) ++ ["origin", branch]

    git(args, auth: true)
  end

  # Git borné par construction via `Fleet.Credentials.Shell` (source unique de la borne) avec gestion
  # d'erreur typée. Les ops réseau (clone, push : `auth: true`) peuvent hung/prompter ; le wrapper les
  # lance dans un process-group dédié et, à la deadline MUR, tue le GROUPE entier (l'op ET ses helpers de
  # transport, porteurs du token forge) + ferme le port. Les ops locales (worktree/add/commit) passent
  # par le même chemin → aucun `System.cmd git` nu ne subsiste ici. `auth: true` → token forge en env
  # (hors argv, ForgeAuth). `author: %{name,email}` → GIT_AUTHOR_* (committer laissé à la git config =
  # l'humain). On passe TOUJOURS `:env` explicitement (donc Shell n'injecte pas son défaut `git_env/0`) :
  # les ops locales tournent sans auth, mais l'anti-prompt n'y change rien (pas de réseau).
  defp git(args, opts) do
    env =
      if(Keyword.get(opts, :auth, false), do: ForgeAuth.git_env(), else: []) ++
        identity_env(Keyword.get(opts, :author))

    case Fleet.Credentials.Shell.git(args, env: env) do
      {:ok, {_out, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:git_failed, Enum.take(args, 3), code, String.slice(out, 0, 500)}}

      {:error, {:timeout, ms}} ->
        {:error, {:git_timeout, Enum.take(args, 3), ms}}

      {:error, {:exit, reason}} ->
        {:error, {:git_exit, Enum.take(args, 3), reason}}
    end
  end

  # Commit (author posé) : GIT_AUTHOR = le système (scaffold généré, `@onboard_author`) + GIT_COMMITTER =
  # l'humain qui a initié (traça), résolu ROBUSTE via `ForgeIdentity.human_identity` (git config → GECOS →
  # login) ⇒ ne dépend PAS du `~/.gitconfig` humain (2026-06-22) : sans GIT_COMMITTER, un
  # humain non-configuré → committer « empty ident name » → commit du scaffold refusé → create_project bloqué.
  defp identity_env(%{name: name, email: email}) do
    committer =
      case Fleet.Credentials.ForgeIdentity.human_identity() do
        {:ok, %{name: cn, email: ce}} -> [{"GIT_COMMITTER_NAME", cn}, {"GIT_COMMITTER_EMAIL", ce}]
        _ -> []
      end

    [{"GIT_AUTHOR_NAME", name}, {"GIT_AUTHOR_EMAIL", email}] ++ committer
  end

  defp identity_env(_), do: []

  # ── scaffold (standard, état de l'art — ajustable) ───────────────────────

  defp scaffold_main(dir, name, opts) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, "(à compléter)")
    File.mkdir_p!(Path.join(dir, "docs"))

    write_all(dir, %{
      "README.md" => readme(name, pitch),
      ".gitignore" => gitignore(),
      ".editorconfig" => editorconfig(),
      "docs/spec.md" => spec_md(name, pitch)
    })
  end

  defp scaffold_work(dir, name, opts) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, "")
    File.mkdir_p!(Path.join(dir, "plans"))

    write_all(dir, %{
      "backlog.md" => backlog_md(name, pitch),
      "scratchpad.md" => "",
      "plans/.gitkeep" => ""
    })
  end

  defp write_all(dir, files) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))

      case File.write(path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:scaffold_write, rel, reason}}}
      end
    end)
  end

  defp readme(name, pitch) do
    """
    # #{name}

    #{pitch}

    ## Installation

    (à compléter)

    ## Usage

    (à compléter)
    """
  end

  defp spec_md(name, pitch) do
    """
    # #{name} — Spec

    **Date** : 2026-06-14
    **Dernière révision** : 2026-06-14
    **Statut** : draft v1
    **Référencé par** : work/ops:backlog.md
    **Dérivé de** : —

    ## Pitch

    #{pitch}

    ## Contraintes

    (à compléter)
    """
  end

  defp backlog_md(name, pitch) do
    """
    # #{name} — Backlog

    **Date** : 2026-06-14
    **Dernière révision** : 2026-06-14
    **Statut** : actif
    **Référencé par** : —
    **Dérivé de** : docs/spec.md

    > #{pitch}

    ## Todo

    - [ ] Cadrer la spec (`docs/spec.md` sur `main`)

    ## Done

    (vide)
    """
  end

  defp gitignore do
    """
    # build / artefacts
    build/
    dist/
    *.log
    *.o
    *.obj

    # secrets / env
    .env
    .env.local

    # langages
    __pycache__/
    *.pyc
    node_modules/
    _build/
    deps/
    """
  end

  defp editorconfig do
    """
    root = true

    [*]
    charset = utf-8
    end_of_line = lf
    insert_final_newline = true
    indent_style = space
    indent_size = 4
    trim_trailing_whitespace = true
    """
  end
end

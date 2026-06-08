# Rework #1 : `Fleet.ProjectBootstrap.CapAccess.cap/3` (accès tolérant
# atom|string) RETIRÉ — `Fleet.CapProfile` garantit désormais des clés STRING
# (normalisation à `to_struct`). Les phases accèdent `cap_profile.spec["..."]`
# directement, sans double-lookup défensif.
defmodule Fleet.ProjectBootstrap.Phase do
  @moduledoc """
  Les 5 sous-phases de `Fleet.ProjectBootstrap.prepare/3` (DN
  ring1/fleet_project_bootstrap.md §"Contrat technique"). Fonctions pures
  (Iron Law — aucun process). Erreurs typées (exit codes DN).
  Accès cap-profile : clés STRING directes (`cap_profile.spec["..."]`) —
  `Fleet.CapProfile` garantit la forme à la production (rework #1).
  """

  defmodule Allocate do
    @moduledoc "Phase 1 — ALLOCATE pod_dir `/tmp/pod-<pod_id>/` (owner = system_user)."
    @spec allocate(String.t(), struct()) :: {:ok, Path.t()} | {:error, term()}
    def allocate(pod_id, _cap_profile) when is_binary(pod_id) and pod_id != "" do
      pod_dir = Path.join(System.tmp_dir!(), "pod-#{pod_id}")

      case File.mkdir_p(pod_dir) do
        :ok -> {:ok, pod_dir}
        {:error, reason} -> {:error, {:allocate_failed, reason}}
      end
    end

    def allocate(_, _), do: {:error, {:allocate_failed, :invalid_pod_id}}
  end

  defmodule Clone do
    @moduledoc """
    Phase 2 — CLONE branch feature OU skip (pod permanent / pas de repo).
    `git clone --reference` (ADR-B Q5) si `spec.project.repo_path`, sinon
    workspace = `mktemp -d` (branch nil).
    """
    @spec clone_or_skip(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t() | nil} | {:error, term()}
    def clone_or_skip(pod_dir, %Fleet.CapProfile{spec: spec}, opts) do
      project = spec["project"] || %{}

      case project["repo_path"] do
        nil ->
          ws = Path.join(pod_dir, "workspace")

          case File.mkdir_p(ws) do
            :ok -> {:ok, ws, nil}
            {:error, r} -> {:error, {:clone_failed, r}}
          end

        repo_url ->
          ws = Path.join(pod_dir, "workspace")
          ref = project["reference_repo_path"]
          base = project["base_branch"] || "main"
          slug = Keyword.get(opts, :slug, "work")
          pod_id = Path.basename(pod_dir) |> String.replace_prefix("pod-", "")
          feature = "feature/#{pod_id}-#{slug}"
          ref_args = if ref, do: ["--reference", ref], else: []

          with {_, 0} <-
                 System.cmd(
                   "git",
                   forge_auth_args() ++ ["clone"] ++ ref_args ++ ["--branch", base, repo_url, ws],
                   stderr_to_stdout: true
                 ),
               # #596 R1 (F-03) : si l'Executor a PINNÉ une base_sha (ls-remote hors-pod), on épingle
               # HEAD dessus AVANT la feature-branch. Élimine la fenêtre « le pod clone une base que
               # l'Executor n'a pas capturée » (course same-role) : `base..HEAD` ne contiendra QUE les
               # commits du pod. F-03 = axiome au boundary clone, pas « observable post-hoc ».
               {_, 0} <- pin_base_sha(ws, project["base_sha"]),
               {_, 0} <-
                 System.cmd("git", ["-C", ws, "checkout", "-b", feature], stderr_to_stdout: true) do
            {:ok, ws, feature}
          else
            {out, code} -> {:error, {:clone_failed, {code, String.slice(out, 0, 500)}}}
          end
      end
    end

    # Épingle HEAD du workspace sur `sha` (capturé hors-pod par l'Executor). Le clone `--branch base`
    # contient déjà `sha` dans le cas nominal (sha = tip) et fast-forward (sha = ancêtre) → `reset
    # --hard` local suffit. Cas pathologique (force-push remote a effacé `sha`) → fetch ciblé puis
    # reset ; échec des deux = {out, code≠0} remonté au `with` → `{:clone_failed, ...}`. nil/"" = no-op.
    defp pin_base_sha(_ws, sha) when sha in [nil, ""], do: {"", 0}

    defp pin_base_sha(ws, sha) when is_binary(sha) do
      case System.cmd("git", ["-C", ws, "reset", "--hard", sha], stderr_to_stdout: true) do
        {_, 0} = ok ->
          ok

        _ ->
          case System.cmd("git", ["-C", ws] ++ forge_auth_args() ++ ["fetch", "origin", sha],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              System.cmd("git", ["-C", ws, "reset", "--hard", sha], stderr_to_stdout: true)

            other ->
              other
          end
      end
    end

    @doc """
    Doc-mount (mundo invocado) — clone la branche DOC du projet (`spec.project.work_branch`,
    orpheline `work/ops` par convention LCARS) dans `<pod_dir>/work` : la doc sur quoi l'agent
    s'appuie pour coder (plans, backlog, conventions). À côté de la branche code (`workspace`).

    - `work_branch` nil/absent OU pas de `repo_path` → `{:ok, nil}` (skip : projet sans branche doc).
    - déclarée mais clone échoué → `{:error, ...}` FAIL-LOUD (I-CBC : un cap-profile qui déclare une
      branche doc inexistante = bug de config, pas un pod silencieusement amputé de sa doc).
    """
    @spec clone_work_doc(Path.t(), Fleet.CapProfile.t()) ::
            {:ok, Path.t() | nil} | {:error, term()}
    def clone_work_doc(pod_dir, %Fleet.CapProfile{spec: spec}) do
      project = spec["project"] || %{}
      work_branch = project["work_branch"]
      repo_url = project["repo_path"]

      if is_nil(work_branch) or is_nil(repo_url) do
        {:ok, nil}
      else
        doc = Path.join(pod_dir, "work")
        ref = project["reference_repo_path"]
        ref_args = if ref, do: ["--reference", ref], else: []

        # --single-branch : la branche doc est orpheline ⇒ inutile de fetch le reste de l'historique.
        case System.cmd(
               "git",
               forge_auth_args() ++
                 ["clone"] ++
                 ref_args ++ ["--branch", work_branch, "--single-branch", repo_url, doc],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            {:ok, doc}

          {out, code} ->
            {:error, {:work_doc_clone_failed, {work_branch, code, String.slice(out, 0, 500)}}}
        end
      end
    end

    # Auth git système-side pour cloner/fetcher une forge PRIVÉE (repo_path remote). Source unique :
    # config `:fleet_pipeline, :forge_auth = %{url_prefix, token}` (même clé que `Fleet.Pipeline.Git.
    # forge_auth_args`, lue ici sans dépendance compile pour éviter le cycle pipeline⇄bootstrap).
    # Injecté en `-c http.<prefix>.extraheader` (option CLI, **non persistée** dans `.git/config` du
    # workspace) : le clone s'authentifie côté MONDE, mais le pod hérite d'un remote SANS credential —
    # barrière forge-aveugle préservée (DN forge-state-machine §4 ; cf. BL-045 unifier les helpers).
    # Absent → `[]` (repo local `file://` / mirror : pas d'auth).
    defp forge_auth_args do
      case Application.get_env(:fleet_pipeline, :forge_auth) do
        %{url_prefix: prefix, token: token}
        when is_binary(prefix) and is_binary(token) and prefix != "" and token != "" ->
          ["-c", "http.#{prefix}.extraheader=Authorization: token #{token}"]

        _ ->
          []
      end
    end

    # O5 (Brick 5) — `set_git_identity/2` RETIRÉ. Posait l'identité du rôle via `git config` dans le
    # `.git/config` du workspace : MUTABLE, le pod l'écrasait (`git config user.email …`) → identité
    # falsifiable (F-01 du juge consultant). Remplacé par une injection en env au lancement
    # (bwrap_launch.sh : GIT_AUTHOR_*/GIT_COMMITTER_* = LCARS-<role> / <role>@lcars.local +
    # GIT_CONFIG_GLOBAL=/dev/null), défaut coopératif déterministe. La garantie F-01 vit côté monde :
    # `Fleet.Pipeline.DeliverableGate.check_identity/3` rejette au push tout commit hors identité
    # autorisée (le pod ne PEUT PAS pousser un livrable usurpé). Cf. JOURNAL-deliverable-model.
  end

  defmodule InitMimic do
    @moduledoc """
    Phase 3 — `/init` mimic vanilla : rend `templates/claude-md-vanilla.md`
    (EEx) → `<workspace>/CLAUDE.md`. L'agent découvre un projet post-/init,
    ne réinvoque pas `/init`.
    """
    @spec init_mimic(Path.t(), Fleet.CapProfile.t()) :: {:ok, Path.t()} | {:error, term()}
    def init_mimic(workspace, %Fleet.CapProfile{spec: spec, metadata: metadata}) do
      tpl =
        Application.app_dir(:fleet_project_bootstrap, "priv/templates/claude-md-vanilla.md.eex")

      project = spec["project"] || %{}

      assigns = [
        project_name: project["name"] || "project",
        project_intent: project["intent"] || "",
        pod_role: metadata["name"] || "worker"
      ]

      with {:ok, tpl_src} <- File.read(tpl),
           rendered <- EEx.eval_string(tpl_src, assigns: assigns),
           path <- Path.join(workspace, "CLAUDE.md"),
           :ok <- File.write(path, rendered) do
        {:ok, path}
      else
        {:error, r} -> {:error, {:init_mimic_failed, r}}
      end
    end
  end

  defmodule BindCredentials do
    @moduledoc """
    Phase 4 — creds via **claudeDir natif bind** (adr-f). Plus d'injection
    d'env OAuth : le claudeDir du compte de l'humain est monté RW par
    `bwrap_launch.sh` en `~/.claude` (CLAUDE_DIR), refresh délégué au lockfile
    cross-process natif Anthropic. Le path CLAUDE_DIR est résolu par
    `Fleet.Spawner` depuis la registration de l'humain (DN onboarding/catalogue
    déférée, adr-e). Cette phase ne produit donc aucun env à injecter.
    """

    @doc """
    Retourne un env vide : aucune variable OAuth injectée (adr-f — le coffre
    `Fleet.Credentials` et le chemin RT-env sont dépréciés). Les creds vivent
    dans le claudeDir bindé par bwrap. Le pattern `%Fleet.CapProfile{}` garde
    le contrat (struct invalide → erreur typée).
    """
    @spec bind_credentials(Path.t(), Fleet.CapProfile.t()) ::
            {:ok, %{String.t() => String.t()}} | {:error, term()}
    def bind_credentials(_pod_dir, %Fleet.CapProfile{}) do
      {:ok, %{}}
    end

    def bind_credentials(_pod_dir, _not_a_cap_profile) do
      {:error, {:credentials_resolve_failed, :not_a_cap_profile}}
    end
  end

  defmodule PrepareMountBinds do
    @moduledoc """
    Phase 5 — calcule les paths plugins à mount-bind RO (effectivement bindés
    en phase LAUNCH par bwrap_launch.sh, chantier 4). Selon
    `spec.knowledge.skills/plugins`. `~/.claude/CLAUDE.md` NON montée (le
    CLAUDE.md vanilla phase 3 prend la place).
    """
    @spec prepare_mount_binds(Path.t(), Fleet.CapProfile.t()) ::
            {:ok, [{Path.t(), Path.t(), :ro | :rw}]} | {:error, term()}
    def prepare_mount_binds(pod_dir, %Fleet.CapProfile{spec: spec}) do
      knowledge = spec["knowledge"] || %{}
      skills = knowledge["skills"] || []
      home = System.user_home!()

      binds =
        if skills == [] do
          []
        else
          [
            # Target = HOME du pod (= $POD_DIR, cf. bwrap_launch.sh --setenv HOME),
            # PAS /home/<role> : le rôle n'est pas un user Linux (adr-e), le chemin
            # in-pod est virtuel. Cohérent avec le bind plugins de bwrap_launch.sh.
            {Path.join(home, ".claude/plugins/superpowers"),
             Path.join(pod_dir, ".claude/plugins/superpowers"), :ro}
          ]
        end

      {:ok, binds}
    end
  end
end

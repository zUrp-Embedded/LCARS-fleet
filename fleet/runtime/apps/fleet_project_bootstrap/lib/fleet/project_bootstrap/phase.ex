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
    @moduledoc """
    Phase 1 — ALLOCATE pod_dir = `<pod_dir_base>/pod-<id>`.

    PB-D2 (2026-06-10) : le défaut **`/tmp`** (`System.tmp_dir!`) est RETIRÉ — il contredisait
    ADR-E (les pods vivent sous `/home/<human>/pods/pod_<id>`, JAMAIS `/tmp` ; `PrivateTmp=yes`
    + tmpfs bwrap orphelineraient les writes). Le `:pod_dir_base` est désormais **REQUIS** dans
    `opts` : prod (#596) injecte la racine ADR-E calculée côté `Fleet.Spawner.Pod` (qui connaît
    l'humain) ; les tests injectent leur `tmp_dir`. Pas de défaut silencieux qui réintroduirait
    le piège `/tmp` si #596 réveille `prepare/3` (aujourd'hui le spawner emprunte direct `Clone`).
    """
    @spec allocate(String.t(), struct(), keyword()) :: {:ok, Path.t()} | {:error, term()}
    def allocate(pod_id, _cap_profile, opts) when is_binary(pod_id) and pod_id != "" do
      base = Keyword.fetch!(opts, :pod_dir_base)
      pod_dir = Path.join(base, "pod-#{pod_id}")

      case File.mkdir_p(pod_dir) do
        :ok -> {:ok, pod_dir}
        {:error, reason} -> {:error, {:allocate_failed, reason}}
      end
    end

    def allocate(_, _, _), do: {:error, {:allocate_failed, :invalid_pod_id}}
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
          # F121 NB : `fleet_project_bootstrap` ne peut PAS dépendre de `fleet_spawner` (cycle compile),
          # donc `"workspace"` est ré-encodé ici — il DOIT rester en sync avec
          # `Fleet.Spawner.@pod_workspace_subdir` (autorité de la convention #596). Ce module est le
          # PRODUCTEUR (il crée et retourne le workspace) ; Pod le RECOMPUTE via pod_workspace_path/1.
          ws = Path.join(pod_dir, "workspace")

          # Idempotence du re-dispatch déterministe : un pod prédécesseur MORT (timeout/crash) laisse son
          # workspace sur disque ; comme le pod_id est déterministe (`<repo-slug>-issue-N-role`), le
          # re-dispatch retombe sur le MÊME pod_dir → `git clone` refuserait (« destination already exists
          # and is not an empty directory ») → wedge PERMANENT du ticket (prouvé live 2026-06-22 : un
          # consultant timeout bouclait à l'infini sur clone_failed). Le pod POSSÈDE son pod_dir (garde
          # spawn = 1 pod/pod_id) → un `ws` résiduel ne peut venir que d'un prédécesseur mort → clean slate
          # (le `base_sha` est ré-épinglé juste après, un clone frais est toujours correct).
          _ = File.rm_rf(ws)

          ref = project["reference_repo_path"]
          base = project["base_branch"] || "main"

          # #chantier monde-propre : branche = `feature/<slug>` SANS le pod_id (l'agent ne doit pas
          # relire son pod_id dans sa propre branche — containment). Le slug vient du dispatcher (titre
          # du ticket sanitizé) ; défaut `work`. (Fixe au passage l'ancien bug : `replace_prefix("pod-")`
          # ne strippait pas `pod_` → le `pod_` restait collé.)
          slug = Keyword.get(opts, :slug, "work")
          feature = "feature/#{slug}"
          ref_args = if ref, do: ["--reference", ref], else: []

          # MOVE-1/MA-22 : la deadline du clone RÉSEAU est calibrable par l'appelant (`:git_timeout_ms`),
          # défaut = celui du wrapper (30s). Le spawner peut la resserrer ; les tests l'utilisent pour
          # prouver le bornage (clone vers une URL qui pend → tué dans le délai, pas de pod zombie).
          git_opts = Keyword.take(opts, [:git_timeout_ms]) |> rename_timeout_key()

          # MOVE-1/MA-22 — clone/checkout BORNÉS par construction via `Fleet.Credentials.Shell.git/2`
          # (Task.async + yield(timeout) || brutal_kill, `GIT_TERMINAL_PROMPT=0` posé par `git_env/0`).
          # Avant, `System.cmd("git", ["clone", …])` était non borné : un clone réseau hung (ou un git
          # qui prompte faute de credential, sans TTY) figeait le `Fleet.Spawner.Pod` (GenServer) → pod
          # zombie / ticket wedgé. Le wrapper tue le git enfant si la deadline expire et rend une erreur
          # typée → le pod ne reste pas figé. `Shell.git/2` injecte `git_env/0` (anti-prompt + auth forge).
          with {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(
                   ["clone"] ++ ref_args ++ ["--branch", base, repo_url, ws],
                   git_opts
                 ),
               # #596 R1 (F-03) : si l'Executor a PINNÉ une base_sha (ls-remote hors-pod), on épingle
               # HEAD dessus AVANT la feature-branch. Élimine la fenêtre « le pod clone une base que
               # l'Executor n'a pas capturée » (course same-role) : `base..HEAD` ne contiendra QUE les
               # commits du pod. F-03 = axiome au boundary clone, pas « observable post-hoc ».
               {:ok, {_, 0}} <- pin_base_sha(ws, project["base_sha"]),
               # `checkout -b` est local (pas réseau, ne prompte pas) mais passe AUSSI par le wrapper
               # borné : pas de `System.cmd git` nu sur ce chemin (la frontière du move = aucun git non
               # borné inexprimable). Env bare (pas d'auth/réseau).
               {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(["-C", ws, "checkout", "-b", feature], env: []) do
            {:ok, ws, feature}
          else
            {:ok, {out, code}} -> {:error, {:clone_failed, {code, String.slice(out, 0, 500)}}}
            {:error, {:timeout, ms}} -> {:error, {:clone_failed, {:git_timeout, ms}}}
            {:error, {:exit, reason}} -> {:error, {:clone_failed, {:git_exit, reason}}}
          end
      end
    end

    # Traduit l'opt PUBLIC `:git_timeout_ms` (vocabulaire bootstrap) en `:timeout_ms` (vocabulaire
    # `Shell.git/2`). Absent → `[]` (le wrapper applique son défaut 30s). Garde la frontière du wrapper
    # honnête (un appelant ne peut pas, par mégarde, passer `:env`/`:cd` arbitraires au clone réseau).
    defp rename_timeout_key([]), do: []
    defp rename_timeout_key(git_timeout_ms: ms), do: [timeout_ms: ms]

    # Épingle HEAD du workspace sur `sha` (capturé hors-pod par l'Executor). Le clone `--branch base`
    # contient déjà `sha` dans le cas nominal (sha = tip) et fast-forward (sha = ancêtre) → `reset
    # --hard` local suffit. Cas pathologique (force-push remote a effacé `sha`) → `fetch` ciblé puis
    # reset. MOVE-1/MA-22 : le `fetch` est RÉSEAU (peut hung/prompter) → BORNÉ via `Shell.git/2` (le
    # `reset` local l'est aussi, pour ne laisser aucun `System.cmd git` nu). Retour homogène avec
    # `Shell.git/2` (`{:ok, {out, code}}` | `{:error, {:timeout|:exit, _}}`), consommé par le `with`
    # de `clone_or_skip`. nil/"" = no-op succès.
    defp pin_base_sha(_ws, sha) when sha in [nil, ""], do: {:ok, {"", 0}}

    defp pin_base_sha(ws, sha) when is_binary(sha) do
      case Fleet.Credentials.Shell.git(["-C", ws, "reset", "--hard", sha], env: []) do
        {:ok, {_, 0}} = ok ->
          ok

        _ ->
          # Le `reset` local a échoué (`sha` absent localement) → fetch RÉSEAU ciblé (auth forge + borne
          # anti-prompt via `git_env/0`), puis re-reset local. Échec du fetch (incl. timeout/exit) →
          # remonté tel quel au `with` → `{:clone_failed, ...}`.
          case Fleet.Credentials.Shell.git(["-C", ws, "fetch", "origin", sha]) do
            {:ok, {_, 0}} ->
              Fleet.Credentials.Shell.git(["-C", ws, "reset", "--hard", sha], env: [])

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

        # MA-22/F-BOOT-FM-03 — PARITÉ avec `clone_or_skip` : un pod prédécesseur MORT laisse son `work/`
        # sur disque ; le pod_id étant déterministe, le re-dispatch retombe sur le même `pod_dir` →
        # `git clone` refuserait (« destination already exists and is not an empty directory ») → même
        # wedge permanent que le workspace (sauf que `clone_work_doc` n'avait pas le `rm_rf`). Clean
        # slate : le `work/` résiduel ne peut venir que d'un prédécesseur mort (le pod possède son
        # pod_dir) → un re-clone frais est toujours correct.
        _ = File.rm_rf(doc)

        # --single-branch : la branche doc est orpheline ⇒ inutile de fetch le reste de l'historique.
        # MOVE-1/MA-22 : clone RÉSEAU BORNÉ via `Shell.git/2` (anti-prompt + auth forge via `git_env/0`,
        # tué dans la deadline si hung → pas de pod figé sur le clone de la doc).
        case Fleet.Credentials.Shell.git(
               ["clone"] ++
                 ref_args ++ ["--branch", work_branch, "--single-branch", repo_url, doc]
             ) do
          {:ok, {_, 0}} ->
            {:ok, doc}

          {:ok, {out, code}} ->
            {:error, {:work_doc_clone_failed, {work_branch, code, String.slice(out, 0, 500)}}}

          {:error, {:timeout, ms}} ->
            {:error, {:work_doc_clone_failed, {work_branch, :git_timeout, ms}}}

          {:error, {:exit, reason}} ->
            {:error, {:work_doc_clone_failed, {work_branch, :git_exit, reason}}}
        end
      end
    end

    # F087/F095 — `forge_auth_args/0` (dup byte-à-byte de Fleet.Pipeline.Git, justifiée jadis par le
    # cycle compile pipeline⇄bootstrap) RETIRÉE. Source unique `Fleet.Credentials.ForgeAuth.git_env/0`
    # (fleet_credentials est en-dessous des deux apps → pas de cycle), token via env hors argv.

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

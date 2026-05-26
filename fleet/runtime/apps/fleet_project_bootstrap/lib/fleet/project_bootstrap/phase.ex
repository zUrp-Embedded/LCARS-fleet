defmodule Fleet.ProjectBootstrap.CapAccess do
  @moduledoc """
  Accès tolérant à `%Fleet.CapProfile{spec: %{...}}` (struct OU map à clés
  atom/string). Module sibling autonome (compilé avant `Phase.*`) — les
  sous-phases l'importent sans dépendre de l'ordre de compilation du module
  englobant (un `import` du module parent depuis un module nested du même
  fichier échoue : parent pas encore compilé → `module_info/1 undefined`).
  Fonction pure (Iron Law — aucun process).
  """

  @spec cap(term(), [atom()], term()) :: term()
  def cap(cp, path, default \\ nil) do
    Enum.reduce(path, cp, fn
      key, %{} = acc -> Map.get(acc, key) || Map.get(acc, to_string(key))
      _key, _acc -> nil
    end) || default
  end
end

defmodule Fleet.ProjectBootstrap.Phase do
  @moduledoc """
  Les 5 sous-phases de `Fleet.ProjectBootstrap.prepare/3` (DN
  ring1/fleet_project_bootstrap.md §"Contrat technique"). Fonctions pures
  (Iron Law — aucun process). Erreurs typées (exit codes DN).
  Helper d'accès cap-profile : `Fleet.ProjectBootstrap.CapAccess`.
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
    import Fleet.ProjectBootstrap.CapAccess, only: [cap: 2, cap: 3]

    @spec clone_or_skip(Path.t(), struct(), keyword()) ::
            {:ok, Path.t(), String.t() | nil} | {:error, term()}
    def clone_or_skip(pod_dir, cap_profile, opts) do
      spec = cap(cap_profile, [:spec], %{})
      project = cap(spec, [:project])

      case project && (Map.get(project, :repo_path) || Map.get(project, "repo_path")) do
        nil ->
          ws = Path.join(pod_dir, "workspace")

          case File.mkdir_p(ws) do
            :ok -> {:ok, ws, nil}
            {:error, r} -> {:error, {:clone_failed, r}}
          end

        repo_url ->
          ws = Path.join(pod_dir, "workspace")
          ref = Map.get(project, :reference_repo_path) || Map.get(project, "reference_repo_path")
          base = Map.get(project, :base_branch) || Map.get(project, "base_branch") || "main"
          slug = Keyword.get(opts, :slug, "work")
          pod_id = Path.basename(pod_dir) |> String.replace_prefix("pod-", "")
          feature = "feature/#{pod_id}-#{slug}"
          ref_args = if ref, do: ["--reference", ref], else: []

          with {_, 0} <-
                 System.cmd("git", ["clone"] ++ ref_args ++ ["--branch", base, repo_url, ws],
                   stderr_to_stdout: true
                 ),
               {_, 0} <-
                 System.cmd("git", ["-C", ws, "checkout", "-b", feature], stderr_to_stdout: true) do
            {:ok, ws, feature}
          else
            {out, code} -> {:error, {:clone_failed, {code, String.slice(out, 0, 500)}}}
          end
      end
    end
  end

  defmodule InitMimic do
    @moduledoc """
    Phase 3 — `/init` mimic vanilla : rend `templates/claude-md-vanilla.md`
    (EEx) → `<workspace>/CLAUDE.md`. L'agent découvre un projet post-/init,
    ne réinvoque pas `/init`.
    """
    import Fleet.ProjectBootstrap.CapAccess, only: [cap: 3]
    @spec init_mimic(Path.t(), struct()) :: {:ok, Path.t()} | {:error, term()}
    def init_mimic(workspace, cap_profile) do
      tpl =
        Application.app_dir(:fleet_project_bootstrap, "priv/templates/claude-md-vanilla.md.eex")

      spec = cap(cap_profile, [:spec], %{})
      project = cap(spec, [:project], %{})

      assigns = [
        project_name: Map.get(project, :name) || Map.get(project, "name") || "project",
        project_intent: Map.get(project, :intent) || Map.get(project, "intent") || "",
        pod_role:
          cap(cap_profile, [:metadata], %{})[:name] ||
            cap(cap_profile, [:metadata], %{})["name"] || "worker"
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
    import Fleet.ProjectBootstrap.CapAccess, only: [cap: 3]

    @spec prepare_mount_binds(Path.t(), struct()) ::
            {:ok, [{Path.t(), Path.t(), :ro | :rw}]} | {:error, term()}
    def prepare_mount_binds(_pod_dir, cap_profile) do
      knowledge = cap(cap_profile, [:spec, :knowledge], %{})
      skills = Map.get(knowledge, :skills) || Map.get(knowledge, "skills") || []
      pod_role = cap(cap_profile, [:metadata], %{})[:name] || "worker"
      home = System.user_home!()

      binds =
        if skills == [] do
          []
        else
          [
            {Path.join(home, ".claude/plugins/superpowers"),
             "/home/#{pod_role}/.claude/plugins/superpowers", :ro}
          ]
        end

      {:ok, binds}
    end
  end
end

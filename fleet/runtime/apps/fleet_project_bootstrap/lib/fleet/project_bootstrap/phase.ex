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

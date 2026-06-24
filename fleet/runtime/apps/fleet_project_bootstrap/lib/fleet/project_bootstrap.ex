defmodule Fleet.ProjectBootstrap do
  @moduledoc """
  Core du pod : prépare le pod_dir vanilla AVANT spawn.

  `prepare/3` orchestre 5 sous-phases (ALLOCATE → CLONE → INIT_MIMIC → BIND_CREDENTIALS →
  PREPARE_MOUNT_BINDS), mais **seul `Phase.Clone` est câblé en PROD** : `Fleet.Spawner.Pod`
  (`maybe_bootstrap_project_workspace`) appelle `Phase.Clone` DIRECTEMENT. Les autres concerns du bootstrap
  sont assurés en prod par des chemins **INDÉPENDANTS de `prepare/3`** : le CLAUDE.md par `do_project`
  (pod.ex), les mounts/creds par bwrap (creds Anthropic-natif, le claudeDir du compte de l'humain est
  bindé en `~/.claude`, refresh délégué au lockfile natif Anthropic). `prepare/3` + les 4 phases
  non-Clone ne sont appelés QUE par `conformance_test` (scaffold non-câblé) — revive-vs-remove est une
  décision d'architecture ouverte.

  Invariant cardinal : l'agent dans le pod **ne voit aucune trace de la mécanique LCARS** hors workspace
  vanilla + plugins. ⚠ **NON testé en hermétique sur le chemin PROD** (il dépend de la vue sandbox bwrap ; le
  `conformance_test` ne couvre que `prepare/3` = chemin mort → vert-creux) → besoin d'un test-intégration
  sandbox.
  """

  alias Fleet.ProjectBootstrap.Phase

  @type bootstrap_result :: %{
          pod_dir: Path.t(),
          workspace: Path.t(),
          branch: String.t() | nil,
          claude_md_path: Path.t(),
          credentials_env: %{String.t() => String.t()},
          mount_binds: [{Path.t(), Path.t(), :ro | :rw}]
        }

  @spec prepare(pod_id :: String.t(), cap_profile :: struct(), opts :: keyword()) ::
          {:ok, bootstrap_result()} | {:error, term()}
  def prepare(pod_id, cap_profile, opts \\ []) do
    with {:ok, pod_dir} <- Phase.Allocate.allocate(pod_id, cap_profile, opts),
         {:ok, workspace, branch} <- Phase.Clone.clone_or_skip(pod_dir, cap_profile, opts),
         {:ok, claude_md_path} <- Phase.InitMimic.init_mimic(workspace, cap_profile),
         {:ok, creds_env} <- Phase.BindCredentials.bind_credentials(pod_dir, cap_profile),
         {:ok, mount_binds} <- Phase.PrepareMountBinds.prepare_mount_binds(pod_dir, cap_profile) do
      {:ok,
       %{
         pod_dir: pod_dir,
         workspace: workspace,
         branch: branch,
         claude_md_path: claude_md_path,
         credentials_env: creds_env,
         mount_binds: mount_binds
       }}
    end
  end
end

defmodule Fleet.ProjectBootstrap do
  @moduledoc """
  Lot 2 — core du pod : prépare le pod_dir vanilla AVANT spawn.

  DN : `ring1/fleet_project_bootstrap.md`. Invoqué par `Fleet.Spawner.Pod`
  en phase PROJECT du cycle 8 phases (chantier 6 PROMOTED).

  Invariant cardinal (SP positif appliqué au bootstrap) : l'agent dans le pod
  **ne voit aucune trace de la mécanique LCARS** hors workspace projet vanilla
  + plugins mount-bindés. Test conformance CI gate OBLIGATOIRE.

  5 sous-phases pures (Iron Law — File/Path/git/:eex, aucun process) :
  ALLOCATE → CLONE → INIT_MIMIC → BIND_CREDENTIALS → PREPARE_MOUNT_BINDS.
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
    with {:ok, pod_dir} <- Phase.Allocate.allocate(pod_id, cap_profile),
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

defmodule Fleet.Spawner.Pod.Backend do
  @moduledoc """
  VIE & MORT du backend OS d'un pod — île extraite de `Fleet.Spawner.Pod`.

  Tout ce qui TUE le process OS du pod et libère ses ressources host : teardown du backend
  (Port BEAM → SIGTERM du holder bwrap/host, ou kill SOCK-AWARE de la session tmux survivante),
  reap d'un orphelin avant un (re)launch, provisioning/libération de la socket MCP per-pod, et les
  résolveurs de chemins des launchers (`bwrap`/`host`/`claude`). Le `Pod` lui passe le `state` (ou un
  `port`/`pod_id`) en argument ; le module ne rappelle AUCUN private de `Pod` (pas de cycle).

  Ce module N'ORCHESTRE PAS : les CALLBACKS/ÉTATS (`terminate/3`,
  `handle_event({:call, from}, :kill, ...)`, les états `:releasing`/`:launching`/`:projecting`, la fn
  `do_launch_backend`) RESTENT au cœur du `Pod` ; ils appellent `Backend.*` pour le geste OS.

  ## Contrat (appelé par `Pod`)

  - `teardown_backend(state)` — Port vivant → `terminate_pod_port` (SIGTERM du holder puis close ;
    `Port.close` SEUL orphelinerait le holder `sleep infinity`) ; sinon kill SOCK-AWARE de la session
    tmux + retrait du sock-dir. Idempotent. Appelé par `terminate/3`,
    `handle_event({:call, from}, :kill, ...)` et l'état `:releasing`.
  - `reap_orphan_pod(pod_id)` — reap d'un orphelin (bwrap/tmux/claude survivant à un crash du process
    pod gen_statem) du même pod_id AVANT un (re)launch. No-op si pas d'orphelin vivant. Appelé par l'état
    `:launching`.
  - `terminate_pod_port(port)` / `safe_port_close(port)` — **publiques** (testées en direct) : SIGTERM
    l'os_pid du holder puis ferme le Port (race `ArgumentError` absorbée). Le test les exerce DIRECTEMENT
    via `Fleet.Spawner.Pod.Backend.terminate_pod_port/1` / `.safe_port_close/1` (plus de `defdelegate`
    côté `Pod` : appel direct sur le sous-module).
  - `ensure_pod_socket(pod_id)` — crée la socket MCP per-pod AVANT le launch → `{:ok, socket_path}`
    (chemin host). Appelé par l'état `:projecting` (le fichier DOIT exister avant le bind bwrap).
  - `release_pod_socket(state)` — arrête le listener + retire le fichier socket (self-protégé, ne lève
    JAMAIS) ; clause `_state` (pod_id absent) = no-op. Appelé par l'`after` de `terminate/3`.
  - `launch_backend/0` — résolveur du backend de lancement (`Fleet.Spawner.LaunchBackend.resolved/0`,
    source unique). Appelé par `do_launch_backend`.
  - `bwrap_launch_path/0` / `host_launch_path/0` / `claude_launch_path/0` — résolveurs de chemins des
    launchers (config `:fleet_spawner`). Appelés par l'état `:launching`.

  `require Logger` (reap/teardown/release loggent). Alias `Fleet.Spawner.PodTmux` (`kill_holder`,
  `sock_path`, `alive?`). En plein qualif : `Fleet.Spawner.LaunchBackend`, `Application`, et le SEAM
  RUNTIME `apply(mcp_socket_provisioner(), ...)` (provisionneur MCP résolu au runtime — `fleet_spawner`
  Ring 1 ne peut PAS dépendre compile-time de `fleet_mcp` Ring 3, dep inversée interdite). Aucune
  dépendance vers `Fleet.Spawner.Pod` (pas de cycle).
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  # Reap un orphelin (bwrap/tmux/claude survivant à un crash du process pod gen_statem) du même pod_id
  # avant un (re)launch. Ne fait RIEN si aucun orphelin vivant (cas pod neuf). Le kill (tmux kill-server +
  # pkill -f ancré) est centralisé dans `PodTmux.kill_holder/1` (anti self-kill).
  def reap_orphan_pod(pod_id) do
    if PodTmux.alive?(pod_id) do
      Logger.warning("pod #{pod_id} : orphelin vivant détecté avant launch (BL-036) — reap")
      PodTmux.kill_holder(pod_id)
    end

    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} reap_orphan échec (non-bloquant): #{inspect(e)}")
      :ok
  end

  # Teardown du backend du pod. Port vivant → Port.close (le SIGTERM du holder bwrap fait tomber
  # namespace+tmux+claude). Port déjà mort mais session bwrap/tmux/claude survivante → kill
  # SOCK-AWARE.
  def teardown_backend(state) do
    cond do
      is_port(state.port) and Port.info(state.port) ->
        terminate_pod_port(state.port)

      is_binary(state.tmux_session) ->
        # La session du pod bwrap (`lcars-pod-<id>`) vit sur le sock PAR-POD (PodTmux), PAS
        # le serveur tmux par défaut. Un kill ciblant le défaut serait un no-op silencieux →
        # le claude sandboxé continuerait à consommer l'OAuth. On kill via le sock par-pod
        # (même geste que reap_orphan_pod), centralisé dans `PodTmux.kill_holder/1` (anti self-kill).
        PodTmux.kill_holder(state.pod_id)

      true ->
        :ok
    end

    # Retire le sock-dir APRÈS le kill. Le kill est fiable (terminate_pod_port ET kill_holder tuent
    # claude+namespace) → pas besoin de garder le sock-dir « tant que le kill n'est pas sûr ». Sans ce
    # nettoyage, le sock-dir traînerait après un teardown gracieux → le PodWarden le ramasserait ~60s
    # plus tard en loguant un FAUX « orphelin persistant » (bruit qui masque les vrais). Le PodWarden
    # reste le filet des VRAIS orphelins (process pod gen_statem crashé → teardown jamais exécuté → sock-dir + claude
    # survivent → reap). Gardé `tmux_session` : pods réels (bwrap/host), pas StubBackend (sock_path
    # nominal, rm_rf no-op de toute façon).
    _ =
      if is_binary(state.tmux_session) do
        PodTmux.remove_sock_dir(state.pod_id)
      end

    :ok
  end

  @doc """
  Tue le pod (chaîne bwrap OU host — geste générique). Le holder (`sleep infinity`) IGNORE l'EOF stdin →
  `Port.close` seul l'ORPHELINE (le pod survit). On SIGTERM donc le process holder
  par son os_pid :
  - **bwrap** : bwrap propage au holder → PID1 exit → namespace + serveur tmux + claude tombent ensemble
    (`--die-with-parent` = filet si le BEAM meurt avant d'arriver ici).
  - **host** : pas de namespace → le holder `host_launch.sh` trap le SIGTERM → `tmux
    kill-server` explicite sur le sock par-pod (teardown self-contained ; cf. `bin/host_launch.sh`).
  Port.close ensuite (libère le port BEAM). Public pour test direct.
  """
  @spec terminate_pod_port(port()) :: :ok
  def terminate_pod_port(port) do
    _ =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

    safe_port_close(port)
  end

  @doc """
  Ferme le port BEAM en absorbant l'`ArgumentError` de RACE : le port peut se fermer
  entre notre check et le close (claude finit tout seul après submit_result → son process
  exit → le port disparaît). La garde `Port.info` seule est insuffisante (TOCTOU) — un port
  déjà fermé EST l'état voulu, donc on rescue plutôt que crash (sinon `:erlang.port_close`
  ArgumentError dans l'état `:releasing` → le process pod gen_statem crasherait sur une complétion RÉUSSIE).
  Public pour test direct.
  """
  @spec safe_port_close(port()) :: :ok
  def safe_port_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Délègue à la source unique du backend (config + défaut canon vivent dans LaunchBackend) —
  # le spawn et la readiness lisent le MÊME résolveur, pas deux copies du défaut.
  def launch_backend, do: Fleet.Spawner.LaunchBackend.resolved()

  # SEAM RUNTIME du provisionneur de socket MCP per-pod. `fleet_spawner` est Ring 1, `fleet_mcp` est
  # Ring 3 : une dep mix.exs `fleet_spawner → fleet_mcp` serait une dépendance INVERSÉE (ring bas → ring
  # haut), INTERDITE. On résout donc le module au RUNTIME (`Application.get_env` + `apply`), exactement
  # comme `Fleet.MCP.PodTools` appelle `Fleet.Pilot.ForgeClient`/`ProjectOnboard`/`Fleet.Spawner` : le
  # défaut est un ATOM littéral (pas un `alias`/appel direct) → AUCUNE dep compile-time, donc aucun cycle.
  # L'umbrella démarre toutes les apps → `Fleet.MCP.PodSocketSupervisor` est vivant quand le pod tourne.
  # Override en test : `:mcp_socket_provisioner` = un stub qui rend un chemin SANS créer de vrai socket
  # `/run/lcars/...` (mirror du pattern `launch_backend: StubBackend`).
  defp mcp_socket_provisioner,
    do:
      Application.get_env(:fleet_spawner, :mcp_socket_provisioner, Fleet.MCP.PodSocketSupervisor)

  # ENSURE (état :projecting, avant le launch) : crée le listener + le fichier socket de CE pod (idempotent côté
  # central) et rend `{:ok, socket_path}` (chemin host). Le fichier DOIT exister avant le bind bwrap.
  def ensure_pod_socket(pod_id) when is_binary(pod_id) do
    apply(mcp_socket_provisioner(), :ensure_pod_socket, [pod_id])
  end

  # RELEASE (filet terminate/3, clause `after`) : arrête le listener ET retire le fichier socket (idempotent
  # côté central). Self-protégé (rescue/catch → log, rend `:ok`) : il tourne dans l'`after` de `terminate`,
  # un raise s'y propagerait et masquerait la raison d'arrêt. Clause `_state` (pod_id absent) = no-op.
  def release_pod_socket(%{pod_id: pod_id}) when is_binary(pod_id) do
    _ = apply(mcp_socket_provisioner(), :release_pod_socket, [pod_id])
    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{pod_id} release_pod_socket a levé (non-fatal) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning("pod #{pod_id} release_pod_socket #{kind} (non-fatal) — #{inspect(value)}")
      :ok
  end

  def release_pod_socket(_state), do: :ok

  def bwrap_launch_path, do: launcher_path(:bwrap_launch_path, "bwrap_launch.sh")

  # Launcher N0 host (containment: none) — frère sans-sandbox de bwrap_launch, même argv-shape.
  def host_launch_path, do: launcher_path(:host_launch_path, "host_launch.sh")

  def claude_launch_path, do: launcher_path(:claude_launch_path, "claude_launch.sh")

  # Résolution UNIQUE d'un chemin de launcher : config `:fleet_spawner` (clé = nom du launcher),
  # défaut = l'install canonique `/usr/local/bin/<basename>` (posée par `etc/install.sh`). Les trois
  # publics ci-dessus (API inchangée) sont des one-liners dessus — un seul endroit porte la forme
  # config-key → défaut, pas trois copies à désaligner.
  defp launcher_path(config_key, default_basename) do
    Application.get_env(:fleet_spawner, config_key, "/usr/local/bin/" <> default_basename)
  end
end

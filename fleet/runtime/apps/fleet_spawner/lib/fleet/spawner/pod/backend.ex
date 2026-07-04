defmodule Fleet.Spawner.Pod.Backend do
  @moduledoc """
  VIE & MORT du backend OS d'un pod — île extraite de `Fleet.Spawner.Pod`.

  Le PROCESS OS du pod, de bout en bout : les résolveurs de chemins des launchers qui le lancent
  (`bwrap`/`host`/`claude` — la VIE), le résolveur du backend de lancement, le teardown qui le tue
  (Port BEAM → SIGTERM du holder bwrap/host, ou kill SOCK-AWARE de la session tmux survivante — la
  MORT) et le reap d'un orphelin avant un (re)launch. Le cycle de vie de la SOCKET MCP per-pod ne
  vit PLUS ici (recentrage 2026-07-05) : tout le canal MCP (socket + `.mcp-fleet.json` + env) est
  dans `Pod.McpProvision`. Le `Pod` lui passe le `state` (ou un `port`/`pod_id`) en argument ; le
  module ne rappelle AUCUN private de `Pod` (pas de cycle).

  Ce module N'ORCHESTRE PAS : les CALLBACKS/ÉTATS (`terminate/3`,
  `handle_event({:call, from}, :kill, ...)`, les états `:releasing`/`:launching`, la fn
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
  - `launch_backend/0` — résolveur du backend de lancement (`Fleet.Spawner.LaunchBackend.resolved/0`,
    source unique). Appelé par `do_launch_backend`.
  - `bwrap_launch_path/0` / `host_launch_path/0` / `claude_launch_path/0` — résolveurs de chemins des
    launchers (config `:fleet_spawner`). Appelés par l'état `:launching`.

  `require Logger` (reap/teardown loggent). Alias `Fleet.Spawner.PodTmux` (`kill_holder`,
  `sock_path`, `alive?`) ; en pleine qualif `Fleet.Spawner.LaunchBackend` et `Application`. Aucune
  dépendance vers `Fleet.Spawner.Pod` (pas de cycle).
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  @doc """
  Reap un orphelin (bwrap/tmux/claude survivant à un crash du process pod gen_statem) du même
  pod_id avant un (re)launch. Ne fait RIEN si aucun orphelin vivant (cas pod neuf). Le kill
  (tmux kill-server + pkill -f ancré) est centralisé dans `PodTmux.kill_holder/1` (anti self-kill).
  Best-effort (rescue → log) : un reap qui lève ne bloque pas le launch.
  """
  @spec reap_orphan_pod(String.t()) :: :ok
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

  @doc """
  Teardown du backend du pod. Port vivant → `terminate_pod_port` (le SIGTERM du holder bwrap fait
  tomber namespace+tmux+claude). Port déjà mort mais session bwrap/tmux/claude survivante → kill
  SOCK-AWARE (`PodTmux.kill_holder/1`). Idempotent — appelé par `terminate/3` (filet), le call
  `:kill` et l'état `:releasing` ; le double appel est inoffensif.
  """
  @spec teardown_backend(map()) :: :ok
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

  @doc """
  Backend de lancement résolu. Délègue à la source unique (config + défaut canon vivent dans
  `Fleet.Spawner.LaunchBackend.resolved/0`) — le spawn et la readiness lisent le MÊME résolveur,
  pas deux copies du défaut. Appelé par `do_launch_backend` et l'état `:projecting` (provisioning MCP).
  """
  @spec launch_backend() :: module()
  def launch_backend, do: Fleet.Spawner.LaunchBackend.resolved()

  @doc """
  Chemin du launcher N0 bwrap (`bwrap_launch.sh` — sandbox, containment par défaut). Config
  `:fleet_spawner, :bwrap_launch_path`, défaut install canonique `/usr/local/bin/`.
  """
  @spec bwrap_launch_path() :: String.t()
  def bwrap_launch_path, do: launcher_path(:bwrap_launch_path, "bwrap_launch.sh")

  @doc """
  Chemin du launcher N0 host (`host_launch.sh` — containment: none, frère sans-sandbox de
  bwrap_launch, même argv-shape). Config `:fleet_spawner, :host_launch_path`.
  """
  @spec host_launch_path() :: String.t()
  def host_launch_path, do: launcher_path(:host_launch_path, "host_launch.sh")

  @doc """
  Chemin du launcher vendor N1 (`claude_launch.sh` — la frontière vendor EST ce script). Config
  `:fleet_spawner, :claude_launch_path`.
  """
  @spec claude_launch_path() :: String.t()
  def claude_launch_path, do: launcher_path(:claude_launch_path, "claude_launch.sh")

  # Résolution UNIQUE d'un chemin de launcher : config `:fleet_spawner` (clé = nom du launcher),
  # défaut = l'install canonique `/usr/local/bin/<basename>` (posée par `etc/install.sh`). Les trois
  # publics ci-dessus (API inchangée) sont des one-liners dessus — un seul endroit porte la forme
  # config-key → défaut, pas trois copies à désaligner.
  defp launcher_path(config_key, default_basename) do
    Application.get_env(:fleet_spawner, config_key, "/usr/local/bin/" <> default_basename)
  end
end

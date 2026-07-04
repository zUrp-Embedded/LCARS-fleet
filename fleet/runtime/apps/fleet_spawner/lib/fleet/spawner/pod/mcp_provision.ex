defmodule Fleet.Spawner.Pod.McpProvision do
  @moduledoc """
  Le CANAL MCP pod↔fleet, de bout en bout — île extraite de `Fleet.Spawner.Pod`.

  Le serveur MCP `fleet` est le canal de comm UNIQUE pod↔fleet (jamais de scraping). Ce module
  porte TOUT le canal (recentrage 2026-07-05 — le lifecycle socket vivait dans `Pod.Backend`,
  module « vie & mort du process OS », où il était le concern orphelin) :

  - la **SOCKET AF_UNIX per-pod** : `ensure_pod_socket/1` (création avant launch) /
    `release_pod_socket/1` (libération au terminate) via le SEAM RUNTIME
    `:mcp_socket_provisioner` ;
  - le **`.mcp-fleet.json`** (`alwaysLoad:true`) que claude charge au boot + la copie du bridge
    stdio (`fleet_mcp_bridge.py`) DANS le pod (`maybe_provision_mcp_config/5`) ;
  - les **env vars MCP** du process pod (`mcp_channel_env/2`).

  Le module ne lit PAS le `state` du Pod et ne rappelle AUCUN private de Pod — le Pod résout le
  placement (`pod_dir`, `sandbox_home`) et le backend, puis passe ces valeurs en arguments. Aucune
  mutation de state, aucun Port, aucun timer.

  ## Contrat (appelé par `Pod`)

  - `ensure_pod_socket/1` — état `:projecting`, AVANT le launch (le fichier socket DOIT exister
    avant le bind bwrap) → `{:ok, socket_path}` (chemin host).
  - `maybe_provision_mcp_config/5` — dans le `with` de l'état `:projecting`. Retourne
    `:ok` (StubBackend sans spec, ou écriture réussie) | `{:error, {:mcp_server_spec_required, backend}}`
    (backend RÉEL sans spec, fail-loud) | `{:error, reason}` (échec FS : `{:write_failed, …}` /
    `{:mcp_bridge_provision_failed, …}`). L'erreur est propagée au `with` → `transition_failed`.
  - `mcp_channel_env/2` — env vars MCP du process pod à merger dans l'env de launch (état `:launching`).
  - `release_pod_socket/1` — l'`after` de `terminate/3` (self-protégé, ne lève JAMAIS).

  La spec serveur MCP est lue en config (`:fleet_spawner, :mcp_server_spec`) ; le backend résolu
  est passé par le Pod (source unique `Fleet.Spawner.LaunchBackend.resolved/0`).
  """

  require Logger

  alias Fleet.Spawner.Pod.Fs

  # SEAM RUNTIME du provisionneur de socket MCP per-pod. `fleet_spawner` est Ring 1, `fleet_mcp` est
  # Ring 2 (au-dessus) : une dep mix.exs `fleet_spawner → fleet_mcp` serait une dépendance INVERSÉE
  # (ring bas → ring haut), INTERDITE. On résout donc le module au RUNTIME (`Application.get_env` +
  # `apply`), exactement comme `Fleet.MCP.PodTools` appelle `Fleet.Pilot.ForgeClient`/`Fleet.Spawner` :
  # le défaut est un ATOM littéral (pas un `alias`/appel direct) → AUCUNE dep compile-time, donc aucun
  # cycle. L'umbrella démarre toutes les apps → `Fleet.MCP.PodSocketSupervisor` est vivant quand le pod
  # tourne. Override en test : `:mcp_socket_provisioner` = un stub qui rend un chemin SANS créer de
  # vrai socket (mirror du pattern `launch_backend: StubBackend`).
  defp mcp_socket_provisioner,
    do:
      Application.get_env(:fleet_spawner, :mcp_socket_provisioner, Fleet.MCP.PodSocketSupervisor)

  @doc """
  ENSURE (état `:projecting`, avant le launch) : crée le listener + le fichier socket de CE pod
  (idempotent côté central) et rend `{:ok, socket_path}` (chemin host). Le fichier DOIT exister
  avant le bind bwrap — un échec est propagé au `with` → `transition_failed`.
  """
  @spec ensure_pod_socket(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_pod_socket(pod_id) when is_binary(pod_id) do
    apply(mcp_socket_provisioner(), :ensure_pod_socket, [pod_id])
  end

  @doc """
  RELEASE (filet `terminate/3`, clause `after`) : arrête le listener ET retire le fichier socket
  (idempotent côté central). Self-protégé (rescue/catch → log, rend `:ok`) : il tourne dans
  l'`after` de `terminate`, un raise s'y propagerait et masquerait la raison d'arrêt. Clause
  `_state` (pod_id absent) = no-op.
  """
  @spec release_pod_socket(map()) :: :ok
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

  # Serveur MCP fleet (canal de comm UNIQUE pod↔fleet ; jamais de scraping).
  # Config = chemin pod-accessible (hors /home,/tmp, comme bwrap/claude_launch). Un pod
  # RÉEL parle MCP, point — il n'y a PAS de mode fichier alternatif. `nil` n'est légitime QUE pour
  # les tests à launch-stub (claude pas lancé) ; un backend réel (LauncherPortBackend) sans spec MCP est un
  # bug de config (le brief instruit submit_result, impossible sans serveur).
  #
  # UN seul mécanisme paramétré : la config fournit la spec serveur (`command`/`args`/`env`),
  # on y force `alwaysLoad`. La spec décide — PROD : pont stdio→central via une socket AF_UNIX per-pod
  # (chemin posé per-pod en `LCARS_FLEET_MCP_SOCKET`), TESTS : fixture file-backed. Même mécanisme, spec différente.
  defp mcp_server_spec, do: Application.get_env(:fleet_spawner, :mcp_server_spec)

  @doc """
  Le spec serveur MCP est-il configuré (`:fleet_spawner, :mcp_server_spec`) ? Accesseur PUBLIC =
  SOURCE UNIQUE de cette lecture pour les sondes cross-app (`Fleet.API.Readiness`) : elles délèguent
  au propriétaire de la clé au lieu de relire `Application.get_env(:fleet_spawner, …)` (couplage
  implicite au nom de clé → `nil` silencieux si la clé est renommée). Même pattern que
  `Fleet.Spawner.LaunchBackend.resolved/0`.
  """
  @spec server_spec_present?() :: boolean()
  def server_spec_present?, do: not is_nil(mcp_server_spec())

  @doc """
  Env vars MCP à propager au pod (consommées par bridge.py côté pod). `LCARS_POD_ID` est TOUJOURS
  posé : nécessaire pour que bridge.py injecte `_lcars_pod_id` dans chaque tool call MCP
  (corrélation côté central PodTools, filtrage TaskQueue.next_for). Sans ça le pod est anonyme —
  get_work_item ne retournerait QUE les untargeted (rate les tasks ciblées via wake_pod).

  `LCARS_ROLE` (= `metadata.name` du cap-profile = rôle métier) : bridge.py l'injecte en
  `_lcars_role`. Ce champ du fil est INDICATIF (surface de tools du pod, descriptif), PAS la
  source de la décision de token de rôle : `PodTools.create_issue` résout le rôle depuis le SPAWN
  (`pod_id → role` gravé côté serveur, `Fleet.Spawner.pod_info`), pas du wire (non authentifié →
  usurpation). Posé ICI (env du process pod) → couvre host_launch ET bwrap (qui le re-`--setenv`
  dans son sandbox).

  Plus de `LCARS_POD_CAPABILITY` : l'identité du pod n'est plus un secret présenté sur le fil mais
  le CANAL lui-même — chaque pod a sa socket MCP AF_UNIX (montée dans son seul sandbox) → « quelle
  socket reçoit » = « quel pod » (cf. `Fleet.MCP.PodSocketAcceptor`). Le chemin de cette socket
  voyage en `LCARS_FLEET_MCP_SOCKET` dans l'env du SERVEUR MCP (`build_fleet_mcp_entry`), pas ici
  (l'env du process pod claude).
  """
  @spec mcp_channel_env(String.t(), String.t() | nil) :: %{String.t() => String.t()}
  def mcp_channel_env(pod_id, role) when is_binary(pod_id) do
    base = %{"LCARS_POD_ID" => pod_id}
    if is_binary(role) and role != "", do: Map.put(base, "LCARS_ROLE", role), else: base
  end

  @doc """
  Écrit `<pod_dir>/.mcp-fleet.json` (+ copie le bridge stdio dans le pod). `backend` est résolu
  par le Pod (`Fleet.Spawner.LaunchBackend.resolved/0`) et passé ici ; la spec serveur est lue en
  config. `socket_path` = chemin host de la socket MCP per-pod (rendu par `ensure_pod_socket/1`,
  état `:projecting`) ; posé tel quel en `LCARS_FLEET_MCP_SOCKET` du serveur (host == namespace,
  cf. `build_fleet_mcp_entry`). Retourne `:ok` (StubBackend sans spec, ou écriture réussie) |
  `{:error, {:mcp_server_spec_required, backend}}` (backend RÉEL sans spec, fail-loud) |
  `{:error, reason}` FS — propagé au `with` de `:projecting` → `transition_failed`.
  """
  @spec maybe_provision_mcp_config(Path.t(), Path.t(), String.t(), Path.t(), module()) ::
          :ok | {:error, term()}
  def maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, socket_path, backend) do
    case {mcp_server_spec(), backend} do
      # Seam test explicite : StubBackend ne lance pas claude → pas de MCP requis.
      {nil, Fleet.Spawner.LaunchBackend.StubBackend} ->
        :ok

      # Un backend RÉEL sans spec MCP est un bug de config — le pod réel parle MCP
      # (le brief instruit submit_result, impossible sans serveur). Refus net
      # (propagé au with de l'état :projecting → transition_failed) qui rend l'état fautif
      # irreprésentable, plutôt qu'un pod lancé puis bloqué en timeout silencieux.
      {nil, backend} ->
        {:error, {:mcp_server_spec_required, backend}}

      {spec, _backend} when is_map(spec) ->
        # Non-bang + retour {:ok|:error} propagé au with chain de l'état `:projecting`
        # (où l'erreur déclenche transition_failed proprement).
        with {:ok, fleet_entry} <-
               build_fleet_mcp_entry(spec, pod_dir, sandbox_home, pod_id, socket_path) do
          config = %{"mcpServers" => %{"fleet" => fleet_entry}}

          Fs.safe_write(
            Path.join(pod_dir, ".mcp-fleet.json"),
            Jason.encode!(config, pretty: true)
          )
        end
    end
  end

  # Construit l'entrée serveur MCP `fleet` du `.mcp-fleet.json`, en provisionnant
  # le bridge stdio DANS le pod_dir.
  #
  # Le bwrap est un SANCTUAIRE — il ne monte que
  # `/usr`, `/etc`, `/sys`, `$POD_DIR`, `$GIT_MIRROR`, le vendor et le sock-dir.
  # `/var/lib/lcars` n'y est PAS monté. Lancer le bridge via son chemin HÔTE
  # (`/var/lib/lcars/bin/...py`) avec un log sous `/var/lib/lcars/` échouerait :
  # DANS le sandbox ce chemin n'existe pas → `bash -c` échoue → le serveur MCP
  # `fleet` ne démarre jamais → le tool `mcp__fleet__get_work_item` n'est jamais chargé
  # → l'agent improvise du curl et timeout. (Un tel bridge marche en test direct
  # car il tourne sur l'HÔTE, pas dans le sandbox.)
  #
  # Côté N1 (le provisioning) : `bwrap_launch.sh` reste MCP-agnostique (N0).
  # On copie le bridge sous `pod_dir/.lcars/` et on résout les placeholders
  # `{{BRIDGE}}`/`{{BRIDGE_LOG}}` de la spec.
  #
  # ⚠ Piège de relocalisation : poser le path HÔTE (`pod_dir = /home/<human>/pods/pod_<id>`) dans
  # le `.mcp-fleet.json` casserait dès lors que bwrap RELOCALISE le pod_dir derrière `/home/.pod`
  # (`sandbox_home`) → le path hôte N'EXISTE PLUS dans le namespace → `bash -c "exec python3 <hôte>.py
  # 2>><hôte>.log"` avorterait au redirect (dossier parent absent) AVANT d'exec python → serveur MCP
  # `fleet` jamais up → 0 tool `mcp__fleet__*`. D'où DEUX chemins distincts : le bridge est COPIÉ sur le
  # path HÔTE (où le spawner écrit), mais le `.mcp-fleet.json` référence le path IN-NAMESPACE
  # (`sandbox_home/.lcars/…`, ce que claude exécute dans le sandbox). Host pods (containment none) :
  # `sandbox_home == pod_dir` → identité (rétro-compat stricte). Sans cette séparation, un pod
  # bwrap n'aurait aucun tool `mcp__fleet__*` (le pont ne démarrerait jamais) — donc aucun moyen de
  # puller son brief ni de soumettre son résultat.
  #
  # Injecte `LCARS_POD_ID` ET `LCARS_FLEET_MCP_SOCKET` dans l'env du serveur (le bridge les lit pour
  # corréler `get_work_item` au bon pod ET savoir SUR QUELLE socket parler au central ; ne pas dépendre de
  # l'héritage env claude→bridge) et force `alwaysLoad:true` (sinon les tools MCP sont déférés derrière
  # ToolSearch, absents du prompt turn-1).
  #
  # ⚠ Host vs namespace pour la SOCKET : contrairement au bridge (host_bridge pour la copie, ns_bridge pour
  # l'argv), le `socket_path` est posé TEL QUEL. Le bind bwrap (R9) montera la socket au MÊME chemin absolu
  # (`--bind X X`) → host == namespace → AUCUN remap. (Host pods, containment none : pas de namespace du
  # tout, le chemin host EST le chemin vu par le pont.) D'où : pas de `sandbox_home` dans le chemin socket.
  defp build_fleet_mcp_entry(spec, pod_dir, sandbox_home, pod_id, socket_path) do
    # HÔTE : où le spawner ÉCRIT réellement le pont (le pod_dir réel sur le disque).
    host_bridge = Path.join([pod_dir, ".lcars", "fleet_mcp_bridge.py"])

    # IN-NAMESPACE : ce que claude EXÉCUTE dans le sandbox (pod_dir remappé → /home/.pod en bwrap).
    ns_bridge = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.py"])
    ns_log = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.log"])

    with :ok <- copy_bridge_into_pod(spec["bridge_source"], host_bridge) do
      args =
        (spec["args"] || [])
        |> Enum.map(fn arg ->
          arg
          |> String.replace("{{BRIDGE}}", ns_bridge)
          |> String.replace("{{BRIDGE_LOG}}", ns_log)
        end)

      pod_env = %{
        "LCARS_POD_ID" => pod_id,
        # Chemin host de la socket per-pod, posé tel quel (host == namespace, cf. note ci-dessus).
        "LCARS_FLEET_MCP_SOCKET" => socket_path
      }

      entry =
        spec
        |> Map.drop(["bridge_source"])
        |> Map.put("args", args)
        |> Map.put("alwaysLoad", true)
        |> Map.update("env", pod_env, &Map.merge(&1, pod_env))

      {:ok, entry}
    end
  end

  # nil = spec sans bridge à projeter (stub/legacy : la spec porte alors un
  # `command`/`args` déjà autonome, pas de placeholder à résoudre).
  defp copy_bridge_into_pod(nil, _dest), do: :ok

  defp copy_bridge_into_pod(source, dest) when is_binary(source) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _bytes} <- File.copy(source, dest),
         :ok <- File.chmod(dest, 0o755) do
      :ok
    else
      {:error, reason} -> {:error, {:mcp_bridge_provision_failed, source, reason}}
    end
  end
end

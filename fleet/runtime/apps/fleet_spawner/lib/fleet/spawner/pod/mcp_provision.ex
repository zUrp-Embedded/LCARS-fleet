defmodule Fleet.Spawner.Pod.McpProvision do
  @moduledoc """
  Provisioning MCP du pod — île d'écritures FS pures, extraite de `Fleet.Spawner.Pod`.

  Le serveur MCP `fleet` est le canal de comm UNIQUE pod↔fleet (jamais de scraping).
  Ce module pose, dans le `pod_dir`, le `.mcp-fleet.json` (`alwaysLoad:true`) que claude
  charge au boot, et copie le bridge stdio (`fleet_mcp_bridge.py`) DANS le pod.

  ## Contrat

  Aucune mutation de state, aucun Port, aucun timer : que des écritures FS déterministes.
  Le module ne lit PAS le `state` du Pod et ne rappelle AUCUN private de Pod — le Pod résout
  le placement (`pod_dir`, `sandbox_home`) et le backend, puis passe ces valeurs en arguments.

  - `maybe_provision_mcp_config/5` — appelé dans la `with` de `do_project`. Retourne
    `:ok` (StubBackend sans spec, ou écriture réussie) | `{:error, {:mcp_server_spec_required, backend}}`
    (backend RÉEL sans spec, fail-loud) | `{:error, reason}` (échec FS : `{:write_failed, …}` /
    `{:mcp_bridge_provision_failed, …}`). L'erreur est propagée au `with` → `transition_failed`.
  - `mcp_channel_env/3` — env vars MCP à merger dans l'env de launch (`do_launch`). Retourne une map.

  La spec serveur MCP est lue en config (`:fleet_spawner, :mcp_server_spec`) ; le backend résolu
  est passé par le Pod (source unique `Fleet.Spawner.LaunchBackend.resolved/0`).
  """

  # Serveur MCP fleet (canal de comm UNIQUE pod↔fleet ; jamais de scraping).
  # Config = chemin pod-accessible (hors /home,/tmp, comme bwrap/claude_launch). Un pod
  # RÉEL parle MCP, point — il n'y a PAS de mode fichier alternatif. `nil` n'est légitime QUE pour
  # les tests à launch-stub (claude pas lancé) ; un backend réel (LauncherPortBackend) sans spec MCP est un
  # bug de config (le brief instruit submit_result, impossible sans serveur).
  #
  # UN seul mécanisme paramétré : la config fournit la spec serveur (`command`/`args`/`env`),
  # on y force `alwaysLoad`. La spec décide — PROD : pont stdio→central (env LCARS_FLEET_MCP_URL),
  # TESTS : fixture file-backed. Même mécanisme, spec différente.
  defp mcp_server_spec, do: Application.get_env(:fleet_spawner, :mcp_server_spec)

  # Env vars MCP à propager au pod (consommés par bridge.py côté pod). `LCARS_POD_ID`
  # est TOUJOURS posé : nécessaire pour que bridge.py injecte `_lcars_pod_id` dans
  # chaque tool call MCP (corrélation côté central PodTools, filtrage TaskQueue.next_for).
  # Sans ça le pod est anonyme — get_task ne retournerait QUE les untargeted (rate les
  # tasks ciblées via wake_pod).
  #
  # `LCARS_ROLE` (= `metadata.name` du cap-profile = rôle métier) : bridge.py l'injecte en `_lcars_role`.
  # Ce champ du fil est INDICATIF (surface de tools du pod, descriptif), PAS la source de la décision
  # de token de rôle : `PodTools.create_ticket` résout le rôle depuis le SPAWN (`pod_id → role` gravé
  # côté serveur, `Fleet.Spawner.pod_info`), pas du wire (non authentifié → usurpation). Posé ICI
  # (env du process pod) → couvre host_launch ET bwrap (qui le re-`--setenv` dans son sandbox).
  #
  # `LCARS_POD_CAPABILITY` (= le secret par-pod, généré au spawn) : bridge.py l'injecte en
  # `_lcars_pod_capability` dans chaque tool-call, exactement comme `LCARS_POD_ID` → `_lcars_pod_id`.
  # Le central VÉRIFIE cette capability contre celle enregistrée pour le pod_id avant de servir le moindre
  # tool corrélé pod (get_task/submit_result/résolution de rôle) : un pod qui présente le pod_id deviné
  # d'un AUTRE pod n'a pas sa capability → REFUS. C'est la fermeture du trou d'usurpation : le pod_id seul
  # ne prouve plus rien. TOUJOURS posée (tout pod spawné par la fleet en reçoit une) ; un pod sans elle
  # ne peut RIEN faire au central (fail-closed, pas de fallback anonyme).
  #
  # `LCARS_FLEET_MCP_CHANNEL_URL` n'est plus posé (push channel ChannelHTTP supprimé,
  # le drive se fait via les tools pull `get_task`).
  def mcp_channel_env(pod_id, role, capability)
      when is_binary(pod_id) and is_binary(capability) do
    base = %{"LCARS_POD_ID" => pod_id, "LCARS_POD_CAPABILITY" => capability}
    if is_binary(role) and role != "", do: Map.put(base, "LCARS_ROLE", role), else: base
  end

  # Écrit `<pod_dir>/.mcp-fleet.json` (+ copie le bridge stdio dans le pod). `backend` est résolu
  # par le Pod (`Fleet.Spawner.LaunchBackend.resolved/0`) et passé ici ; la spec serveur est lue en config.
  def maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, capability, backend) do
    case {mcp_server_spec(), backend} do
      # Seam test explicite : StubBackend ne lance pas claude → pas de MCP requis.
      {nil, Fleet.Spawner.LaunchBackend.StubBackend} ->
        :ok

      # Un backend RÉEL sans spec MCP est un bug de config — le pod réel parle MCP
      # (le brief instruit submit_result, impossible sans serveur). Refus net
      # (propagé au with do_project → transition_failed) qui rend l'état fautif
      # irreprésentable, plutôt qu'un pod lancé puis bloqué en timeout silencieux.
      {nil, backend} ->
        {:error, {:mcp_server_spec_required, backend}}

      {spec, _backend} when is_map(spec) ->
        # Non-bang + retour {:ok|:error} propagé au with chain do_project
        # (où l'erreur déclenche transition_failed proprement).
        with {:ok, fleet_entry} <-
               build_fleet_mcp_entry(spec, pod_dir, sandbox_home, pod_id, capability) do
          config = %{"mcpServers" => %{"fleet" => fleet_entry}}

          safe_write(
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
  # `fleet` ne démarre jamais → le tool `mcp__fleet__get_task` n'est jamais chargé
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
  # puller son mandat ni de soumettre son résultat.
  #
  # Injecte aussi `LCARS_POD_ID` ET `LCARS_POD_CAPABILITY` dans l'env du serveur (le bridge les lit
  # pour corréler `get_task` au bon pod ET prouver son identité au central ; ne pas dépendre de l'héritage
  # env claude→bridge) et force `alwaysLoad:true` (sinon les tools MCP sont déférés derrière ToolSearch,
  # absents du prompt turn-1). La capability est posée ICI, dans l'env du SEUL pont de CE pod : un autre pod
  # ne peut pas la lire (son `.mcp-fleet.json` porte SA propre capability). C'est ce qui rend le pod_id
  # non-suffisant pour usurper — il faut AUSSI le secret, qui ne quitte jamais l'env de son pod.
  defp build_fleet_mcp_entry(spec, pod_dir, sandbox_home, pod_id, capability) do
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
        "LCARS_POD_CAPABILITY" => capability
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

  # Variante non-bang de File.write (mêmes sémantiques que le safe_write de Pod) : retourne
  # {:error, {:write_failed, path, reason}} au lieu de raise → propagation via `with` →
  # transition_failed clean. Local à l'île MCP (pas de rappel reverse vers Pod).
  defp safe_write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end
end

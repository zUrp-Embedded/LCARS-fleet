# LCARS Fleet runtime config — chantier 16 (lancement per-humain via bin/fleet_v2)
#
# Évalué à chaque démarrage du release (post-Mix release build, runtime)
# ET par `mix test` (Mix charge config/runtime.exs dans TOUS les envs).
#
# Garde `config_env() != :test` OBLIGATOIRE : ce fichier est de la
# config de boot (lit des env vars du run humain `~/.lcars/fleet_v2.env`
# inexistantes en test) et il est évalué APRÈS `config/test.exs`. Sans la
# garde, `config :fleet_api, start_listener: true` (l.~) override le
# `start_listener: false` hermétique de test.exs → fleet_api démarre le
# listener Cowboy en test → crash boot → umbrella mort. (Régression B8
# avérée par StarFleet : `rel/runtime.exs` orphelin ne tournait jamais ;
# déplacé en config/runtime.exs il s'active partout — d'où la garde.)
# Cohérent discipline hermétique B4/B5 (config runtime ≠ tests).

import Config

if config_env() != :test do
  # ============================================================
  # R-no-root-runtime (FORGE-D1, Z4) — boot guard anti-root
  # ============================================================
  # Le daemon fleet ne tourne JAMAIS en root (la BEAM tourne sous l'UID de l'humain ; ce
  # self-check attrape les lancements dev/manuel en root, où ~/.gitea_token
  # résoudrait /root/.gitea_token = token admin — cf. FORGE-D1). starfleet/
  # sysadmin est HORS-fleet (invoqué hors daemon) → pas d'exception ici. Hygiène,
  # pas défense anti-adversaire (threat-model coopératif). Garde `== :prod` : ne
  # gêne ni le dev ni `mix lcars.contracts.check` (qui tourne en :dev).
  if config_env() == :prod do
    {uid, 0} = System.cmd("id", ["-u"])

    if String.trim(uid) == "0" do
      raise "R-no-root-runtime : le daemon fleet refuse de tourner en root " <>
              "(lancer sous ton UID humain via bin/fleet_v2, jamais en root)"
    end
  end

  # Z6 (CFG-CR) — parse entier d'un env var SANS crash-boot opaque. Malformé → raise CLAIR
  # (un port/intervalle invalide DOIT refuser le boot, mais avec un message lisible, pas une
  # `** (ArgumentError) String.to_integer`). Le daemon ne doit jamais crash-booter sur une
  # stacktrace énigmatique d'un typo d'env.
  parse_int = fn name, val ->
    case Integer.parse(val) do
      {n, ""} ->
        n

      _ ->
        raise "LCARS config: #{name}=#{inspect(val)} n'est pas un entier valide — boot refusé (corriger l'env)"
    end
  end

  # ============================================================
  # Logger
  # ============================================================
  # Z6 (CFG-CR) — `String.to_existing_atom` crashait le boot sur un niveau inconnu
  # (ex. LCARS_LOG_LEVEL=verbose). Validé contre l'enum Logger ; inconnu → fallback :info
  # + warning stderr (un mauvais niveau de log NE doit PAS empêcher le boot — non-critique).
  log_level =
    case System.get_env("LCARS_LOG_LEVEL", "info") do
      lvl when lvl in ~w(emergency alert critical error warning notice info debug) ->
        String.to_existing_atom(lvl)

      other ->
        IO.puts(
          :stderr,
          "LCARS config: LCARS_LOG_LEVEL=#{inspect(other)} invalide — fallback :info"
        )

        :info
    end

  config :logger, level: log_level

  # ============================================================
  # fleet_cap_profile (ch1) — chemin catalogue cap-profiles
  # ============================================================
  if path = System.get_env("LCARS_CAPPROFILES_ROOT") do
    # Clé `:root_dir` (pas `:capprofiles_root`) — ce que
    # Fleet.CapProfile.root_dir/0 lit réellement (cap_profile.ex:206).
    config :fleet_cap_profile, root_dir: path
    # #582 re-bounce sf : Fleet.Spawner.PermanentBoot.cap_profiles_dir/0
    # lit `:fleet_spawner, :cap_profiles_dir` (config séparée du loader
    # ch1). Même env source → même path partagé canon.
    config :fleet_spawner, cap_profiles_dir: path
  end

  # ============================================================
  # fleet_credentials (ch3) — ADR-F : plus de coffre. Le knob LCARS_CREDENTIALS_ROOT
  # (→ :credentials_root) a été RETIRÉ (Fable F160) : aucun module ne lisait `credentials_root`
  # (les creds = claudeDir humain bindé par bwrap, pas un coffre).
  # ============================================================

  # Z4 (forge-identité B') — l'identité git de l'humain est DÉRIVÉE de l'OS (git config →
  # GECOS → login), plus de catalogue `settings_users.yaml` (doctrine 2026-06-11 : si l'user
  # existe sur le système, c'est un humain de la fleet, on n'over-filtre pas). Aucun knob.

  # ============================================================
  # fleet_event_router (ch11) — webhook Gitea + signaux OS
  # ============================================================
  if path = System.get_env("FLEET_WEBHOOK_SECRET_PATH") do
    config :fleet_event_router, webhook_secret_path: path
  end

  # F161/F036 : ON-SWITCH du listener webhook Gitea (:8081 HMAC). Sans lui, `:start_webhooks` restait
  # à `false` partout → WebhooksGitea + le secret + les clés gitea.* du registre étaient une surface
  # de config qui ne pouvait JAMAIS démarrer. Défaut OFF (intégration forge opt-in). Port surchargeable.
  if System.get_env("LCARS_FLEET_WEBHOOKS") == "true" do
    config :fleet_event_router, start_webhooks: true

    if port = System.get_env("LCARS_FLEET_WEBHOOK_PORT") do
      config :fleet_event_router, webhook_port: parse_int.("LCARS_FLEET_WEBHOOK_PORT", port)
    end
  end

  # SignalsOS (:start_signals) : PAS d'on-switch — F037 : `handle_info({:signal,_})` est MORT
  # (les signaux OS vont au gen_event `:erl_signal_server`, pas au GenServer ; SIGUSR1 halte même le
  # VM). Câbler un knob activerait un module cassé ET dangereux. Reste gated-off jusqu'à F037 (vrai
  # fix = gen_event handler). os.signal.* du registre = dormant en attendant.

  # ============================================================
  # fleet_spawner (Lot 3) — pods permanents
  # BL-028 (clos) : `:boot_permanent_at_start` EST le gate canon du boot des pods
  # permanents (consulté par `Fleet.Starfleet.BootOrchestrator` via
  # `PermanentBoot.auto_boot_enabled?/0`, l'autorité unique depuis F-14). Défaut
  # **true** (canon DN lcars-fleet_service §391 : « default true en prod ») ;
  # `LCARS_BOOT_PERMANENT_AT_START=false` désactive (BootOrchestrator wire les
  # consumers + émet boot_complete mais ne spawn aucun pod permanent). Le second
  # gate `:start_boot_orchestrator` (défaut true) contrôle si l'orchestrateur
  # tourne du tout. Deux knobs distincts et significatifs.
  # ============================================================
  config :fleet_spawner,
    boot_permanent_at_start: System.get_env("LCARS_BOOT_PERMANENT_AT_START") != "false"

  # F-C4b-1 — GATE du recovery `:resume` (`--resume <session>` au respawn d'un pod
  # pipe/forever en vol). Défaut **true** (resume implémenté + actif) ; mais `--resume`
  # n'a jamais été prouvé live (session morte/non-persistée → claude exit → boot raté
  # silencieux, observé C4b). `LCARS_RECOVERY_RESUME_ENABLED=false` → recovery reroll
  # (`:recreate`) PARTOUT = escape-hatch si `--resume` se révèle mauvais à l'usage.
  # (Les one-shot rerollent de toute façon — clear-policy /clear, hors gate.)
  # BL-035 (dogfood F7) : défaut OFF (opt-in via env "true"). `--resume` sur session morte = pod zombie
  # PROUVÉ ; `:recreate` (session neuve) est le défaut sûr.
  config :fleet_spawner,
    recovery_resume_enabled: System.get_env("LCARS_RECOVERY_RESUME_ENABLED") == "true"

  # ============================================================
  # fleet_spawner pod_dir : PER-HUMAIN, dérivé du HOME du process runtime (pod.ex `pod_dir_for` →
  # `~/pods/pod_<id>`). Décision 2026-06-09 : plus de knob env `LCARS_PODS_ROOT` (il écrasait le
  # per-humain et a re-cassé le runtime le 2026-06-08 ; cf. journal). L'humain = l'user qui lance le
  # runtime, point. Override éventuel = `config :fleet_spawner, pod_dir_root: …` directement (tests).
  # ============================================================

  # tmux sock-dir base — défaut `/run/lcars/tmux-sock` (provisionné par le service systemd via
  # RuntimeDirectory). Override quand le runtime est lancé par un HUMAIN (pas le service) → un chemin
  # SOUS son home, writable sans privilège. Pose à la fois le côté runtime (`:tmux_sock_base`) et,
  # via do_launch, l'env `LCARS_TMUX_SOCK_BASE` que bwrap_launch lit (les deux côtés coïncident).
  if sock_base = System.get_env("LCARS_TMUX_SOCK_BASE") do
    config :fleet_spawner, tmux_sock_base: sock_base
  end

  # ============================================================
  # Backend de lancement : LauncherPortBackend (chaîne bwrap) — défaut et unique.
  # ============================================================
  # TmuxBackend (claude --remote-control HORS bwrap, containment: none, control-path cassé depuis la
  # convergence PodTmux 2026-06-02) a été SUPPRIMÉ (Fable F103). Le bloc d'opt-in quarantaine
  # `LCARS_LAUNCH_BACKEND=tmux` + `LCARS_UNSAFE_ALLOW_HOST_TMUX=1` est retiré avec lui : il n'y a plus
  # de backend hors-bwrap à activer. La chaîne bwrap est la seule voie (sanctuaire).

  # ============================================================
  # fleet_mcp — port HTTP pod-facing (PodTools transport :http +
  # TaskQueue centrale, R-CORE.comm Ring 4)
  # ============================================================
  # Démarre `Fleet.MCP.PodTools` HTTP + `Fleet.MCP.TaskQueue` quand set.
  # Les pods s'y connectent via le bridge.py stdio → http://127.0.0.1:
  # <port>/mcp. Sans ce port, les pods n'ont AUCUN tool mcp__fleet__*
  # (workflow worker impossible).
  if port = System.get_env("LCARS_FLEET_MCP_POD_FACING_PORT") do
    config :fleet_mcp, pod_facing_port: parse_int.("LCARS_FLEET_MCP_POD_FACING_PORT", port)
  end

  # ============================================================
  # fleet_spawner — mcp_server_spec (config du `.mcp-fleet.json`
  # écrit dans chaque pod par pod.ex maybe_provision_mcp_config)
  # ============================================================
  # Le pod claude REPL démarre le bridge.py via cette spec ; le bridge
  # forward stdio → HTTP central (LCARS_FLEET_MCP_URL). `LCARS_POD_ID`
  # est ajouté per-pod par pod.ex (build_fleet_mcp_entry).
  #
  # PASSE-9 (2026-06-08) : le bridge NE peut PAS être lancé via son chemin hôte
  # (`/var/lib/lcars/bin/...`) — le sandbox bwrap ne monte PAS `/var/lib/lcars`.
  # On fournit donc `bridge_source` (chemin HÔTE à COPIER) ; pod.ex le projette
  # sous `pod_dir/.lcars/` et résout les placeholders `{{BRIDGE}}`/`{{BRIDGE_LOG}}`
  # sur ce chemin pod-local (pod_dir est le SEUL espace RW monté dans le sandbox,
  # au même chemin absolu hôte+sandbox). Cf. pod.ex build_fleet_mcp_entry.
  mcp_url = System.get_env("LCARS_FLEET_MCP_URL")
  bridge_path = System.get_env("LCARS_FLEET_MCP_BRIDGE_PATH")

  if mcp_url && bridge_path do
    config :fleet_spawner, :mcp_server_spec, %{
      # Chemin HÔTE du bridge, copié per-pod par pod.ex (pas lancé en place).
      "bridge_source" => bridge_path,
      "command" => "bash",
      "args" => [
        "-c",
        # {{BRIDGE}}/{{BRIDGE_LOG}} = chemins POD-LOCAUX résolus par pod.ex (sous
        # pod_dir/.lcars/, RW dans le sandbox). PAS de chemin hôte ici : invisible
        # dans le sandbox bwrap.
        "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"
      ],
      "env" => %{
        "LCARS_FLEET_MCP_URL" => mcp_url
      }
    }
  end

  # ============================================================
  # fleet_pipeline (ch12) — racine catalogue pipelines YAML
  # ============================================================
  if path = System.get_env("LCARS_PIPELINES_ROOT") do
    config :fleet_pipeline, pipelines_root: path
  end

  # F092 : racine des workspaces de pipeline (scratch git). Défaut HORS /tmp (ADR-E :
  # PrivateTmp + tmpfs bwrap orphelineraient les écritures) = `~/.lcars/workspaces`.
  if path = System.get_env("LCARS_WORKSPACES_ROOT") do
    config :fleet_pipeline, workspaces_root: path
  end

  # R7 I-CBC — en prod, un échec de broadcast d'event lifecycle pipeline est
  # loggé (Logger.error) mais NE crash PAS l'Executor (préserver l'état du
  # pipeline). Hors prod, défaut `true` = fail-loud (re-raise) pour que le dev
  # voie le trou. (Ce fichier n'est pas évalué en `:test` → test garde true.)
  config :fleet_pipeline, reraise_broadcast_errors: false

  # ============================================================
  # fleet_starfleet (ch13) — log audit Cat 5
  # ============================================================
  if path = System.get_env("LCARS_STARFLEET_AUDIT_LOG") do
    config :fleet_starfleet, audit_log_path: path
  end

  # Drain de shutdown : backend réel (agrège l'in-flight Spawner/Pipeline/
  # TaskQueue + active la quiescence). Hors `:test` (ce fichier est guardé) →
  # les tests gardent le défaut `NoOpDispatcher` (hermétisme). Décision user
  # 2026-06-05 : pas de god-module Fleet.Dispatcher, le seam EST l'abstraction.
  config :fleet_starfleet,
         :shutdown_dispatcher,
         Fleet.Starfleet.Shutdown.AggregateDispatcher

  # ============================================================
  # fleet_coord (ch14) — wired backend Fleet.Coord pour ch13
  # (ch12/pipeline : soft gate consolidé sur le gatekeeper côté pipeline, R06 —
  #  plus de :fleet_pipeline, :coord_backend)
  # ============================================================
  config :fleet_starfleet, :coord_backend, Fleet.Coord

  if path = System.get_env("LCARS_COORD_POLICIES_PATH") do
    config :fleet_coord, policies_path: path
  end

  # ============================================================
  # fleet_api (ch15) — port HTTP + git config repo (pas d'auth app, cf. rest.ex § Auth)
  # ============================================================
  http_port =
    case System.get_env("FLEET_API_PORT") do
      nil -> 8080
      str -> parse_int.("FLEET_API_PORT", str)
    end

  config :fleet_api, http_port: http_port
  config :fleet_api, start_listener: true

  if path = System.get_env("LCARS_CONFIG_REPO") do
    config :fleet_api, git_repo_path: path
  end

  # ============================================================
  # fleet_observation — observation deck read-only :8091 (BL-026)
  # ============================================================
  # Listener démarré en prod/dev (le `start_listener: false` hermétique de
  # test.exs n'est pas atteint ici : runtime.exs est gardé hors :test).
  obs_port =
    case System.get_env("LCARS_OBSERVATION_PORT") do
      nil -> 8091
      str -> parse_int.("LCARS_OBSERVATION_PORT", str)
    end

  config :fleet_observation, http_port: obs_port
  config :fleet_observation, start_listener: true

  # ============================================================
  # fleet_pilot (M-033) — auto-dispatch tickets Gitea
  # ============================================================
  # AutoDispatcher subscribe Bus `gitea.*` au boot. Lock idempotent via
  # label `lcars-dispatched` posé côté forge avant invoke pipeline.
  # OFF par défaut pour permettre rollout progressif via env var ;
  # passer à true via LCARS_PILOT_DISPATCHER=true quand catalogue
  # forge-routing.yaml est peuplé.
  config :fleet_pilot,
    start_dispatcher: System.get_env("LCARS_PILOT_DISPATCHER") == "true"

  if path = System.get_env("LCARS_PILOT_ROUTING_PATH") do
    config :fleet_pilot, forge_routing_path: path
  end

  # Poller catch-up : repo à scanner (`"owner/name"`) + interval ms.
  # Sans LCARS_PILOT_POLL_REPO, le Poller n'est pas démarré (seul
  # l'AutoDispatcher webhook-driven tourne).
  if repo = System.get_env("LCARS_PILOT_POLL_REPO") do
    config :fleet_pilot, poll_repo: repo
  end

  # Repo cible de la délégation arch (`create_ticket`). Défaut `fleet/fleet-test` (config app
  # fleet_mcp). À aligner sur LCARS_PILOT_POLL_REPO pour que le poller voie les tickets posés.
  if repo = System.get_env("LCARS_DELEGATION_REPO") do
    config :fleet_mcp, delegation_repo: repo
  end

  if interval = System.get_env("LCARS_PILOT_POLL_INTERVAL_MS") do
    config :fleet_pilot, poll_interval_ms: parse_int.("LCARS_PILOT_POLL_INTERVAL_MS", interval)
  end

  # Forge config — résolue par Fleet.Pilot.ForgeClient.resolve_config/1
  # à l'appel (merge avec opts d'appel). base_url obligatoire ;
  # token soit inline (FORGE_TOKEN) soit via fichier (FORGE_TOKEN_FILE,
  # défaut ~/.gitea_token convention v1.5).
  forge_opts =
    [
      base_url: System.get_env("FORGE_BASE_URL"),
      token: System.get_env("FORGE_TOKEN"),
      token_file: System.get_env("FORGE_TOKEN_FILE")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

  if forge_opts != [] do
    config :fleet_pilot, :forge, forge_opts
  end

  # F058/F059/F060 — login du compte SYSTÈME (propriétaire de FORGE_TOKEN). Les marqueurs
  # forge (route / hop / result-block) ne font foi QUE s'ils sont écrits par ce login (un user
  # forge qui en poste un faux est ignoré). Optionnel : si absent, ForgeClient le dérive une fois
  # via `GET /user` (l'authentifié du token) et le cache. Le surcharger ici évite ce round-trip et
  # lève toute ambiguïté en déploiement (token partagé, miroir, etc.).
  if bot_login = System.get_env("FORGE_BOT_LOGIN") do
    config :fleet_pilot, forge_bot_login: bot_login
  end

  # ============================================================
  # A2/A3 — runtime STAGE-MODE (forge = machine à états) + BL-045b auth push
  # ============================================================
  # OFF par défaut. `LCARS_PILOT_STAGE=true` démarre Poller(stage) + HopConsumer
  # (cf. Fleet.Pilot.Application.stage_children). Requiert aussi LCARS_PILOT_POLL_REPO.
  if System.get_env("LCARS_PILOT_STAGE") == "true" do
    config :fleet_pilot, stage_dispatch?: true
  end

  # Routing d'ENTRÉE stage-mode : map `type:X → carte`. JSON inline via env.
  # Ex : LCARS_PILOT_STAGE_ROUTING='{"type:poc":"poc-cycle"}'.
  if routing_json = System.get_env("LCARS_PILOT_STAGE_ROUTING") do
    # Z6 (CFG-CR) — `Jason.decode!` crashait le boot sur un JSON malformé. Garde claire.
    case Jason.decode(routing_json) do
      {:ok, map} when is_map(map) ->
        config :fleet_pilot, stage_routing: map

      _ ->
        raise "LCARS config: LCARS_PILOT_STAGE_ROUTING n'est pas un objet JSON valide — boot refusé"
    end
  end

  # Remote git où le système pousse les livrables (HopConsumer). Override ; sinon dérivé
  # de :forge base_url + poll_repo (cf. Application.hop_remote). Token JAMAIS dans l'URL.
  if remote = System.get_env("LCARS_HOP_REMOTE") do
    config :fleet_pilot, hop_remote: remote
  end

  # BL-045b — auth push runtime (`Fleet.Credentials.ForgeAuth.git_env` → extraheader via env, token
  # HORS argv ET HORS .git/config — F087/F095). Token système (lcars-system, write:repository).
  # FORGE_PUSH_TOKEN prioritaire sur FORGE_TOKEN (le push exige write:repository, ≠ token poller read).
  forge_base = System.get_env("FORGE_BASE_URL")
  forge_push_token = System.get_env("FORGE_PUSH_TOKEN") || System.get_env("FORGE_TOKEN")

  if is_binary(forge_base) and is_binary(forge_push_token) do
    config :fleet_credentials, :forge_auth, %{url_prefix: forge_base, token: forge_push_token}
  end

  # NB cap-profiles / cartes : déjà couverts par `LCARS_CAPPROFILES_ROOT` (→ :fleet_cap_profile
  # :root_dir, plus haut) et `LCARS_PIPELINES_ROOT` (→ :fleet_pipeline :pipelines_root). Pas de
  # knob dupliqué ici (I-CBC, une source par config).

  # (Plus de knob `LCARS_POD_HUMAN` : l'humain = l'user du process runtime, dérivé in-code, jamais
  #  une config. Décision 2026-06-09 — cf. pod.ex `runtime_user`/`runtime_home`.)

  # State task-queue (défaut /var/lib/lcars/task-queue/state.json, root-owned en deploy).
  if path = System.get_env("LCARS_STATE_PATH") do
    config :fleet_task_queue, state_path: path
  end

  # State FS des pods (session_id/phase, recovery). Défaut `~/.lcars/state` (fleet sous l'humain,
  # doctrine 2026-06-11 — cf. pod.ex `default_state_fs_root`). Override explicite si déploiement
  # non-standard ; sinon le state suit le home de l'humain qui lance la fleet.
  if path = System.get_env("LCARS_STATE_FS_ROOT") do
    config :fleet_spawner, state_fs_root: path
  end

  # Kick d'onboarding du pod (nudge `yop` → claude appelle get_task). La fenêtre par défaut
  # (first 2s + 12×2.5s ≈ 32s) est trop courte face au cold-start claude en bwrap sur le service
  # déployé (binaire 238MB, caches froids) → kick abandonné avant REPL prêt → pod sans mandat.
  # Élargir en deploy. Entiers via env.
  if v = System.get_env("LCARS_KICK_FIRST_DELAY_MS"),
    do: config(:fleet_spawner, kick_first_delay_ms: parse_int.("LCARS_KICK_FIRST_DELAY_MS", v))

  if v = System.get_env("LCARS_KICK_RETRY_MS"),
    do: config(:fleet_spawner, kick_retry_ms: parse_int.("LCARS_KICK_RETRY_MS", v))

  if v = System.get_env("LCARS_KICK_MAX_ATTEMPTS"),
    do: config(:fleet_spawner, kick_max_attempts: parse_int.("LCARS_KICK_MAX_ATTEMPTS", v))
end

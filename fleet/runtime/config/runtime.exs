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
# listener Cowboy en test → crash boot → boot du daemon mort. (Régression B8
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

  # ============================================================
  # fleet_mcp — boot guard fail-closed (soft-default #6)
  # ============================================================
  # Le défaut code de `Fleet.MCP.Server.boot_environment` est `:pod` (refuse PAR OMISSION). runtime.exs ne
  # tourne QU'AU boot du daemon HOST → on y déclare `:host` POSITIVEMENT. Un boot qui ne passe pas par ici
  # (ni par config/test.exs) est refusé, jamais démarré permissivement. Résiduel wire-time : un pod qui
  # tournerait la BEAM umbrella complète exécuterait aussi runtime.exs ; les pods sont des REPL claude +
  # bridge.py, PAS la BEAM (latent — un signal host per-boot de bin/fleet_v2 durcirait encore).
  config :fleet_mcp, boot_environment: :host

  # Z6 (CFG-CR) — parsing des env vars DÉLÉGUÉ à `Fleet.EnvParse` (Ring 0, TESTABLE — ce fichier est
  # wrappé `config_env() != :test`, un lambda inline ne serait jamais testé : SOC-CONF-001/002/003).
  # Domaine borné : `port` (1..65535), `positive_ms` (>0), `count` (≥0), `bool` (formes reconnues +
  # défaut si inconnu), `path` (expand + rejet `..`/control). Un knob load-bearing invalide → raise clair.

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
    path = Fleet.EnvParse.path("LCARS_CAPPROFILES_ROOT", path)
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
    config :fleet_event_router,
      webhook_secret_path: Fleet.EnvParse.path("FLEET_WEBHOOK_SECRET_PATH", path)
  end

  # F161/F036 : ON-SWITCH du listener webhook Gitea (:8081 HMAC). Sans lui, `:start_webhooks` restait
  # à `false` partout → WebhooksGitea + le secret + les clés gitea.* du registre étaient une surface
  # de config qui ne pouvait JAMAIS démarrer. Défaut OFF (intégration forge opt-in). Port surchargeable.
  #
  # ⚠ DÉCISION (user 2026-07-13) — reste OFF DÉLIBÉRÉMENT, ce n'est PAS juste « pas encore branché ».
  # Le webhook n'est qu'un ACCÉLÉRATEUR de poll : il fait réagir le Poller à un changement forge tout
  # de suite au lieu d'attendre le prochain tick (~30 s). Or (a) c'est un hint LOSSY qui peut foirer /
  # se perdre (la vérité durable vit dans le poll, doctrine D1), et (b) gagner 30 s ne pèse rien quand
  # la réaction des agents se compte en MINUTES. Le rapport coût/risque/bénéfice ne le justifie pas.
  # Ne pas le rallumer « pour la latence » sans re-poser cette question à l'humain.
  if Fleet.EnvParse.bool("LCARS_FLEET_WEBHOOKS", System.get_env("LCARS_FLEET_WEBHOOKS"), false) do
    config :fleet_event_router, start_webhooks: true

    if port = System.get_env("LCARS_FLEET_WEBHOOK_PORT") do
      config :fleet_event_router,
        webhook_port: Fleet.EnvParse.port("LCARS_FLEET_WEBHOOK_PORT", port)
    end
  end

  # SignalsOS (:start_signals) : PAS d'on-switch — le module est un stub NON-IMPLÉMENTÉ dont
  # `init/1` RAISE avant tout `:os.set_signal` (boot fail-loud : l'activer est une misconfiguration,
  # jamais une capture silencieuse de SIGTERM/SIGHUP). Le vrai fix, le jour venu = un gen_event
  # handler sur `:erl_signal_server` (les signaux OS n'atteignent pas un GenServer). Reste gated-off ;
  # os.signal.* du registre = dormant en attendant.

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
    boot_permanent_at_start:
      Fleet.EnvParse.bool(
        "LCARS_BOOT_PERMANENT_AT_START",
        System.get_env("LCARS_BOOT_PERMANENT_AT_START"),
        true
      )

  # ============================================================
  # fleet_spawner pod_dir : PER-HUMAIN, dérivé du HOME du process runtime (pod.ex `pod_dir_for` →
  # `~/pods/pod_<id>`). Décision 2026-06-09 : plus de knob env `LCARS_PODS_ROOT` (il écrasait le
  # per-humain et a re-cassé le runtime le 2026-06-08 ; cf. journal). L'humain = l'user qui lance le
  # runtime, point. Override éventuel = `config :fleet_spawner, pod_dir_root: …` directement (tests).
  # ============================================================

  # tmux sock-dir base — le défaut côté Elixir est home-relatif `~/.lcars/run/tmux-sock`
  # (`Fleet.Spawner.PodTmux.sock_base`, fleet lancée par un humain : un chemin writable sans privilège).
  # Cet env (posé par bin/fleet_v2) le surcharge explicitement pour que TOUS les côtés calculent le même
  # chemin. Pose à la fois le côté runtime (`:tmux_sock_base`) et, via do_launch, l'env
  # `LCARS_TMUX_SOCK_BASE` que les launchers lisent. (`/run/lcars/tmux-sock` = ancien RuntimeDirectory du
  # service systemd retiré, jamais le défaut courant.)
  if sock_base = System.get_env("LCARS_TMUX_SOCK_BASE") do
    config :fleet_spawner, tmux_sock_base: Fleet.EnvParse.path("LCARS_TMUX_SOCK_BASE", sock_base)
  end

  # ============================================================
  # Backend de lancement : LauncherPortBackend (chaîne bwrap) — défaut et unique.
  # ============================================================
  # TmuxBackend (claude --remote-control HORS bwrap, containment: none, control-path cassé depuis la
  # convergence PodTmux 2026-06-02) a été SUPPRIMÉ (Fable F103). Le bloc d'opt-in quarantaine
  # `LCARS_LAUNCH_BACKEND=tmux` + `LCARS_UNSAFE_ALLOW_HOST_TMUX=1` est retiré avec lui : il n'y a plus
  # de backend hors-bwrap à activer. La chaîne bwrap est la seule voie de lancement sandboxé
  # (elle projette le sanctuaire du pod — le monde clos fourni À l'agent).

  # ============================================================
  # fleet_mcp — base des sockets MCP per-pod (transport AF_UNIX, R9)
  # ============================================================
  # Le transport pod-facing n'est plus un listener HTTP partagé (`:pod_facing_port` retiré — dead config
  # sans lecteur depuis la bascule socket) mais une socket AF_UNIX PAR POD (`<base>/<pod_id>/sock`, créée
  # par `Fleet.MCP.PodSocketSupervisor.ensure_pod_socket`, lue par le pod via `LCARS_FLEET_MCP_SOCKET`).
  # Défaut `:sock_base` = `/run/lcars/mcp` (côté fleet_mcp). Quand le runtime est lancé par un HUMAIN (pas
  # un service système), `/run/lcars` n'est pas writable sans privilège → override SOUS son home, EXACTEMENT
  # comme `LCARS_TMUX_SOCK_BASE` le fait pour la socket tmux des pods. La socket est bindée au MÊME chemin
  # absolu dans le sandbox bwrap (`--bind X X`) → host == namespace (pas de remap du chemin).
  if sock_base = System.get_env("LCARS_FLEET_MCP_SOCK_BASE") do
    config :fleet_mcp, sock_base: Fleet.EnvParse.path("LCARS_FLEET_MCP_SOCK_BASE", sock_base)
  end

  # ============================================================
  # fleet_spawner — mcp_server_spec (config du `.mcp-fleet.json`
  # écrit dans chaque pod par pod.ex maybe_provision_mcp_config)
  # ============================================================
  # Le pod claude REPL démarre le bridge.py via cette spec ; le bridge parle au central via la socket
  # AF_UNIX per-pod dont le chemin est injecté PER-POD par pod.ex en `LCARS_FLEET_MCP_SOCKET`
  # (build_fleet_mcp_entry) — plus de `LCARS_FLEET_MCP_URL` (l'ancien transport HTTP loopback partagé a
  # disparu, R9). `LCARS_POD_ID` est lui aussi ajouté per-pod par pod.ex.
  #
  # PASSE-9 (2026-06-08) : le bridge NE peut PAS être lancé via son chemin hôte
  # (`/var/lib/lcars/bin/...`) — le sandbox bwrap ne monte PAS `/var/lib/lcars`.
  # On fournit donc `bridge_source` (chemin HÔTE à COPIER) ; pod.ex le projette
  # sous `pod_dir/.lcars/` et résout les placeholders `{{BRIDGE}}`/`{{BRIDGE_LOG}}`
  # sur ce chemin pod-local (pod_dir est le SEUL espace RW monté dans le sandbox,
  # au même chemin absolu hôte+sandbox). Cf. pod.ex build_fleet_mcp_entry.
  #
  # Gate sur `bridge_path` SEUL (le bridge doit être copiable) : la cible de comm n'est plus une URL mais
  # la socket per-pod, résolue au runtime côté pod, pas une config statique de boot.
  if bridge_path = System.get_env("LCARS_FLEET_MCP_BRIDGE_PATH") do
    config :fleet_spawner, :mcp_server_spec, %{
      # Chemin HÔTE du bridge, copié per-pod par pod.ex (pas lancé en place).
      "bridge_source" => Fleet.EnvParse.path("LCARS_FLEET_MCP_BRIDGE_PATH", bridge_path),
      "command" => "bash",
      "args" => [
        "-c",
        # {{BRIDGE}}/{{BRIDGE_LOG}} = chemins POD-LOCAUX résolus par pod.ex (sous
        # pod_dir/.lcars/, RW dans le sandbox). PAS de chemin hôte ici : invisible
        # dans le sandbox bwrap.
        "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"
      ]
      # Pas de clé "env" statique : `LCARS_FLEET_MCP_SOCKET` (socket per-pod) + `LCARS_POD_ID` sont
      # injectés PER-POD par pod.ex (build_fleet_mcp_entry), pas figés ici.
    }
  end

  # ============================================================
  # fleet_workflow (ch12) — racine catalogue pipelines YAML
  # ============================================================
  if path = System.get_env("LCARS_WORKFLOW_MAPS_ROOT") do
    config :fleet_workflow,
      workflow_maps_root: Fleet.EnvParse.path("LCARS_WORKFLOW_MAPS_ROOT", path)
  end

  # TOMBSTONE (D3 2026-07-05) : le knob `LCARS_WORKSPACES_ROOT` (→ `:fleet_workflow,
  # :workspaces_root`, racine des workspaces scratch git de pipeline) est RETIRÉ — son
  # dernier lecteur (`WorkspaceProvisioner`, pile du moteur RAM) a été supprimé avec le
  # retrait du moteur RAM (Executor + pile) ; la config restait posée sans AUCUN lecteur.
  # Ne pas réintroduire : les workspaces actuels sont per-pod (pod_dir), pas un scratch
  # git partagé de pipeline.

  # ============================================================
  # fleet_starfleet (ch13) — log audit Cat 5
  # ============================================================
  if path = System.get_env("LCARS_STARFLEET_AUDIT_LOG") do
    config :fleet_starfleet,
      audit_log_path: Fleet.EnvParse.path("LCARS_STARFLEET_AUDIT_LOG", path)
  end

  # Drain de shutdown : backend réel (agrège l'in-flight Spawner + TaskQueue et active la
  # quiescence — le Pipeline RAM historique a disparu du décompte). Hors `:test` (ce fichier est guardé) →
  # les tests gardent le défaut `NoOpDispatcher` (hermétisme). Décision user
  # 2026-06-05 : pas de god-module Fleet.Dispatcher, le seam EST l'abstraction.
  config :fleet_starfleet,
         :shutdown_dispatcher,
         Fleet.Starfleet.Shutdown.AggregateDispatcher

  # ============================================================
  # fleet_coord (ch14) — wired backend Fleet.Coord pour ch13
  # (ch12/pipeline : soft gate consolidé sur le gatekeeper côté pipeline, R06 —
  #  plus de :fleet_workflow, :coord_backend)
  # ============================================================
  config :fleet_starfleet, :coord_backend, Fleet.Coord

  if path = System.get_env("LCARS_COORD_POLICIES_PATH") do
    config :fleet_coord, policies_path: Fleet.EnvParse.path("LCARS_COORD_POLICIES_PATH", path)
  end

  # ============================================================
  # fleet_api (ch15) — port HTTP (pas d'auth app, cf. rest.ex § Auth)
  # ============================================================
  # A7 (accord des ports) : les ports sont per-humain (bloc UID calculé par bin/fleet_v2) — un
  # défaut statique (l'ancien 8080) n'est JAMAIS le vrai port et divergeait du reste de la fleet.
  # Absent = boot hors bin/fleet_v2 → fail-loud (même règle que LCARS_FLEET_MCP_BRIDGE_PATH).
  http_port =
    case System.get_env("FLEET_API_PORT") do
      nil ->
        raise "FLEET_API_PORT manquant — les ports sont posés par bin/fleet_v2 (bloc per-humain). " <>
                "Lance via fleet_v2 start, ou pose la var explicitement."

      str ->
        Fleet.EnvParse.port("FLEET_API_PORT", str)
    end

  config :fleet_api, http_port: http_port
  config :fleet_api, start_listener: true

  # AF_UNIX control socket pour la porte d'écriture (POST /api/admin/spawn, ControlRouter) —
  # hors du réseau que le pod partage (A-21). Défaut : ~/.lcars/run/api.sock (per-humain, home
  # réel jamais bindé dans le pod → inatteignable). Override LCARS_API_SOCK (posé par bin/fleet_v2).
  config :fleet_api,
    control_socket:
      System.get_env("LCARS_API_SOCK") ||
        Path.join([System.fetch_env!("HOME"), ".lcars", "run", "api.sock"])

  # ============================================================
  # fleet_observation — observation deck read-only, port per-humain (BL-026)
  # ============================================================
  # Listener démarré en prod/dev (le `start_listener: false` hermétique de
  # test.exs n'est pas atteint ici : runtime.exs est gardé hors :test).
  obs_port =
    case System.get_env("LCARS_OBSERVATION_PORT") do
      nil ->
        raise "LCARS_OBSERVATION_PORT manquant — posé par bin/fleet_v2 (bloc per-humain). " <>
                "Lance via fleet_v2 start, ou pose la var explicitement."

      str ->
        Fleet.EnvParse.port("LCARS_OBSERVATION_PORT", str)
    end

  config :fleet_observation, http_port: obs_port
  config :fleet_observation, start_listener: true

  # ============================================================
  # fleet_pilot — le knob legacy `start_dispatcher` / `LCARS_PILOT_DISPATCHER` et le catalogue
  # `LCARS_PILOT_ROUTING_PATH` (→ `forge-routing.yaml`) sont SUPPRIMÉS avec le rail AutoDispatcher
  # (webhook→route→Executor RAM). Aucun code ne lisait plus `:forge_routing_path`. Seul le rail
  # forge-state-machine subsiste (config `LCARS_PILOT_STEP` / `LCARS_PILOT_POLL_REPO`, plus bas).
  # ============================================================

  # F-037 MULTI-PROJET : le Poller ne scanne PLUS un repo fixe — il DÉCOUVRE ses projets par topic
  # (`lcars-fleet-<human>`, posé à l'onboarding). `LCARS_PILOT_POLL_REPO` n'est donc PLUS requis pour que
  # le rail tourne (la garde fail-loud boot est sur FORGE_BASE_URL, cf. Fleet.Pilot.Application).
  # ÉTAT VRAI (D3 2026-07-05) : cette config est posée SANS lecteur runtime (aucun
  # `get_env(:fleet_pilot, :poll_repo)` dans le code ; les tests injectent repo/remote par opts directs).
  # CONSERVÉE délibérément comme contrat ops (l'env var reste reconnue, pas un no-op surprise si un
  # déploiement la pose). En prod multi-projet, repo+remote voyagent dans l'event `pod.completed`.
  if repo = System.get_env("LCARS_PILOT_POLL_REPO") do
    config :fleet_pilot, poll_repo: repo
  end

  if interval = System.get_env("LCARS_PILOT_POLL_INTERVAL_MS") do
    config :fleet_pilot,
      poll_interval_ms: Fleet.EnvParse.positive_ms("LCARS_PILOT_POLL_INTERVAL_MS", interval)
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
  # forge (route / step_run / result-block) ne font foi QUE s'ils sont écrits par ce login (un user
  # forge qui en poste un faux est ignoré). Optionnel : si absent, ForgeClient le dérive une fois
  # via `GET /user` (l'authentifié du token) et le cache. Le surcharger ici évite ce round-trip et
  # lève toute ambiguïté en déploiement (token partagé, miroir, etc.).
  if bot_login = System.get_env("FORGE_BOT_LOGIN") do
    config :fleet_pilot, forge_bot_login: bot_login
  end

  # Multi-forge par config (une forge par boot, choisie par profil env). Les tokens de RÔLE
  # (`Fleet.Credentials.RoleToken`) sont lus dans `<role_tokens_dir>/<role>.gitea_token` ;
  # défaut `/home/private` (forge primaire). Pour cibler une 2e forge (ex. secours :3000), un
  # profil env distinct pose FORGE_BASE_URL + FORGE_TOKEN_FILE + ce dossier → un jeu de tokens
  # ISOLÉ par forge (pas de clobber). Le token système, lui, est déjà par-forge via
  # FORGE_TOKEN_FILE. Absent = défaut (rétro-compat stricte). Pas de multi-forge SIMULTANÉ
  # (registry/routing par-projet) : hors-scope, ce serait un autre modèle.
  if role_tokens_dir = System.get_env("FORGE_ROLE_TOKENS_DIR") do
    config :fleet_credentials,
      role_tokens_dir: Fleet.EnvParse.path("FORGE_ROLE_TOKENS_DIR", role_tokens_dir)
  end

  # ============================================================
  # A2/A3 — runtime STEP-MODE (forge = machine à états) + BL-045b auth push
  # ============================================================
  # OFF par défaut. `LCARS_PILOT_STEP=true` démarre Poller(step) + StepRunConsumer
  # (cf. Fleet.Pilot.Application.step_children!). F-037 : requiert UNIQUEMENT FORGE_BASE_URL — c'est la
  # seule garde fail-loud du boot step (découverte des projets par topic + push per-step-run). LCARS_PILOT_POLL_REPO
  # n'est PAS requis (override legacy/test seulement ; la découverte réelle est par topic forge, pas un repo fixe).
  if Fleet.EnvParse.bool("LCARS_PILOT_STEP", System.get_env("LCARS_PILOT_STEP"), false) do
    config :fleet_pilot, step_dispatch?: true
  end

  # #8 coherence: no more label-routing knob (`LCARS_PILOT_STEP_ROUTING` removed). Routing lives in the
  # scoped labels `wfmap/*`+`stage/*` (engraved by `post_route`; delegation workflow_map, default brief-gate). type:* = display.

  # F-037 : `LCARS_HOP_REMOTE` retiré — le remote de push n'est plus un URL fixe (incompatible multi-projet) ;
  # il est PER-STEP-RUN, dérivé du `repo_path` du projet et embarqué dans l'event `pod.completed` (cf.
  # `Fleet.Spawner.Pod.pod_completed_payload` + `Fleet.Pilot.StepRunConsumer.step_run_state/2`). Auth push inchangée
  # (`Fleet.Credentials.ForgeAuth.git_env` → token via env, jamais dans l'URL).

  # BL-045b — auth push runtime (`Fleet.Credentials.ForgeAuth.git_env` → extraheader via env, token
  # HORS argv ET HORS .git/config — F087/F095). Token système (lcars-system, write:repository).
  # FORGE_PUSH_TOKEN prioritaire sur FORGE_TOKEN (le push exige write:repository, ≠ token poller read).
  forge_base = System.get_env("FORGE_BASE_URL")

  # Le token push doit venir de la MÊME source que le token poller : var (FORGE_PUSH_TOKEN / FORGE_TOKEN)
  # PUIS le FICHIER (FORGE_TOKEN_FILE, défaut ~/.gitea_token). Sans ce fallback-fichier, un déploiement
  # qui ne pose QUE le fichier (cas nominal) avait un push SANS auth → « could not read Username »
  # (régression latente prouvée live : le poller lisait le fichier, le push ne lisait que la var).
  default_token_file =
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, ".gitea_token")
      _ -> nil
    end

  forge_push_token =
    System.get_env("FORGE_PUSH_TOKEN") || System.get_env("FORGE_TOKEN") ||
      case System.get_env("FORGE_TOKEN_FILE") || default_token_file do
        path when is_binary(path) ->
          case File.read(path) do
            {:ok, t} -> String.trim(t)
            _ -> nil
          end

        _ ->
          nil
      end

  if is_binary(forge_base) and is_binary(forge_push_token) and forge_push_token != "" do
    config :fleet_credentials, :forge_auth, %{url_prefix: forge_base, token: forge_push_token}
  end

  # NB cap-profiles / workflow_maps : déjà couverts par `LCARS_CAPPROFILES_ROOT` (→ :fleet_cap_profile
  # :root_dir, plus haut) et `LCARS_WORKFLOW_MAPS_ROOT` (→ :fleet_workflow :workflow_maps_root). Pas de
  # knob dupliqué ici (I-CBC, une source par config).

  # (Plus de knob `LCARS_POD_HUMAN` : l'humain = l'user du process runtime, dérivé in-code, jamais
  #  une config. Décision 2026-06-09 — cf. pod.ex `runtime_user`/`runtime_home`.)

  # State task-queue (défaut home-relatif `~/.lcars/task-queue/state.json` ; HOME irrésoluble =
  # fail-loud délibéré, raise — cf. task_queue/store.ex `default_path/0` ; aucun fallback).
  if path = System.get_env("LCARS_STATE_PATH") do
    config :fleet_task_queue, state_path: Fleet.EnvParse.path("LCARS_STATE_PATH", path)
  end

  # State FS des pods (session_id/phase, recovery). Défaut `~/.lcars/state` (fleet sous l'humain,
  # doctrine 2026-06-11 — cf. pod.ex `default_state_fs_root`). Override explicite si déploiement
  # non-standard ; sinon le state suit le home de l'humain qui lance la fleet.
  if path = System.get_env("LCARS_STATE_FS_ROOT") do
    config :fleet_spawner, state_fs_root: Fleet.EnvParse.path("LCARS_STATE_FS_ROOT", path)
  end

  # Launchers pod (N0/N1) : path absolu lu par le spawner (défaut `/usr/local/bin`, pod.ex). Le launcher
  # `fleet_v2` les pose depuis `$INSTALL_DIR/bin` (BSD : tout sous l'install, rien d'éparpillé ; fini le
  # `sudo cp` vers /usr/local/bin). Le dir parent est bindé RO dans le sandbox (pod.ex `system_mounts`,
  # dérivé de `claude_launch_path`). Param d'install → le `v2 → lcars` futur ne touche aucun code.
  if path = System.get_env("LCARS_BWRAP_LAUNCH_PATH"),
    do:
      config(:fleet_spawner,
        bwrap_launch_path: Fleet.EnvParse.path("LCARS_BWRAP_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_HOST_LAUNCH_PATH"),
    do:
      config(:fleet_spawner,
        host_launch_path: Fleet.EnvParse.path("LCARS_HOST_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_CLAUDE_LAUNCH_PATH"),
    do:
      config(:fleet_spawner,
        claude_launch_path: Fleet.EnvParse.path("LCARS_CLAUDE_LAUNCH_PATH", path)
      )

  # Seed store (round-1 des pods — optimisation de reprise, JAMAIS requis ; vide = auto-peuplant, le pod
  # spawne fresh). Override env `LCARS_SEED_STORE_ROOT` du défaut code (`~/.lcars/seeds`, aligné dans
  # seed_store.ex). Le fallback `/var/lib/lcars` ne sert que si HOME est irrésoluble AU BOOT :
  # évaluer la config ne doit pas crasher le node pour un store optionnel (le défaut code, lui,
  # est rescué à l'usage).
  seed_store_root =
    case System.get_env("LCARS_SEED_STORE_ROOT") do
      nil -> Path.join(System.user_home() || "/var/lib/lcars", ".lcars/seeds")
      p -> Fleet.EnvParse.path("LCARS_SEED_STORE_ROOT", p)
    end

  config :fleet_spawner, seed_store_root: seed_store_root

  # Kick d'onboarding du pod (nudge `yop` → claude appelle get_work_item). La fenêtre par défaut
  # (first 2s + 12×2.5s ≈ 32s) est trop courte face au cold-start claude en bwrap sur le service
  # déployé (binaire 238MB, caches froids) → kick abandonné avant REPL prêt → pod sans brief.
  # Élargir en deploy. Entiers via env.
  if v = System.get_env("LCARS_KICK_FIRST_DELAY_MS"),
    do:
      config(:fleet_spawner,
        kick_first_delay_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_FIRST_DELAY_MS", v)
      )

  if v = System.get_env("LCARS_KICK_RETRY_MS"),
    do:
      config(:fleet_spawner, kick_retry_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_RETRY_MS", v))

  if v = System.get_env("LCARS_KICK_MAX_ATTEMPTS"),
    do:
      config(:fleet_spawner,
        kick_max_attempts: Fleet.EnvParse.count("LCARS_KICK_MAX_ATTEMPTS", v)
      )
end

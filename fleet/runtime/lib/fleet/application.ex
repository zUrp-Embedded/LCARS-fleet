defmodule Fleet.Application do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary,
    deps: [
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.MCP,
      Fleet.Spawner,
      Fleet.Coord,
      Fleet.Starfleet,
      Fleet.Pilot,
      Fleet.API,
      Fleet.Observation
    ],
    exports: []

  @moduledoc """
  Racine OTP de l'app unique `:lcars_fleet` — l'UNIQUE callback `Application` du runtime
  depuis le collapse de l'umbrella (migration Z2, 2026-07-12).

  Démarre les superviseurs de domaine (les ex-apps umbrella) dans l'ordre topologique de
  l'ancien graphe de deps compile. Cinq ex-apps sont des bibliothèques PURES sans arbre de
  supervision (cap_profile, credentials, sp_builder, workflow, project_bootstrap) — rien à
  démarrer pour elles (elles n'ont AUCUN processus ; leurs modules sont chargés dans l'app,
  les fonctions pures marchent sans superviseur). Ne restent dans les children que les
  9 domaines qui démarrent réellement quelque chose.

  ## L'ordre des children EST l'invariant de boot (cicatrice F8)

  Avant le collapse, l'ordre venait du graphe de deps OTP + de la liste `releases:` du
  mix.exs umbrella. Il ne reste plus que CETTE liste : la réordonner peut casser le boot
  SANS erreur de compilation. Contraintes portées par l'ordre ci-dessous :

    * `event_router` PREMIER — le Bus (Phoenix.PubSub) est le substrat : tout subscriber
      démarré avant lui crashe à l'init. Sa mort escalade délibérément jusqu'au node
      (cf. `Bus.EscalatingSupervisor`, max_restarts: 0 — un PubSub ressuscité seul
      laisserait tous les subscribers sourds à vie).
    * `mcp` AVANT `spawner` (seam RUNTIME, pas une dep compile) : tout spawn de pod exige
      `ensure_pod_socket` (`Fleet.MCP.PodSocketSupervisor`) déjà vivant — et le
      PublishConsumer de spawner peut recevoir un `admin.spawn.request` dès son subscribe.
    * (Les contraintes historiques `mcp < starfleet` et `spawner < starfleet` sont TOMBÉES
      avec l'acte4 A-08 : le BootOrchestrator — seule cause de ces contraintes — n'est plus
      un child mid-boot de starfleet ; il est déclenché ci-dessous APRÈS le start_link OK,
      quand la fleet ENTIÈRE est prouvée up. « Post-readiness » est devenu mécanique.)
    * `api` avant-dernier (readiness interroge pilot/mcp/spawner/starfleet),
      `observation` DERNIER (read-only, rien du core n'en dépend).

  ## Sémantique de panne (D-17 chantier — transposition FIDÈLE de l'umbrella)

  `max_restarts: 0` : chaque domaine porte sa propre intensité de restart (3/60 en
  général) ; un domaine qui l'épuise MEURT, et sa mort tue le node (`start_permanent`
  en prod) — exactement le comportement des apps `:permanent` de l'umbrella. On ne
  redonne PAS une seconde vie au domaine ici : un domaine ressuscité seul (état perdu,
  subscriptions Bus mortes) serait une panne success-shaped, la classe exacte que
  l'audit 2026-07-09 a chassée. Adoucissement éventuel (`:rest_for_one` gracieux) =
  arbitrage user A-01, PAS un défaut.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      # Ring 0 — le Bus d'abord (substrat PubSub de tout le monde).
      Fleet.EventRouter.Application,
      # Ring 1 — broker de mandats (dep : Bus).
      Fleet.TaskQueue.Application,
      # Ring 2 — substrat MCP (sockets per-pod). ⚠ AVANT spawner (cicatrice F8, cf. moduledoc).
      Fleet.MCP.Supervisor,
      # Ring 1 — spawner (pods). Après mcp : son provisionneur de sockets résout vers MCP au runtime.
      Fleet.Spawner.Application,
      # Ring 2 — policy coord (init_policies! fail-fast dans son init/1).
      Fleet.Coord.Application,
      # Ring 2 — audit + monitors (DriftMonitor/AuditConsumer/Shutdown/MCP*). Le BootOrchestrator
      # n'y est PLUS : déclenché post-boot par la racine (A-08, cf. bas de start/2).
      Fleet.Starfleet.Application,
      # Ring 3 — driver forge (inerte sans :step_dispatch?).
      Fleet.Pilot.Application,
      # Ring 4 — surface REST/WS (readiness interroge les domaines précédents).
      Fleet.API.Application,
      # Ring 4 — observation deck read-only (rien du core n'en dépend → dernier).
      Fleet.Observation.Application
    ]

    opts = [strategy: :one_for_one, max_restarts: 0, name: Fleet.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Effet de bord de fin de boot (trace build-info) : APRÈS le start_link OK = fleet
        # entière up, listener api bindé inclus. Contrat détaillé dans
        # `Fleet.API.Application.post_boot/0`.
        Fleet.API.Application.post_boot()

        # BootOrchestrator (spawn des pods permanents = dépense claude RÉELLE) déclenché ICI,
        # structurellement POST-boot (acte4 A-08) : avant, child mid-boot de starfleet, son Task
        # async pouvait spawner AVANT que pilot/api soient up — si un ring tardif ratait son
        # start_link (port pris), les permanents étaient déjà lancés dans une fleet à moitié
        # morte (spend gaspillé, process orphelins). Ici, si le boot avorte, AUCUN spawn n'a eu
        # lieu. Via la FAÇADE (le domaine possède son gate `:start_boot_orchestrator` — false en
        # test, hermétique — et son trigger ; la racine dit juste « maintenant ») : boundary a
        # refusé l'appel direct à Starfleet.Application, à raison — la façade EST la surface.
        Fleet.Starfleet.boot_orchestrate()

        {:ok, pid}

      error ->
        error
    end
  end
end

defmodule Fleet.Pilot.Application do
  @moduledoc """
  Supervisor de l'app `fleet_pilot` — **mode STEP uniquement** (la forge EST la machine à états).

  Démarre, si `:step_dispatch?` est configuré (`config/runtime.exs` depuis l'env) et que la forge
  `base_url` résout, les trois process du rail forge-state-machine :

    * `Fleet.Pilot.Poller` (mode step) — **MULTI-PROJET** : DÉCOUVRE les repos de l'humain par
      topic (`lcars-fleet-<human>`, plus de `:poll_repo` hard-codé), dispatche les **issues assignées**
      (assignee=humain) vers le spawn du rôle **producteur** (`StepDispatcher`).
    * `Fleet.Pilot.StepRunConsumer` — consumer Bus : sur `pod.completed`, exécute la **fin-de-step-run**
      (publish du livrable git-native → push système → ouverture PR → merge). Sans lui, la chaîne
      n'avance pas au-delà du spawn producteur.
    * `Task.Supervisor` (`StepRunConsumer.task_supervisor/0`) — offload de la complétion de step_run : le
      `git push` ≤30s ne bloque pas le singleton `StepRunConsumer`. Démarré AVANT le StepRunConsumer (qui s'y réfère).
    * `Fleet.Pilot.IncidentConsumer` (+ sa `Task.Supervisor`) — consumer Bus SÉPARÉ des events d'ÉCHEC
      de pod (`pod.failed`/`wake.failed`) → `IncidentRegistry`. Concern distinct de la fin-de-step-run
      (blast-radius isolé : un burst d'échecs ne partage pas la mailbox du StepRunConsumer).

  ## Historique — rail legacy RETIRÉ (2026-06-16)

  L'ancien rail `AutoDispatcher` (webhook Gitea `gitea.*` → `Routing` catalogue → `Dispatcher` →
  `PipelineInvoker` → `Fleet.Workflow.start_pipeline` = moteur RAM `Executor`) a été **supprimé** :
  le double-modèle de livraison (RAM + forge) est éliminé, seul le **rail forge** subsiste. Avec lui
  ont disparu `auto_dispatcher.ex` / `dispatcher.ex` / `pipeline_invoker.ex`, le mode `do_poll` legacy
  du `Poller`, et la garde `guard_no_duplicate_poller!` (plus de collision possible : un seul Poller).
  Le moteur RAM (`fleet_workflow`) tombe en aval (`start_pipeline` orphelin).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # Le pool forge démarre INCONDITIONNELLEMENT, avant le rail step : le ForgeClient est aussi appelé
    # par `create_issue` (fleet_mcp) hors du rail Poller/StepRunConsumer, donc le pool doit exister dès que
    # fleet_pilot boote. Lazy (aucune connexion tant qu'aucune requête) → inoffensif hors prod/tests.
    children = [forge_finch_spec() | step_children()]

    # `:one_for_one` (pas `:rest_for_one`) bien que les enfants se réfèrent dans l'ordre
    # (Task.Supervisor + IncidentRegistry démarrés AVANT Poller + StepRunConsumer qui les utilisent) :
    # ces références sont par NOM GLOBAL (résolu à CHAQUE appel — `Task.Supervisor.start_child(name, …)`,
    # `IncidentRegistry` via son nom de process), JAMAIS un pid capturé à l'init. Donc si IncidentRegistry
    # ou le Task.Supervisor crashe et redémarre, le Poller/StepRunConsumer le re-trouve sous le même nom au
    # prochain appel — inutile de les redémarrer en cascade (ce que ferait `:rest_for_one`). L'isolation
    # par-process (un crash n'en tue qu'un) est le bon régime ici.
    #
    # Bornes de restart EXPLICITES (alignées TaskQueue 3/60) : >3 crashes/60s d'un singleton du rail =
    # boucle de crash → on remonte au superviseur racine plutôt que de marteler. Fenêtre rendue choix.
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.Pilot.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # Pool HTTP dédié au ForgeClient. `conn_max_idle_time: 30_000` ferme toute connexion restée idle >30s
  # AVANT que la forge ne la ferme côté serveur (le défaut Finch `:infinity` la garderait jusqu'à ce
  # qu'elle devienne stale → 1er appel suivant pendu jusqu'au receive_timeout, cause suspectée du ~30s
  # cumulé de create_issue). Pool HTTP/1 simple, lazy. `Req.request(finch: Fleet.Pilot.ForgeFinch)`
  # côté ForgeClient l'utilise.
  defp forge_finch_spec do
    {Finch, name: Fleet.Pilot.ForgeFinch, pools: %{default: [conn_max_idle_time: 30_000]}}
  end

  @doc """
  Statut de liveness du rail step forge-state-machine, pour la readiness. fleet_pilot
  possède la topologie du rail → c'est lui qui sait si les singletons sont vivants (fleet_api ne
  fait que demander, pas de fuite des noms de process Ring 2 dans Ring 4).

    * `{:inactive, _}`    — `:step_dispatch?` off (rail volontairement absent, attendu hors prod-step).
    * `{:operational, _}` — Poller + StepRunConsumer vivants.
    * `{:degraded, _}`    — step activé mais ≥1 singleton mort → **vert-creux attrapé** (le daemon
      tourne mais le rail forge n'avance plus).
  """
  @spec step_status() :: {:inactive | :operational | :degraded, map()}
  def step_status do
    if Application.get_env(:fleet_pilot, :step_dispatch?, false) do
      poller? = is_pid(Process.whereis(Fleet.Pilot.Poller))
      step_run? = is_pid(Process.whereis(Fleet.Pilot.StepRunConsumer))

      if poller? and step_run? do
        {:operational, %{poller: true, step_run_consumer: true}}
      else
        {:degraded, %{poller: poller?, step_run_consumer: step_run?}}
      end
    else
      {:inactive, %{note: "step_dispatch? off"}}
    end
  end

  # Process du rail STEP (la forge EST la machine à états). Démarré ssi `:step_dispatch?` est
  # vrai. `[]` si `:step_dispatch?` absent/false (app inerte volontaire — hermétisme test).
  #
  # Si `:step_dispatch?` est VRAI mais que la config essentielle ne résout pas, on ne retombe PAS sur
  # `[]` en silence (ça démarrerait l'app « verte » sans Poller/StepRunConsumer → rail forge mort, zéro
  # crash, zéro log). L'opérateur a DEMANDÉ le mode step → config incomplète = deploy cassé →
  # fail-loud au boot.
  defp step_children do
    if Application.get_env(:fleet_pilot, :step_dispatch?, false) do
      step_children!()
    else
      []
    end
  end

  @doc false
  # Test seam : expose les child-specs du rail SANS démarrer le superviseur (qui enregistrerait les
  # singletons sous leurs noms globaux → conflits / boot parasites). Sert à vérifier la garde fail-loud.
  def step_children_for_test, do: step_children()

  # MULTI-PROJET : plus de `:poll_repo` obligatoire ni de remote figé au boot — le Poller DÉCOUVRE ses
  # repos par appartenance-org (`list_org_repos`, WS3) et le StepRunConsumer dérive le repo+remote
  # PER-STEP-RUN de l'event. La config essentielle qui reste = la forge `base_url` : sans elle, ni
  # découverte (`list_org_repos`) ni push (remote per-step-run) ne marchent → rail mort. C'est la garde
  # fail-loud, pointée sur le réel.
  defp step_children! do
    unless forge_base_url() do
      raise "fleet_pilot: :step_dispatch? activé mais la forge base_url est absente (config :fleet_pilot, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — le Poller ne peut pas DÉCOUVRIR ses projets " <>
              "(list_org_repos) ni le StepRunConsumer dériver le remote de push. Deploy cassé, fail-loud."
    end

    interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)

    [
      # Superviseur de tasks pour l'offload de la complétion de step_run (le git push ≤30s du
      # StepRunConsumer ne bloque pas le singleton). Démarré AVANT le StepRunConsumer (qui s'y réfère).
      # max_children (E4) : borne le burst (cascade de pod.completed -> N pushes forge concurrents =
      # thundering herd). Au-dela -> {:error, :max_children}, gere fail-loud par offload_async.
      {Task.Supervisor, name: Fleet.Pilot.StepRunConsumer.task_supervisor(), max_children: 16},
      # Mémoire persistante des incidents système (owner résilient). Consommée par WakeRecovery
      # (kick_gatekeeper / safe_wake) ET par l'IncidentConsumer (events `*.failed`). Boot best-effort
      # (forge injoignable au boot → WAL local seul, pas de crash).
      Fleet.Pilot.IncidentRegistry,
      # Consumer Bus SÉPARÉ des events d'ÉCHEC de pod (`pod.failed`/`wake.failed`) → IncidentRegistry.
      # Sa Task.Supervisor (offload du forge du registre) démarrée AVANT lui (il s'y réfère). Séparé du
      # StepRunConsumer : concern distinct, le burst d'échecs ne partage pas la mailbox de la complétion.
      {Task.Supervisor, name: Fleet.Pilot.IncidentConsumer.task_supervisor(), max_children: 16},
      {Fleet.Pilot.IncidentConsumer, runner: &Fleet.Pilot.IncidentConsumer.offload_async/1},
      # Sérialiseur d'alignement du clone local après merge : projette le livrable (`origin/main`) sur
      # `/home/projects/<name>`. Démarré AVANT Poller + StepRunConsumer — ses deux déclencheurs de merge
      # (`promote_pr` / `StepRunCompleter.promote`) — pour qu'il sérialise leurs alignements potentiellement
      # concurrents (un `git` à la fois par worktree, contre la corruption d'index).
      Fleet.Pilot.WorktreeSync,
      # Ni `:repo` au Poller (découverte par topic), ni `:repo`/`:remote` au StepRunConsumer (per-step-run).
      # Le routing vit dans la route-comment (gravée par create_issue) ; le Poller la lit (state-machine).
      {Fleet.Pilot.Poller, interval_ms: interval, step_dispatch?: true},
      {Fleet.Pilot.StepRunConsumer,
       forge_opts: [], step_run_runner: &Fleet.Pilot.StepRunConsumer.offload_async/1}
    ]
  end

  # Forge base_url résolue (config app `:forge`). `nil` si absente/vide. Source de la garde fail-loud
  # ci-dessus (le rail step multi-projet en a besoin pour découvrir ET pour dériver les remotes per-step-run).
  defp forge_base_url do
    case Keyword.get(Application.get_env(:fleet_pilot, :forge, []), :base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end
end

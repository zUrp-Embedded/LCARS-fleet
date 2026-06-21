defmodule Fleet.Pilot.Application do
  @moduledoc """
  Supervisor de l'app `fleet_pilot` — **mode STAGE uniquement** (la forge EST la machine à états).

  Démarre, si `:stage_dispatch?` est configuré (`config/runtime.exs` depuis l'env) et que la forge
  `base_url` résout, les trois process du rail forge-state-machine :

    * `Fleet.Pilot.Poller` (mode stage) — **F-037 MULTI-PROJET** : DÉCOUVRE les repos de l'humain par
      topic (`lcars-fleet-<human>`, plus de `:poll_repo` hard-codé), dispatche les **issues assignées**
      (assignee=humain) vers le spawn du rôle **producteur** (`StageDispatcher`).
    * `Fleet.Pilot.HopConsumer` — consumer Bus : sur `pod.completed`, exécute la **fin-de-hop**
      (publish du livrable git-native → push système → ouverture PR → merge). Sans lui, la chaîne
      n'avance pas au-delà du spawn producteur.
    * `Task.Supervisor` (`HopConsumer.task_supervisor/0`) — offload de la complétion de hop : le
      `git push` ≤30s ne bloque pas le singleton `HopConsumer`. Démarré AVANT le HopConsumer (qui s'y réfère).

  ## Historique — rail legacy RETIRÉ (②.3 / BL-050, 2026-06-16)

  L'ancien rail `AutoDispatcher` (webhook Gitea `gitea.*` → `Routing` catalogue → `Dispatcher` →
  `PipelineInvoker` → `Fleet.Pipeline.start_pipeline` = moteur RAM `Executor`) a été **supprimé** :
  le double-modèle de livraison (RAM + forge) est éliminé, seul le **rail forge** subsiste. Avec lui
  ont disparu `auto_dispatcher.ex` / `dispatcher.ex` / `pipeline_invoker.ex`, le mode `do_poll` legacy
  du `Poller`, et la garde `guard_no_duplicate_poller!` (plus de collision possible : un seul Poller).
  Le moteur RAM (`fleet_pipeline`) tombe en aval (`start_pipeline` orphelin).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = stage_children()
    opts = [strategy: :one_for_one, name: Fleet.Pilot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Statut de liveness du rail stage forge-state-machine, pour la readiness (F-010). fleet_pilot
  possède la topologie du rail → c'est lui qui sait si les singletons sont vivants (fleet_api ne
  fait que demander, pas de fuite des noms de process Ring 2 dans Ring 4).

    * `{:inactive, _}`    — `:stage_dispatch?` off (rail volontairement absent, attendu hors prod-stage).
    * `{:operational, _}` — Poller + HopConsumer vivants.
    * `{:degraded, _}`    — stage activé mais ≥1 singleton mort → **vert-creux attrapé** (le daemon
      tourne mais le rail forge n'avance plus).
  """
  @spec stage_status() :: {:inactive | :operational | :degraded, map()}
  def stage_status do
    if Application.get_env(:fleet_pilot, :stage_dispatch?, false) do
      poller? = is_pid(Process.whereis(Fleet.Pilot.Poller))
      hop? = is_pid(Process.whereis(Fleet.Pilot.HopConsumer))

      if poller? and hop? do
        {:operational, %{poller: true, hop_consumer: true}}
      else
        {:degraded, %{poller: poller?, hop_consumer: hop?}}
      end
    else
      {:inactive, %{note: "stage_dispatch? off"}}
    end
  end

  # Process du rail STAGE (la forge EST la machine à états). Démarré ssi `:stage_dispatch?` est
  # vrai. `[]` si `:stage_dispatch?` absent/false (app inerte volontaire — hermétisme test).
  #
  # F-027 (Pattern A crash-boot) : si `:stage_dispatch?` est VRAI mais que la config essentielle ne
  # résout pas, on ne renvoie plus `[]` en SILENCE (ex-`else _ -> []` qui démarrait l'app « verte » sans
  # Poller/HopConsumer → rail forge mort, zéro crash, zéro log). L'opérateur a DEMANDÉ le mode stage →
  # config incomplète = deploy cassé → fail-loud au boot.
  defp stage_children do
    if Application.get_env(:fleet_pilot, :stage_dispatch?, false) do
      stage_children!()
    else
      []
    end
  end

  @doc false
  # Test seam (F-037) : expose les child-specs du rail SANS démarrer le superviseur (qui enregistrerait les
  # singletons sous leurs noms globaux → conflits / boot parasites). Sert à vérifier la garde fail-loud.
  def stage_children_for_test, do: stage_children()

  # F-037 MULTI-PROJET : plus de `:poll_repo` obligatoire ni de remote figé au boot — le Poller DÉCOUVRE
  # ses repos par topic (`lcars-fleet-<human>`) et le HopConsumer dérive le repo+remote PER-HOP de l'event.
  # La config essentielle qui reste = la forge `base_url` : sans elle, ni découverte (`search_repos_by_topic`)
  # ni push (remote per-hop) ne marchent → rail mort. C'est la garde fail-loud F-027 re-pointée sur le réel.
  defp stage_children! do
    unless forge_base_url() do
      raise "fleet_pilot: :stage_dispatch? activé mais la forge base_url est absente (config :fleet_pilot, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — le Poller ne peut pas DÉCOUVRIR ses projets " <>
              "(search_repos_by_topic) ni le HopConsumer dériver le remote de push. Deploy cassé, fail-loud."
    end

    interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)

    [
      # F067 : superviseur de tasks pour l'offload de la complétion de hop (le git push ≤30s du
      # HopConsumer ne bloque pas le singleton). Démarré AVANT le HopConsumer (qui s'y réfère).
      {Task.Supervisor, name: Fleet.Pilot.HopConsumer.task_supervisor()},
      # #5.2 : mémoire persistante des incidents système (owner résilient). Utilisée par WakeRecovery
      # (kick_gatekeeper / safe_wake) ; démarrée avec le rail, son seul consommateur. Boot best-effort
      # (forge injoignable au boot → WAL local seul, pas de crash).
      Fleet.Pilot.IncidentRegistry,
      # F-037 : ni `:repo` au Poller (découverte par topic), ni `:repo`/`:remote` au HopConsumer (per-hop).
      # Le routing vit dans la route-comment (gravée par create_ticket) ; le Poller la lit (state-machine).
      {Fleet.Pilot.Poller, interval_ms: interval, stage_dispatch?: true},
      {Fleet.Pilot.HopConsumer,
       forge_opts: [], hop_runner: &Fleet.Pilot.HopConsumer.offload_async/1}
    ]
  end

  # Forge base_url résolue (config app `:forge`). `nil` si absente/vide. Source de la garde fail-loud
  # ci-dessus (le rail stage multi-projet en a besoin pour découvrir ET pour dériver les remotes per-hop).
  defp forge_base_url do
    case Keyword.get(Application.get_env(:fleet_pilot, :forge, []), :base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end
end

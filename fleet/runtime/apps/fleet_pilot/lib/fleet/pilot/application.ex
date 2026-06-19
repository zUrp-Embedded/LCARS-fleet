defmodule Fleet.Pilot.Application do
  @moduledoc """
  Supervisor de l'app `fleet_pilot` — **mode STAGE uniquement** (la forge EST la machine à états).

  Démarre, si `:stage_dispatch?` + `:poll_repo` sont configurés (`config/runtime.exs` depuis l'env),
  les trois process du rail forge-state-machine :

    * `Fleet.Pilot.Poller` (mode stage) — scanne le repo cible, dispatche les **issues assignées**
      (assignee=humain) vers le spawn du rôle **producteur** (`StageDispatcher`). (+ `Entry` legacy
      sur `type:`, conservé transitoirement, FALL.)
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
  # F-027 (Pattern A crash-boot) : si `:stage_dispatch?` est VRAI mais que `:poll_repo` ou le remote
  # ne résolvent pas, on ne renvoie plus `[]` en SILENCE (ex-`else _ -> []` qui démarrait l'app
  # « verte » sans Poller/HopConsumer → rail forge mort, zéro crash, zéro log). L'opérateur a DEMANDÉ
  # le mode stage → une config incomplète = deploy cassé → fail-loud au boot.
  defp stage_children do
    if Application.get_env(:fleet_pilot, :stage_dispatch?, false) do
      stage_children!()
    else
      []
    end
  end

  defp stage_children! do
    repo = Application.get_env(:fleet_pilot, :poll_repo)

    unless is_binary(repo) and repo != "" do
      raise "fleet_pilot: :stage_dispatch? activé mais :poll_repo absent/vide — le rail forge-state-" <>
              "machine ne démarrerait pas (Poller/HopConsumer). Deploy cassé, fail-loud (vérifier " <>
              "LCARS_PILOT_POLL_REPO)."
    end

    remote = hop_remote(repo)

    unless is_binary(remote) and remote != "" do
      raise "fleet_pilot: :stage_dispatch? activé (repo=#{repo}) mais remote irrésolu — FORGE_BASE_URL " <>
              "(ou :hop_remote) absent → le HopConsumer ne pourrait pas pousser. Deploy cassé, fail-loud."
    end

    interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)

    [
      # F067 : superviseur de tasks pour l'offload de la complétion de hop (le git push ≤30s du
      # HopConsumer ne bloque pas le singleton). Démarré AVANT le HopConsumer (qui s'y réfère).
      {Task.Supervisor, name: Fleet.Pilot.HopConsumer.task_supervisor()},
      # #8 cohérence : plus de `routing` (type:label→carte). Le routing vit dans la route-comment
      # (gravée par create_ticket) ; le Poller la lit (state-machine). type:* = visu seulement.
      {Fleet.Pilot.Poller, repo: repo, interval_ms: interval, stage_dispatch?: true},
      {Fleet.Pilot.HopConsumer,
       repo: repo,
       remote: remote,
       forge_opts: [],
       hop_runner: &Fleet.Pilot.HopConsumer.offload_async/1}
    ]
  end

  # Remote git où le SYSTÈME pousse les livrables (HopConsumer). Dérivé du base_url forge
  # (`:fleet_pilot, :forge`) + repo, ou override explicite `:hop_remote`. Le token n'est PAS
  # dans l'URL (auth via `Fleet.Credentials.ForgeAuth.git_env`, env hors argv). `nil` → stage désactivé.
  defp hop_remote(repo) do
    case Application.get_env(:fleet_pilot, :hop_remote) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        case Keyword.get(Application.get_env(:fleet_pilot, :forge, []), :base_url) do
          # F055 : trim du slash final (symétrie avec StageDispatcher.forge_base_url + ForgeClient.
          # resolve_config) — sinon `http://forge//repo.git` (double slash → remote invalide).
          base when is_binary(base) and base != "" ->
            "#{String.trim_trailing(base, "/")}/#{repo}.git"

          _ ->
            nil
        end
    end
  end
end

defmodule Fleet.Pilot.Dispatcher do
  @moduledoc """
  Logique partagée "tenter le lock label + invoker pipeline" pour un
  issue donné. Utilisée par les deux chemins :

    * `Fleet.Pilot.AutoDispatcher` — event-driven (webhook Gitea
      `gitea.*` via Bus)
    * `Fleet.Pilot.Poller` — catch-up périodique (issues ouvertes
      sans label `lcars-dispatched`)

  Une seule source de vérité = `add_label/4` idempotent. Re-call sur
  une issue déjà dispatchée → `{:skipped, :already_dispatched}`,
  zéro effet de bord (cohérent doctrine "label = source de vérité").

  ## Pourquoi un module dédié

  Le PoC initial inlinait la logique dans AutoDispatcher. Brique 2
  (poller) a besoin du même chemin avec un trigger différent (pas
  d'event_type, juste un issue payload). Extraction = duplication zéro
  + futur 3e trigger (CLI manuel `mix fleet.dispatch <issue>` ?) sans
  refactor.
  """

  require Logger

  @type config :: %{
          dispatch_label: String.t(),
          forge_opts: keyword(),
          forge_client: module(),
          invoker: module()
        }

  @type result ::
          {:dispatched, pipeline_id :: String.t()}
          | {:skipped, atom()}
          | {:error, term()}

  @doc """
  Dispatch un issue : pose le lock label + invoke le pipeline.

  ## Inputs

    * `config` — map runtime (cf. type `config()`)
    * `pipeline_name` — name de pipeline (résolu par caller via Routing)
    * `repo` — `"owner/name"` (extrait du payload par caller)
    * `issue_number` — integer (extrait du payload par caller)
    * `payload` — payload Gitea complet, utilisé pour `ask` (issue.body)
      et metadata (title, html_url)

  ## Returns

  Cf. `result()`. Le caller décide quoi faire des skipped/error
  (logs, metrics, telemetry).
  """
  @spec dispatch(config(), String.t(), String.t(), integer(), map()) :: result()
  def dispatch(config, pipeline_name, repo, issue_number, payload)
      when is_map(config) and is_binary(pipeline_name) and is_binary(repo) and
             is_integer(issue_number) and is_map(payload) do
    ticket_id = build_ticket_id(repo, issue_number)

    with {:ok, lock_status} <- attempt_lock(config, repo, issue_number),
         :proceed <- check_lock(lock_status) do
      invoke_pipeline(config, pipeline_name, ticket_id, payload)
    else
      {:skipped, _} = skipped -> skipped
      {:error, _} = err -> err
    end
  end

  defp attempt_lock(config, repo, issue_number) do
    config.forge_client.add_label(
      repo,
      issue_number,
      config.dispatch_label,
      config.forge_opts
    )
  end

  defp check_lock(:added), do: :proceed
  defp check_lock(:already_present), do: {:skipped, :already_dispatched}

  defp build_ticket_id(repo, issue_number), do: "#{repo}##{issue_number}"

  defp invoke_pipeline(config, pipeline_name, ticket_id, payload) do
    ask = get_in(payload, ["issue", "body"]) || ""

    mandate_context = %{
      ticket_id: ticket_id,
      ask: ask,
      issue_title: get_in(payload, ["issue", "title"]),
      issue_url: get_in(payload, ["issue", "html_url"])
    }

    case config.invoker.start_pipeline(pipeline_name, mandate_context, []) do
      {:ok, pipeline_id} ->
        Logger.info(
          "fleet_pilot dispatched ticket=#{ticket_id} pipeline=#{pipeline_name} id=#{pipeline_id}"
        )

        {:dispatched, pipeline_id}

      {:error, reason} = err ->
        Logger.error(
          "fleet_pilot dispatch failed ticket=#{ticket_id} pipeline=#{pipeline_name} reason=#{inspect(reason)}"
        )

        err
    end
  end
end

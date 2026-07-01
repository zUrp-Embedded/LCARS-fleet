defmodule Fleet.Shutdown.Quiesce do
  @moduledoc """
  Flag de **quiescence** global du daemon (drain de shutdown coordonné).

  Primitive partagée : un seul booléen en `:persistent_term`. Quand le drain
  commence (`Fleet.Starfleet.Shutdown.begin/1` → `refuse_new_jobs/1`), le flag
  passe à `true` ; les **points d'entrée de travail top-level neuf** le
  consultent et refusent d'admettre du nouveau travail :

    * `Fleet.Pipeline.start_pipeline/3` — nouveau pipeline (webhook→pipeline
      via Pilot, ou opérateur)
    * REST `POST /api/admin/spawn` — nouveau pod opérateur

  Le travail **interne** d'un pipeline déjà en vol (spawn de l'étape suivante,
  enqueue de brief) ne consulte PAS ce flag — sinon l'in-flight ne pourrait
  plus se terminer, à l'opposé du but du drain.

  ## Pourquoi ici (fleet_event_router) et pas dans fleet_starfleet

  Les lecteurs (`fleet_pipeline` Ring 3, `fleet_api` Ring 4) ne peuvent pas
  prendre `fleet_starfleet` (Ring 3) en dépendance sans coupler des frères /
  inverser le layering. `fleet_event_router` est le substrat universel dont
  tout le monde dépend déjà (comme `Fleet.Event`). Le **primitive** (le flag)
  vit donc ici ; la **policy** (quand quiescer, l'agrégateur d'in-flight) reste
  dans `fleet_starfleet`. Iron Law : pas de process, juste `:persistent_term`.
  """

  @key {__MODULE__, :quiescing}

  @doc "Le daemon refuse-t-il le travail top-level neuf (drain en cours) ?"
  @spec quiescing?() :: boolean()
  def quiescing?, do: :persistent_term.get(@key, false)

  @doc "Active la quiescence — appelé par `Shutdown.refuse_new_jobs/1`. Idempotent."
  @spec refuse!() :: :ok
  def refuse! do
    :persistent_term.put(@key, true)
    :ok
  end

  @doc "Lève la quiescence (reprise d'admission). Idempotent."
  @spec resume!() :: :ok
  def resume! do
    :persistent_term.put(@key, false)
    :ok
  end
end

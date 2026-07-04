defmodule Fleet.Pilot.Offload do
  @moduledoc """
  Source UNIQUE de l'idiome d'**offload supervisé** des consumers Bus du pilot
  (`Fleet.Pilot.StepRunConsumer`, `Fleet.Pilot.IncidentConsumer`) : exécuter un travail I/O
  (git push, écritures forge) dans une `Task.Supervisor` pour ne PAS bloquer la mailbox du
  singleton, avec un échec de spawn fail-loud (jamais silencieux).

  Les deux consumers portaient chacun leur copie de `offload_async/1` (même séquence
  `Task.Supervisor.start_child` → `{:ok, :offloaded}` | log error + `{:error, {:offload_failed, _}}`).
  Le squelette est factorisé ici ; chaque consumer GARDE :

    * **son superviseur** (`task_supervisor/0`, démarré par `application.ex` AVANT le consumer —
      blast-radius séparé : un burst d'un concern ne sature pas les tasks de l'autre) ;
    * **son message d'échec** (la conséquence d'un offload raté diffère : « complétion perdue »
      côté step_run vs « incident NON gravé » côté incidents) — porté par `error_label`.

  Le vrai outcome du travail offloadé est loggé DANS la task par l'appelant (le retour
  `{:ok, :offloaded}` ne dit que « la task est partie »).
  """

  require Logger

  @doc """
  Démarre `fun` dans la `Task.Supervisor` nommée `supervisor_name`. Rend `{:ok, :offloaded}`
  (le vrai outcome est loggé dans la task par l'appelant). Échec de spawn (ex. `:max_children`
  atteint) → fail-loud : log `"<consumer>: offload Task échoué (<reason>) — <conséquence>"` +
  `{:error, {:offload_failed, reason}}` — le travail N'A PAS été lancé, et ça se voit.

  `error_label` = `{consumer, conséquence}` : le nom du consumer (préfixe du log) et la
  conséquence métier de la perte (suffixe du log), les deux seuls points de divergence des
  copies d'origine.
  """
  @spec async(atom(), (-> any()), {String.t(), String.t()}) ::
          {:ok, :offloaded} | {:error, {:offload_failed, term()}}
  def async(supervisor_name, fun, {consumer, consequence}) do
    case Task.Supervisor.start_child(supervisor_name, fun) do
      {:ok, _pid} ->
        {:ok, :offloaded}

      {:error, reason} ->
        Logger.error("#{consumer}: offload Task échoué (#{inspect(reason)}) — #{consequence}")

        {:error, {:offload_failed, reason}}
    end
  end
end

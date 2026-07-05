defmodule Fleet.MCP.PodTools.WorkItems do
  @moduledoc """
  Métier « drive work-item » — extrait de `Fleet.MCP.PodTools` (qui garde la table
  de routage `handle_tool_call/3` et le format de contenu MCP).

  Les deux canaux du pod vers le broker `Fleet.TaskQueue` :

    * `get_work_item/1` : canal IN — le pod PULL son brief. `%{"done" => true}` quand
      aucun brief (le pod s'arrête) ; sinon `%{"done" => false, "work_item" => %{...}}`.
    * `submit_result/3` : canal OUT — le pod PUSH son livrable (`payload`), corrélé à
      UN brief précis par le `work_item_id` OBLIGATOIRE.

  Médiation serveur-side : le pod ne touche jamais la TaskQueue directement (la queue,
  son schéma, son stockage restent invisibles au pod). Ce module est **passeur de
  `correlation_id`** : `work_item_id` exposé côté `get_work_item`, validé côté
  `submit_result` (le broker rejette un `work_item_id` ≠ brief actif).

  L'identité (quel pod) N'ARRIVE PAS ici : elle est résolue en amont par l'accepteur de
  socket (l'identité EST le canal) et vérifiée par les clauses de `PodTools` — ce module
  reçoit un `pod_id` déjà établi, jamais lu du wire.
  """

  alias Fleet.TaskQueue

  @doc """
  PULL du brief actif du pod auprès du broker.

  Rend la map résultat du tool (`%{"done" => boolean(), ...}`) : `done: true` = plus de
  tâche (le pod s'arrête), sinon le work item sous enveloppe JSON (`work_item_id` =
  correlation_id, exposé pour que le pod le renvoie à `submit_result`).
  """
  @spec get_work_item(String.t()) :: map()
  def get_work_item(pod_id) when is_binary(pod_id) and pod_id != "" do
    case TaskQueue.get_for_pod(pod_id) do
      {:ok, task} -> %{"done" => false, "work_item" => envelope(task)}
      {:error, :no_work_item} -> %{"done" => true}
    end
  end

  @doc """
  PUSH du livrable (`payload`) vers le broker, corrélé par `work_item_id`.

  Le corrélateur est cherché au top-level des `args` (format canonique) PUIS dans le
  `payload` (un agent juge le range parfois dans son payload de verdict). Absent des
  DEUX → `{:error, :work_item_id_required}`. Le broker valide ensuite pod_id ↔
  work_item_id et broadcast `%Fleet.Event{work_item.completed}`.

  Retours :

    * `{:ok, message}` — livrable accepté (ou double submit idempotent : le 1er submit
      EST enregistré, le doublon est ignoré avec un message dédié).
    * `{:error, :no_active_work_item}` — pas de brief actif : le livrable n'a NULLE PART
      où aller (jamais assigné, ou clos/réassigné depuis) → DROP signalé en erreur,
      jamais masqué en succès (sinon le pod croit son livrable accepté).
    * `{:error, :work_item_id_mismatch}` — le corrélateur ne nomme pas le brief actif du
      pod (verrou anti-impersonation du broker).
    * `{:error, :broadcast_failed}` — le broadcast lifecycle `work_item.completed` a
      échoué : le step_run ne finira PAS (le StepRunConsumer n'a rien reçu). Le pod doit
      voir un échec → il peut re-soumettre (le broadcast sera ré-émis), au lieu de croire
      son livrable accepté alors que le verrou forge reste posé à vie.
  """
  @spec submit_result(String.t(), map(), map()) :: {:ok, String.t()} | {:error, atom()}
  def submit_result(pod_id, args, payload)
      when is_binary(pod_id) and pod_id != "" and is_map(args) and is_map(payload) do
    case effective_work_item_id(args, payload) do
      nil ->
        {:error, :work_item_id_required}

      work_item_id ->
        case TaskQueue.submit_result(pod_id, Map.put(payload, "work_item_id", work_item_id)) do
          {:ok, _task} ->
            {:ok, "Resultat recu par le fleet. Tache close."}

          {:error, :no_active_work_item} ->
            {:error, :no_active_work_item}

          {:error, :double_submit_ignored} ->
            {:ok, "Resultat deja recu (ignore)."}

          {:error, :work_item_id_mismatch} ->
            {:error, :work_item_id_mismatch}

          {:error, {:broadcast_failed, _reason}} ->
            {:error, :broadcast_failed}
        end
    end
  end

  # Le `work_item_id` (corrélateur) cherché au top-level du wire PUIS dans le payload : un agent juge range
  # parfois le corrélateur DANS son payload de verdict plutôt qu'au paramètre top-level. Renvoie le work_item_id
  # non vide trouvé (top-level prioritaire), ou nil si absent des deux. Le broker corrèle ensuite sur
  # `result["work_item_id"]` et rejette (`:work_item_id_mismatch`) s'il ne correspond pas à SON brief actif → un pod
  # ne peut pas clôturer la tâche d'un autre (verrou orthogonal au transport). L'emplacement (top-level vs
  # payload) n'entre PAS dans la sécurité : le work_item_id reste explicite et validé ; seul le fallback
  # « dernière active » (implicite) était le trou.
  defp effective_work_item_id(args, payload) do
    present_work_item_id(Map.get(args, "work_item_id") || Map.get(args, :work_item_id)) ||
      present_work_item_id(Map.get(payload, "work_item_id") || Map.get(payload, :work_item_id))
  end

  defp present_work_item_id(tid) when is_binary(tid) and tid != "", do: tid
  defp present_work_item_id(_), do: nil

  # JSON envelope du brief exposé au pod — work_item_id = correlation_id.
  defp envelope(%Fleet.TaskQueue.WorkItem{} = t) do
    %{
      "work_item_id" => t.id,
      "issue_id" => t.issue_id,
      "role" => t.role,
      "brief" => t.brief,
      "deadline" => iso(t.deadline),
      "retry_count" => t.retry_count
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end

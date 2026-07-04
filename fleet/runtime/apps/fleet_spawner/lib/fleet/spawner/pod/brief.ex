defmodule Fleet.Spawner.Pod.Brief do
  @moduledoc """
  BRIEF du pod : contenu lisible + canal canonique — île extraite de `Fleet.Spawner.Pod.Scaffold`.

  Le brief d'un pod (sa TÂCHE, livrée par l'orchestrateur, modèle PUSH) a DEUX projections que ce
  module porte toutes les deux :

  - le **fichier lisible** `issues/<issue_id>.md` (contexte projet, lu comme contenu — pas une
    injection-prompt) : `issue_id_to_filename/1` (nom safe) + `default_brief/1` (le corps) ;
  - le **canal CANONIQUE** : l'enqueue idempotent dans la `Fleet.TaskQueue`
    (`maybe_enqueue_brief/1`) — le pod PULL via le tool MCP `get_work_item` (déclenché par le
    mot-clé `yop`), jamais par le texte injecté.

  Chaque étape rend une valeur ou `:ok`/`{:error, reason}` taggé que le `with` de l'état
  `:projecting` propage vers `transition_failed`. Aucun state, aucun Port, aucun timer. Dépend de
  `Pod.TaskProbe` (gate d'enqueue), `Fleet.TaskQueue` (enqueue) et `Fleet.CapProfile` (source
  unique du `name`). Aucune dépendance vers `Fleet.Spawner.Pod` (pas de cycle).

  ## Contrat (appelé par `Pod`, état `:projecting`)

  - `issue_id_to_filename/1` + `default_brief/1` — écriture du `issues/<id>.md`.
  - `maybe_enqueue_brief/1` — enqueue TaskQueue idempotent, APRÈS le scaffold lisible.
  """

  alias Fleet.Spawner.Pod.TaskProbe

  @doc """
  Convertit un `issue_id` (peut contenir `/`, `#`, etc. — ex. `fleet/lcars#600` depuis Gitea) en
  filename safe : remplace `/` par `_` (un `/` créerait des sous-dirs) et garde `#` (lisible humain).
  """
  @spec issue_id_to_filename(String.t()) :: String.t()
  def issue_id_to_filename(issue_id) when is_binary(issue_id) do
    String.replace(issue_id, "/", "_")
  end

  @doc """
  Corps du `issues/<id>.md` : cadre conversationnel neutre « pod LCARS (rôle X) » + la demande
  (`opts[:brief]`, ou un placeholder si absent).

  Ton NATUREL (pas multi-section formalisée « ## Tâche / ## Livrable ») : claude REPL en mode
  interactif peut interpréter un format trop structuré comme tentative de prompt injection et
  refuser. Le contexte fleet (convention `submit_result`) est posé en préambule conversationnel,
  pas comme directive impérative. Le RÔLE est interpolé RÉSOLU (source unique
  `Fleet.CapProfile.name/1`) — pas de « worker engineer » hardcodé qui primerait mal la persona
  d'un juge.
  """
  @spec default_brief(map()) :: String.t()
  def default_brief(state) do
    brief = Keyword.get(state.opts || [], :brief)
    role = Fleet.CapProfile.name(state.cap_profile)

    body =
      if is_binary(brief) and brief != "" do
        brief
      else
        "(Pas de brief fourni — issue #{state.issue_id}.)"
      end

    """
    Salut. Tu es un pod LCARS (rôle #{role}, pod #{state.pod_id}) ; cette session
    a été lancée par le fleet pour traiter une demande référencée issue #{state.issue_id}.

    Le fleet attend que tu utilises le tool MCP `submit_result` quand ton travail est
    terminé — c'est la convention LCARS, le canal de retour structuré équivalent d'un
    Slack DM signed-off. Pas besoin d'écrire de fichier toi-même.

    Voici la demande :

    #{body}
    """
  end

  @doc """
  Enqueue le brief dans la TaskQueue (le canal CANONIQUE `get_work_item`), idempotent :

  - pas de brief (pod permanent/interactif booté à froid) → rien à puller → bootstrap (skip) ;
  - brief DÉJÀ en file (`TaskProbe.no_pending_brief?` faux : dispatch step, le StepDispatcher a
    enqueué AVANT le spawn) → pas de double-enqueue (skip) ;
  - sinon (`admin.spawn` / `lcars spawn --brief` : aucun dispatcher) → on enqueue ici, sinon
    `get_work_item` rend `{done:true}` et le pod reste idle (cf. StepDispatcher.enqueue_brief).

  Mirror des `attrs` de StepDispatcher (`issue_id`/`role`/`brief`/`metadata`).
  """
  @spec maybe_enqueue_brief(map()) :: :ok | {:error, {:brief_enqueue_failed, term()}}
  def maybe_enqueue_brief(state) do
    brief = Keyword.get(state.opts || [], :brief)

    cond do
      not (is_binary(brief) and brief != "") ->
        :ok

      not TaskProbe.no_pending_brief?(state.pod_id) ->
        :ok

      true ->
        attrs = %{
          issue_id: state.issue_id,
          role: Fleet.CapProfile.name(state.cap_profile),
          brief: brief,
          metadata: %{"source" => "admin.spawn"}
        }

        case Fleet.TaskQueue.enqueue(state.pod_id, attrs) do
          {:ok, _task} -> :ok
          {:error, reason} -> {:error, {:brief_enqueue_failed, reason}}
        end
    end
  end
end

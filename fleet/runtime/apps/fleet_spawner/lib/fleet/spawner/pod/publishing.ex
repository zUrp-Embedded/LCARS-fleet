defmodule Fleet.Spawner.Pod.Publishing do
  @moduledoc """
  FLAG `:publishing` (SLOT-FREEZE) d'un pod pipe + son fail-safe `:publish_deadline` — cluster
  extrait de `Fleet.Spawner.Pod`.

  Un pipe `git_native` est `:publishing` entre le submit de son résultat et la confirmation forge
  `deliverable.published` : tant qu'il publie, il n'est PAS `:ready` (pas de reset/re-brief — le push
  async doit avoir LU le workspace avant qu'on le réinitialise). `:publishing` est un FLAG dans
  `data.conditions`, PAS un état gen_statem : un pod publishing est fonctionnellement en `:monitoring`
  (il peut recevoir une tâche) ; le flag ne fait que gater le reset/re-brief EXTERNE
  (`pipe_rebrief_state` lit `pod_info.conditions`).

  Ce module porte TOUT le cycle de vie du flag et de son unique timer (le generic timeout
  `:publish_deadline`, fail-safe si la confirmation forge n'arrive jamais) : la décision d'entrée
  (gatée `deliverable_mode == "git_native"` — un pod payload n'a rien à protéger et n'arme donc
  jamais un deadline jamais levé), la levée, le prédicat, l'action d'annulation et la config du délai.
  Aucun state propre, aucun Port, aucun timer ARMÉ ici : les fonctions rendent des VALEURS
  (`data` transformé + actions gen_statem) que le `Pod` émet — les HANDLERS (`:info
  deliverable.published`, `{:timeout, :publish_deadline}`) restent des callbacks de la machine.

  ## Contrat (appelé par `Pod`)

  - `maybe_enter_publishing/1` — appelé par `do_extract_proceed` au retour en `:monitoring` d'un
    pod long-lived ; rend `{data, actions}` (flag posé + armement du deadline, ou identité).
  - `leave_publishing/1` / `cancel_publish_deadline_action/0` — appelés par les 2 handlers de levée
    (`deliverable.published` reçu, ou fire du `:publish_deadline`).
  - `publishing?/1` — le flag est-il posé ? (gate des logs de levée côté handlers).
  - `publish_deadline_ms/0` — délai du fail-safe (config `:fleet_spawner, :publish_deadline_ms`,
    défaut 120 000 ms).

  Dépend de `Fleet.CapProfile.deliverable_mode/1` (source unique du mode de livrable) ; aucune
  dépendance vers `Fleet.Spawner.Pod` (pas de cycle).
  """

  @doc """
  Entre en `:publishing` SI le pod a un livrable git async à protéger. Seul un pod à livrable
  `git_native` a un push (confirmé par `deliverable.published`) qu'il faut protéger du
  reset/re-brief → flag + armement du generic timeout `:publish_deadline`. Un pod payload
  (gatekeeper/architect : pas de push) n'a rien à protéger ; le mettre `:publishing` armerait un
  deadline jamais levé → WARNING récurrent + sémantique fausse. Rend `{data, actions}` — le `Pod`
  émet les actions sur sa transition de retour en `:monitoring`.
  """
  @spec maybe_enter_publishing(map()) :: {map(), [:gen_statem.action()]}
  def maybe_enter_publishing(data) do
    if Fleet.CapProfile.deliverable_mode(data.cap_profile) == "git_native" do
      {put_flag(data), [{{:timeout, :publish_deadline}, publish_deadline_ms(), :fire}]}
    else
      {data, []}
    end
  end

  @doc """
  Lève le flag `:publishing` (le pod redevient `:ready`). Appelé sur `deliverable.published` reçu
  OU sur le fire du `:publish_deadline` (fail-safe). L'annulation du timer est émise en ACTION par
  les appelants (`cancel_publish_deadline_action/0`), pas ici.
  """
  @spec leave_publishing(map()) :: map()
  def leave_publishing(data),
    do: Map.update!(data, :conditions, &MapSet.delete(&1, :publishing))

  @doc """
  Le flag `:publishing` est-il posé ? Gate des logs de levée côté handlers (une levée par deadline
  doit être visible, une levée d'un flag jamais posé ne logge pas).
  """
  @spec publishing?(map()) :: boolean()
  def publishing?(data), do: MapSet.member?(data.conditions, :publishing)

  @doc """
  Action gen_statem d'annulation du generic timeout `:publish_deadline` (= le poser à `:infinity`).
  Émise par les 2 handlers de levée.
  """
  @spec cancel_publish_deadline_action() :: :gen_statem.action()
  def cancel_publish_deadline_action, do: {{:timeout, :publish_deadline}, :infinity, :fire}

  @doc """
  Délai (ms) du fail-safe `:publish_deadline` — config `:fleet_spawner, :publish_deadline_ms`,
  défaut 120 000. Passé ce délai sans `deliverable.published`, le flag est levé quand même (sinon
  le pod resterait jamais-`:ready` donc jamais re-brief — wedge), avec WARNING côté handler.
  """
  @spec publish_deadline_ms() :: non_neg_integer()
  def publish_deadline_ms,
    do: Application.get_env(:fleet_spawner, :publish_deadline_ms, 120_000)

  # Pose le flag dans data.conditions. Primitive MapSet locale : `add_condition/2` (Pod) reste
  # l'accumulateur des jalons de la machine ; ici on ne touche QUE :publishing.
  defp put_flag(data),
    do: Map.update!(data, :conditions, &MapSet.put(&1, :publishing))
end

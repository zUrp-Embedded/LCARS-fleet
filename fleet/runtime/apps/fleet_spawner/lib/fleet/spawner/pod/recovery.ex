defmodule Fleet.Spawner.Pod.Recovery do
  @moduledoc """
  DÉCISION de recovery d'un pod (re)spawné — île de calcul PUR extraite de `Fleet.Spawner.Pod`.

  À partir de la SEULE phase observée dans le `state.json` snapshot (+ le `recovery`/`phase` déjà posé
  dans le state), tranche QUOI relancer au démarrage du Pod, sans jamais porter d'état, de Port, de timer
  ni faire d'I/O :

  - `recovery_action/1` — la phase terminale (`:succeeded`/`:released`/`:killed`) → `:release` (rien à
    relancer) ; tout le reste → `:recreate` (from scratch, session neuve). La recovery NE tente JAMAIS
    `--resume` sur une session morte côté serveur (= pod zombie, prouvé live).
  - `apply_recovery/4` — projette cette décision dans le `state` (`:recreate` laisse la base intacte =
    session neuve ; `:release` grave la phase terminale + le flag de release).
  - `first_continue_for/1` — choisit le PREMIER `{:continue, _}` de l'`init/1` selon le `recovery`/`phase`
    du state (`:recreate` → `:allocate`, `:release` → `:release`, sinon mappe la phase observée).
  - `phase_from_string/1` — décode la phase string du `state.json` en atome existant (`nil` si inconnue).

  Que des opérations de `Map`/`String` déterministes : aucune dépendance externe (pas de `Logger`, pas de
  `File`, pas de TaskQueue). Le `Pod` lui passe `phase`/`state`/`base` en arguments ; le module ne rappelle
  aucun private de `Pod` (pas de cycle). `recover_or_init`/`initial_state`/`deterministic_session_id`
  (constructeur + orchestrateur du démarrage) RESTENT au cœur du `Pod`.

  ## Contrat (appelé par `Pod`)

  - `recovery_action/1` — appelé par `recover_or_init` ; le test `recovery_test.exs` l'exerce DIRECTEMENT
    via `Fleet.Spawner.Pod.Recovery.recovery_action/1` (plus de wrapper délégant côté `Pod`).
  - `apply_recovery/4` — appelé par `recover_or_init` (projette la décision dans le state).
  - `first_continue_for/1` — appelé par `init/1` (premier `{:continue, _}` de la state machine).
  - `phase_from_string/1` — appelé par `recover_or_init` ET `clear_terminal_snapshot`.
  """

  @doc """
  Décision de recovery d'un pod (re)spawné dont un `state.json` snapshot existe.
  PURE, fonction de la seule **phase observée**. Sous `:temporary` le supervisor
  ne ressuscite jamais : c'est un (re)spawn délibéré qui appelle `init/1`, et la
  décision est explicite (pas de reprise implicite
  `first_continue_for(:monitoring)` sur un backend mort).

    * `:release`  — phase terminale (`:succeeded`/`:released`/`:killed`) → rien à relancer.
    * `:recreate` — tout le reste (`:failed`/`:pending`/phase EN VOL `:launching`/
                    `:monitoring`/`:extracting`/`:releasing`/ambiguë) → from scratch,
                    session neuve. Une phase en vol sur un (re)spawn = backend mort
                    (sous `:temporary`) : on reroll. On NE tente PAS de `--resume` sur
                    une session morte côté serveur → claude exit → pod zombie (prouvé
                    live) ; la tâche reste en queue et re-drive un REPL neuf.
  """
  @spec recovery_action(atom()) :: :release | :recreate
  def recovery_action(phase) do
    cond do
      phase in [:succeeded, :released, :killed] -> :release
      true -> :recreate
    end
  end

  # :recreate → fresh, nouvelle session (base intacte : session_id neuf, resume=false).
  def apply_recovery(base, :recreate, _sid, _phase), do: Map.put(base, :recovery, :recreate)

  # :release → terminal ; le pod stoppera proprement (do_release sur backend nil).
  def apply_recovery(base, :release, _sid, phase) do
    base |> Map.put(:phase, phase) |> Map.put(:recovery, :release)
  end

  # Un pod (re)spawné avec un snapshot suit la décision explicite de
  # `recover_or_init`/`recovery_action` : `:recreate` repart de zéro (`:allocate`,
  # session neuve), `:release` s'arrête (phase terminale, rien à relancer). JAMAIS
  # reprendre en `:monitor` sur un backend mort (le supervisor ne ressuscite jamais
  # sous `:temporary`).
  def first_continue_for(%{recovery: :recreate}), do: :allocate
  def first_continue_for(%{recovery: :release}), do: :release
  def first_continue_for(%{phase: :pending}), do: :allocate
  def first_continue_for(%{phase: :launching}), do: :launch
  def first_continue_for(%{phase: phase}), do: phase_to_continue(phase)

  # Bijection phase (nom d'état gen_statem persisté) ↔ point de reprise `:continue`. SOURCE UNIQUE
  # des deux sens : `phase_to_continue/1` (reprise depuis une phase) et `continue_to_phase/1` (nom
  # d'état de départ pour la state machine, appelé par `Pod.init/1`). Tapée UNE fois ici.
  @phases [
    {:allocating, :allocate},
    {:cleaning, :clean},
    {:projecting, :project},
    {:injecting, :inject},
    {:launching, :launch},
    {:monitoring, :monitor},
    {:extracting, :extract},
    {:releasing, :release}
  ]

  # phase persistée → point de reprise. Fallback `:allocate` : une phase inconnue (snapshot d'une
  # version antérieure) repart proprement du début.
  for {phase, continue} <- @phases do
    defp phase_to_continue(unquote(phase)), do: unquote(continue)
  end

  defp phase_to_continue(_), do: :allocate

  @doc """
  Point de reprise `:continue` (sortie de `first_continue_for/1`) → NOM d'état gen_statem de départ.
  INVERSE EXACT de `phase_to_continue/1`. Pas de fallback : `first_continue_for/1` ne produit QUE des
  `:continue` catalogués, donc un atome hors bijection est un bug amont qu'on laisse crasher (visible).
  """
  @spec continue_to_phase(atom()) :: atom()
  for {phase, continue} <- @phases do
    def continue_to_phase(unquote(continue)), do: unquote(phase)
  end

  def phase_from_string(s) when is_binary(s) do
    # String.to_existing_atom/1 rend TOUJOURS un atome (ou raise ArgumentError si l'atome n'existe pas —
    # rattrapé ci-dessous → nil). Pas de `case`/fallback : l'ancien `_ -> nil` était mort (jamais un non-atom).
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  def phase_from_string(_), do: nil
end

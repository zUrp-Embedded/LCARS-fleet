defmodule Fleet.Shutdown.Quiesce do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Zero-dependency daemon quiescence primitive. Admission and respawn paths refuse
  new work while finalizers remain allowed to drain current work. Policy stays in
  `Fleet.Admiral`; this module only owns persistent flags and activity counters.
  """

  @key {__MODULE__, :quiescing}

  @doc "Does the daemon refuse new top-level work (drain in progress)?"
  @spec quiescing?() :: boolean()
  def quiescing?, do: :persistent_term.get(@key, false)

  @doc "Enables quiescence — called by `Shutdown.refuse_new_jobs/1`. Idempotent."
  @spec refuse!() :: :ok
  def refuse! do
    :persistent_term.put(@key, true)
    :ok
  end

  @doc "Lifts quiescence (resumes admission). Idempotent."
  @spec resume!() :: :ok
  def resume! do
    :persistent_term.put(@key, false)
    :ok
  end

  require Logger

  # ── Synchronous-finalizer activity counter (drain visibility) ──
  #
  # The drain's aggregate counts the broker's work-items and the completion offloads —
  # but a finalizer running SYNCHRONOUSLY inside a singleton (the poller tick's
  # review/merge work, a completion handler between event reception and its offload)
  # is invisible to it: three zero reads would conclude :drained while a merge is in
  # flight. `busy/1` makes that window countable. Iron Law kept: an `:atomics` ref,
  # no process (and no per-write `:persistent_term` put — the ref is stored once).

  @busy_key {__MODULE__, :busy}

  @doc false
  # Boot hook (`Fleet.Application.start`, single-threaded): materializes the counter ref
  # before any concurrent first use (two concurrent lazy inits would orphan one ref and
  # undercount its wrap).
  @spec init_busy!() :: :ok
  def init_busy! do
    _ = busy_ref()
    :ok
  end

  @doc """
  Wraps a SYNCHRONOUS finalizer so the drain counts it as in-flight for the wrap's
  duration. Crash-safe: the decrement runs in `after` — a raised finalizer never
  freezes the drain. Returns the fun's result.
  """
  @spec busy((-> result)) :: result when result: var
  def busy(fun) when is_function(fun, 0) do
    ref = busy_ref()
    :atomics.add(ref, 1, 1)

    try do
      fun.()
    after
      :atomics.sub(ref, 1, 1)
    end
  end

  @doc "Number of synchronous finalizers currently inside `busy/1` — summed into the drain's in-flight."
  @spec busy_count() :: non_neg_integer()
  def busy_count do
    case :persistent_term.get(@busy_key, nil) do
      nil -> 0
      ref -> report_if_negative(ref, :atomics.get(ref, 1))
    end
  end

  # ⚠ `max(0, …)` SEUL RENDAIT L'ANOMALIE INDETECTABLE, et c'est le `signed: true` qui le prouve :
  # on a deliberement choisi un compteur capable de descendre sous zero, puis on a efface la seule
  # observation qui en tirait quelque chose. Le clamp est la BONNE reponse cote sortie — un solde
  # negatif veut dire « rien en vol », ce que le drain doit conclure — mais il ne doit pas etre la
  # SEULE. Un desequilibre `add`/`sub` (un `after` joue deux fois, un `sub` sur une ref recreee)
  # faisait mentir ce compteur durablement, sans jamais rien signaler.
  #
  # UNE LIGNE PAR NOUVEAU PLANCHER, jamais une par appel : `busy_count/0` alimente la somme d'en-vol
  # du drain, sur une boucle de POLL. Journaliser a chaque lecture noierait le drain sous une
  # anomalie qui est deja permanente. Le slot 2 porte le plancher deja signale, et
  # `compare_exchange/4` le reclame — deux lecteurs concurrents ne produisent donc qu'UNE ligne.
  #
  # `error` et non `warning` : le compteur ment sur un fait durable, et la doctrine des niveaux du
  # depot reserve `error` a la perte reelle ou a la condition terminale. Ici la perte est celle de
  # l'observabilite du drain lui-meme.
  defp report_if_negative(_ref, raw) when raw >= 0, do: raw

  defp report_if_negative(ref, raw) do
    floor = :atomics.get(ref, 2)

    if raw < floor and :atomics.compare_exchange(ref, 2, floor, raw) == :ok do
      Logger.error(
        "Quiesce: busy_count NEGATIF (#{raw}) — desequilibre add/sub du compteur de quiescence. " <>
          "Le drain lit 0 (« rien en vol »), reponse conservatrice et correcte cote sortie, mais " <>
          "le compteur est FAUX de #{abs(raw)} et le restera : un `busy/1` en vol y sera invisible."
      )
    end

    0
  end

  # DEUX SLOTS : 1 = le compteur, 2 = le plancher negatif deja signale (0 au depart, donc aucune
  # ligne tant que le compteur reste sain).
  defp busy_ref do
    case :persistent_term.get(@busy_key, nil) do
      nil ->
        ref = :atomics.new(2, signed: true)
        :persistent_term.put(@busy_key, ref)
        ref

      ref ->
        ref
    end
  end
end

defmodule Fleet.Spawner.Pod.TaskProbe do
  @moduledoc """
  SONDES de l'état tâche/agent via le `Fleet.TaskQueue` — cluster extrait de `Fleet.Spawner.Pod`.

  Quatre questions best-effort que le cœur du `Pod` (handler de kick, deadline de réponse, enqueue de
  mandat) pose au broker pour DÉCIDER, sans jamais porter d'état ni de timer :

  - `polled?/1` — l'agent a-t-il déjà appelé `get_task` (ACK in-band réel, `last_poll`) ? Stoppe le kick
    bootstrap dès que le REPL répond. Prend le `state` (lit l'override test `:polled_fun` puis `state.pod_id`).
  - `pod_has_active_task?/1` — le pod a-t-il une task ACTIVE (`pending|assigned|in_progress`) là, maintenant ?
    Au fire de `:result_deadline` : oui = vrai timeout de réponse (kill) ; non = idle, on laisse lapser.
  - `mandate_pulled?/1` — le mandat est-il déjà pull (`assigned|in_progress|completed`) ? Stoppe la boucle de wake.
  - `no_pending_mandate?/1` — AUCUN mandat en attente (`{:ok, nil}`, jamais enqueué) ? Distingue le pod
    permanent/interactif (bootstrap) du worker (mandat `pending` au spawn).

  Les trois dernières prennent le `pod_id` (string) ; toutes lisent `Fleet.TaskQueue.pod_status/last_poll`
  derrière une garde `rescue`/`catch :exit` qui ramène `false` — un hoquet du broker (down/restarting,
  GenServer.call qui EXIT) ne doit PAS crasher le pod. Aucun state propre, aucun Port, aucun timer, aucune
  écriture FS : que des lectures best-effort. Le `Pod` passe `pod_id`/`state` en arguments — le module ne
  rappelle aucun private de `Pod`. Dépend de `Fleet.TaskQueue` (déjà une dep de l'app) et de la config
  `:fleet_spawner` (override test `:polled_fun`) ; aucune dépendance vers `Fleet.Spawner.Pod` (pas de cycle).
  Ces sondes ne loggent pas (pas de `Logger`) : elles décident, le cœur du `Pod` trace.

  ## Contrat (appelé par `Pod`)

  - `polled?/1` — bootstrap-stop du kick (handler `handle_info({:kick_attempt, n}, ...)`).
  - `pod_has_active_task?/1` — `pod_info` (`has_active_task`) + fire de `:result_deadline`.
  - `mandate_pulled?/1` — réduit en booléen passé à `Kick.acked?/3` par le handler.
  - `no_pending_mandate?/1` — détection bootstrap (handler) + gate de `maybe_enqueue_mandate`.
  """

  # L'agent a-t-il POLLÉ (appelé get_task) ? = ACK in-band RÉEL : l'agent a tendu la main via l'API
  # officielle (last_poll, tracké par le TaskQueue), pas un proxy host-side comme un
  # `pgrep watch.sh` (« le process existe » ≠ « l'agent agit »). Sert à stopper le kick bootstrap dès que
  # l'agent est up. Override test : `:polled_fun`.
  def polled?(%{pod_id: pod_id} = state) when is_binary(pod_id) do
    case Map.get(state, :polled_fun) || Application.get_env(:fleet_spawner, :polled_fun) do
      fun when is_function(fun, 1) -> fun.(state)
      _ -> Fleet.TaskQueue.last_poll(pod_id) != nil
    end
  rescue
    _ -> false
  catch
    # `last_poll` est un GenServer.call → TaskQueue down/restarting EXIT (ne raise pas), `rescue` ne
    # l'attrape pas. MÊME garde que mandate_pulled?/no_pending_mandate? : un hoquet broker ne crashe PAS le pod.
    :exit, _ -> false
  end

  def polled?(_), do: false

  # Le pod a-t-il une task ACTIVE (pending/assigned/in_progress) là, maintenant ?
  # Utilisé au FIRE de :result_deadline : oui = vrai timeout de réponse (kill) ; non =
  # le pod attendait juste sa prochaine task (idle), on laisse lapser. Même source que
  # mandate_pulled?/no_pending_mandate? (TaskQueue.pod_status), même garde rescue/catch
  # (TaskQueue indisponible ⇒ pas de task active connue ⇒ pas de kill, fail-safe).
  def pod_has_active_task?(pod_id) do
    case Fleet.TaskQueue.pod_status(pod_id) do
      {:ok, s} when s in [:pending, :assigned, :in_progress] -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Le mandat est-il déjà pull par le pod ? « Pull » = la task est dans un état qui
  # PROUVE que claude a appelé get_task : `:assigned | :in_progress | :completed`.
  # Volontairement PAS : `:pending`/`nil` (pas encore pull / pas encore enqueué — on
  # continue de kicker, ce qui couvre aussi la race spawn↔enqueue), ni `:cleared`/`:failed`
  # (kill délibéré / deadline broker — le pod n'a rien pull, ne PAS arrêter le kick sur
  # un faux « pull » ; au pire on kicke jusqu'au cap, harmless, le result_deadline couvre).
  # Best-effort : exception/exit broker → false (on retentera). Sert à ARRÊTER la boucle.
  def mandate_pulled?(pod_id) do
    case Fleet.TaskQueue.pod_status(pod_id) do
      {:ok, s} when s in [:assigned, :in_progress, :completed] -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # AUCUN mandat (task) en attente pour ce pod : `pod_status == {:ok, nil}` (jamais enqueué).
  # Distingue le pod permanent/interactif (rien à puller à froid → bootstrap) du worker (mandat
  # `pending` enqueué au spawn). En cas d'erreur → `false` (défaut sûr : on traite comme un
  # worker, kick fréquent — on ne suspend pas par erreur les kicks d'un vrai mandat).
  def no_pending_mandate?(pod_id) do
    case Fleet.TaskQueue.pod_status(pod_id) do
      {:ok, nil} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end

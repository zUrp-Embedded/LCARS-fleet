defmodule Fleet.Spawner.Pod.TaskProbe do
  @moduledoc """
  SONDES de l'état tâche/agent via le `Fleet.TaskQueue` — cluster extrait de `Fleet.Spawner.Pod`.

  Quatre questions best-effort que le cœur du `Pod` (handler de kick, deadline de réponse, enqueue de
  brief) pose au broker pour DÉCIDER, sans jamais porter d'état ni de timer :

  - `polled?/1` — l'agent a-t-il déjà appelé `get_work_item` (ACK in-band réel, `last_poll`) ? Stoppe le kick
    bootstrap dès que le REPL répond. Prend le `state` (lit `state.pod_id`).
  - `pod_has_active_task?/1` — le pod a-t-il une task ACTIVE (`pending|assigned|in_progress`) là, maintenant ?
    Au fire de `:result_deadline` : oui = vrai timeout de réponse (kill) ; non = idle, on laisse lapser.
  - `brief_pulled?/1` — le brief est-il déjà pull (`assigned|in_progress|completed`) ? Stoppe la boucle de wake.
  - `no_pending_brief?/1` — AUCUN brief en attente (`{:ok, nil}`, jamais enqueué) ? Distingue le pod
    permanent/interactif (bootstrap) du worker (brief `pending` au spawn).

  Les trois dernières prennent le `pod_id` (string) ; toutes lisent `Fleet.TaskQueue.pod_status/last_poll`
  derrière une garde `rescue`/`catch :exit` qui ramène `false` — un hoquet du broker (down/restarting,
  GenServer.call qui EXIT) ne doit PAS crasher le pod. Aucun state propre, aucun Port, aucun timer, aucune
  écriture FS : que des lectures best-effort. Le `Pod` passe `pod_id`/`state` en arguments — le module ne
  rappelle aucun private de `Pod`. Dépend de `Fleet.TaskQueue` (déjà une dep de l'app) ; aucune dépendance
  vers `Fleet.Spawner.Pod` (pas de cycle). Ces sondes ne loggent pas (pas de `Logger`) : elles décident,
  le cœur du `Pod` trace.

  ## Contrat (appelé par `Pod`)

  - `polled?/1` — bootstrap-stop du kick (handler `handle_event({:timeout, :kick}, {:attempt, n}, ...)`).
  - `pod_has_active_task?/1` — `pod_info` (`has_active_task`) + fire de `:result_deadline`.
  - `brief_pulled?/1` — réduit en booléen passé à `Kick.acked?/3` par le handler.
  - `no_pending_brief?/1` — détection bootstrap (handler) + gate de `maybe_enqueue_brief`.
  """

  # L'agent a-t-il POLLÉ (appelé get_work_item) ? = ACK in-band RÉEL : l'agent a tendu la main via l'API
  # officielle (last_poll, tracké par le TaskQueue), pas un proxy host-side comme un
  # `pgrep watch.sh` (« le process existe » ≠ « l'agent agit »). Sert à stopper le kick bootstrap dès que
  # l'agent est up.
  def polled?(%{pod_id: pod_id}) when is_binary(pod_id) do
    Fleet.TaskQueue.last_poll(pod_id) != nil
  rescue
    _ -> false
  catch
    # `last_poll` est un GenServer.call → TaskQueue down/restarting EXIT (ne raise pas), `rescue` ne
    # l'attrape pas. MÊME garde que brief_pulled?/no_pending_brief? : un hoquet broker ne crashe PAS le pod.
    :exit, _ -> false
  end

  def polled?(_), do: false

  # pod_status best-effort : un hoquet du broker (down/restart, GenServer.call qui EXIT) rend `:error`
  # au lieu de crasher — comme `:error` ne matche aucun `{:ok, _}`, chaque sonde retombe sur `false`
  # (même table de vérité que l'ancien rescue/catch inline). Source unique des 3 sondes pod_status
  # ci-dessous ; `polled?` n'utilise PAS ce helper (il lit `last_poll`, avec sa propre garde).
  defp safe_pod_status(pod_id) do
    Fleet.TaskQueue.pod_status(pod_id)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Le pod a-t-il une task ACTIVE (pending/assigned/in_progress) là, maintenant ?
  # Utilisé au FIRE de :result_deadline : oui = vrai timeout de réponse (kill) ; non =
  # le pod attendait juste sa prochaine task (idle), on laisse lapser. Même source que
  # brief_pulled?/no_pending_brief? (TaskQueue.pod_status via safe_pod_status), même
  # fail-safe (TaskQueue indisponible ⇒ `:error` ⇒ pas de task active connue ⇒ pas de kill).
  def pod_has_active_task?(pod_id),
    do: match?({:ok, s} when s in [:pending, :assigned, :in_progress], safe_pod_status(pod_id))

  # Le brief est-il déjà pull par le pod ? « Pull » = la task est dans un état qui
  # PROUVE que claude a appelé get_work_item : `:assigned | :in_progress | :completed`.
  # Volontairement PAS : `:pending`/`nil` (pas encore pull / pas encore enqueué — on
  # continue de kicker, ce qui couvre aussi la race spawn↔enqueue), ni `:cleared`/`:failed`
  # (kill délibéré / deadline broker — le pod n'a rien pull, ne PAS arrêter le kick sur
  # un faux « pull » ; au pire on kicke jusqu'au cap, harmless, le result_deadline couvre).
  # Best-effort : exception/exit broker → false (on retentera). Sert à ARRÊTER la boucle.
  def brief_pulled?(pod_id),
    do: match?({:ok, s} when s in [:assigned, :in_progress, :completed], safe_pod_status(pod_id))

  # AUCUN brief (task) en attente pour ce pod : `pod_status == {:ok, nil}` (jamais enqueué).
  # Distingue le pod permanent/interactif (rien à puller à froid → bootstrap) du worker (brief
  # `pending` enqueué au spawn). En cas d'erreur → `false` (défaut sûr : on traite comme un
  # worker, kick fréquent — on ne suspend pas par erreur les kicks d'un vrai brief).
  def no_pending_brief?(pod_id),
    do: match?({:ok, nil}, safe_pod_status(pod_id))
end

defmodule Fleet.Pilot.Poller.Reconciliation do
  @moduledoc """
  IMPURE "orphan reconciliation" cluster of `Fleet.Pilot.Poller` — TWO symmetric duties on the
  same tick, the same suspect set and the same 2-tick grace:

  **(1) Orphaned lock** (label without pod). A `lcars-in-flight` lock is ORPHANED if the brick
  carries it but no live pod is WORKING it. Two causes: a dead pod (`:result_timeout` deadline, crash,
  BEAM restart) reaped by the PodWarden — which removes the PROCESS but NOT the forge label — OR a
  PARKED pod: one spawned + locked + briefed whose wake never LANDED (`wake_unreached`, and the pod's
  ack-driven kick loop exhausted), so the agent never pulled its task. "Working" is proven by a
  PULLED task (`pod_pull_state/2`), not merely an enqueued `:pending` one: a never-pulled admission owns
  no lock, else a parked pod (task active-but-`:pending`) would mask its lock forever — a silent
  wedge the reconciliation could not tell from real work. Broken symmetry → without repair the
  `dispatch_*` skips the `:in_flight` brick FOREVER (a single pod stall wedges the pipe). Repair:
  reclaim (remove the label) the CONFIRMED orphans → the next tick re-dispatches (re-attempting the
  activation of a still-alive parked pod, or a fresh spawn if it died).

  **(2) Quiesced pod** (pod without lock — the inverse). A live PER-BRICK pod whose brick no longer
  holds the lock and which has no active task has no reason to live: a one-shot never "ends itself"
  — the pod model is a persistent interactive PTY — so without this reap it idles at the prompt
  INDEFINITELY and gets re-briefed by the next dispatch. **This reap IS the lifetime mechanism**,
  not a belt over some other cap. It is the NOMINAL end-of-life of per-brick pods.

  ## What this module does / does NOT do

  It READS 5 seams (`%Seams{}`) and yields the NEW set of suspects (`MapSet.t()`) — it WRITES no
  poller state. The **2-tick grace** (only accumulate a suspect over two consecutive ticks) and
  the **cross-repo aggregation** (`MapSet.union` of the suspects of all the repos of a tick) are
  CROSS-TICK state: they STAY at the core (`Fleet.Pilot.Poller` — `do_poll`/`step_do_poll` passes
  THIS repo's subset of the previous tick's suspects as `prior_suspects` and re-writes the yielded
  set into the state).

  ## 2-REGULAR-tick grace + REPO-QUALIFIED refs (load-bearing semantics)

  We only reclaim a CONFIRMED orphan: `reconcile/6` intersects the orphans seen THIS tick with
  `prior_suspects` (the orphans seen at the PREVIOUS tick) — never a freshly dispatched pod (not
  yet registered) or one in the process of dying. The grace unit is the REGULAR tick (~30s):
  webhook kick-polls are dispatch-only and NEVER call `reconcile/6` (counting them would compress
  the ~60s grace to the webhook rate — reclaim mid-publication, double dispatch).
  The lock refs are REPO-QUALIFIED (`{repo, :issue|:pr, n}`): the key carries the repo, so the
  refs of the live pods (`owned`, scoped to the current repo) and the suspects (repo-scoped by
  the caller) cannot collide on the number alone. An orphan #N/repoA is not masked by
  a live pod #N/repoB, and the grace does not contaminate across repos.

  ## Fail-safe

  If the enumeration of live pods fails (`live_owned_refs/2 → :error`), we reclaim NOTHING and
  keep `prior_suspects` as is — NEVER unlock blindly.

  ## Policy on `unknown`

  Both duties act destructively — a lock reclaim re-dispatches, a reap kills — so an UNREADABLE
  ownership must never read as an ABSENCE of ownership:

    * A broker that CANNOT BE ASKED — `pod_status/1` exits or raises — is `:unknown`. Never `false`,
      never `[]`. `pod_task_state/2` defers the reap; `pod_pull_state/2` makes `live_owned_refs/2`
      answer `:error`, which the fail-safe above turns into "reclaim nothing this cycle".
    * A broker that ANSWERED is a measured fact, `[]` and `{:ok, nil}` included: out of scope, no
      active task, terminal state. Those DO release ownership — that is the orphan this duty exists
      to collect.
    * A seam MODULE that does not export the function is neither: it is a compile-time capability,
      identical on every tick (a test stub), so it stays a measured empty and not indeterminacy.
      Reading it as `:unknown` would make every cycle `:error` under such a stub, i.e. a
      reconciliation that never reclaims anything.

  The confirmation delay is the caller's ~60 s grace (`prior_suspects` must survive two cycles);
  `unknown` does not consume it — the cycle simply declares no orphan.

  ## Boundary: explicit seams struct (not the whole `state`)

  The cluster reads a NARROW, TYPED struct of seams, never the whole poller `state` — that would be
  a boundary leak. `@enforce_keys` forces the fields at the call site, and reaching for a field the
  struct does not carry DOES NOT COMPILE; a bare map would let the same access pass in silence. The
  caller resolves the prod defaults at ITS site, so the cluster receives already-resolved modules.

  The kill goes through a SINGLE authority, never forked here.
  """

  alias Fleet.Forge.Payload

  require Logger

  # workflow_run lock: single source `Fleet.Labels` (compile-time constant). SAME source as
  # `Lease`'s `@in_flight` (kept there for the fast-path `classify_issue`) — not a fork of a
  # literal, the authority stays `Labels.in_flight/0`.
  @in_flight Fleet.Labels.in_flight()

  # The PULLED work-item states — the durable proof an executor ACTIVATED (get_work_item transitions
  # `:pending → :assigned` and records the in-band ACK). ONE source for both ownership reads
  # (`pod_pull_state/2` and `gate_eval_owned_refs/2`): a `:pending` admission (enqueued, never pulled — the
  # wake was lost) owns nothing, on either side.
  @pulled_states [:assigned]

  # CE QUE CETTE LISTE PORTE POUR LES AUTRES — et c'est une nature de couture sans equivalent dans
  # ce depot : un FOURNISSEUR qui porte une garantie sans appel pour la lui rappeler. Trois modules
  # lisent la propriete de verrou sur cette regle, aucun ne l'appelle : ils la CITENT en commentaire
  # et raisonnent dessus. Changer `@pulled_states` sans les relire casse leur raisonnement en
  # silence — aucun test ne les relie, aucun appel ne les traverse.
  #
  # La declaration ci-dessous ferme ce trou : le fournisseur nomme ses dependants, et le mur
  # `reconciliation.pulled_states_declared` la garde vraie DANS LES DEUX SENS — un dependant qui
  # cesse de dependre sort de la liste, un nouveau qui apparait doit y entrer.
  @pulled_states_dependents [
    "lib/fleet/pilot/step_run_consumer/gatekeeper_escalation.ex",
    "lib/fleet/pilot/step_dispatcher/spawn.ex",
    "lib/fleet/task_queue/server.ex"
  ]

  @doc """
  Les fichiers qui s'appuient sur `@pulled_states` sans l'appeler.

  Existe pour que la garantie soit LISIBLE cote fournisseur : une valeur est la seule forme qu'un
  mur puisse lire sans deviner, et un commentaire ne se verifie pas. Ne sert a rien au runtime, et
  c'est assume — son lecteur est le gate.
  """
  @spec pulled_states_dependents() :: [String.t()]
  def pulled_states_dependents, do: @pulled_states_dependents

  defmodule Seams do
    @moduledoc """
    Reconciliation boundary contract: the 5 seams (and NOTHING else) that `reconcile/6` reads.
    `@enforce_keys` forces the 5 fields at construction; an access `seams.<other_field>` does not compile
    — the cluster never receives the poller's whole `state`. `spawner`/`task_queue` are already
    RESOLVED by the caller (prod defaults `Fleet.Spawner`/`Fleet.TaskQueue` applied at its site).
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Forge.Client`).
            forge: module(),
            # Injected spawner, ALREADY resolved by the caller (seam `:spawner`, prod default `Fleet.Spawner`).
            spawner: module(),
            # Injected broker, ALREADY resolved by the caller (seam `:task_queue`, prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # `owner/name` of the current repo (the lock refs are repo-qualified there).
            repo: String.t(),
            # Forge opts (base_url/token…) passed to the ForgeClient (`remove_label`).
            forge_opts: keyword()
          }
  end

  @doc """
  Reconciles the orphaned `lcars-in-flight` locks of the repo `seams.repo` and yields the NEW set of
  suspects (`MapSet.t()` of repo-qualified refs `{repo, :issue|:pr, n}`).

  `prior_suspects` = THIS repo's orphans seen at the PREVIOUS regular tick (2-tick grace, carried
  by the core — the caller passes the repo-scoped subset, never the whole cross-repo union: the
  union let an error branch resurrect suspects resolved on other repos). Side effect: removes the
  forge label (`reclaim_lock/2`) of the CONFIRMED orphans (seen at both ticks). The yielded set =
  the orphans of THIS tick not yet reclaimed (those awaiting their 2nd confirmation).

  Fail-safe: if the enumeration of the pods fails (`:error`), yields `prior_suspects` unchanged (reclaims
  nothing blindly).
  """
  @spec reconcile(list(map()), list(map()), MapSet.t(), MapSet.t(), Seams.t(), [map()] | :error) ::
          MapSet.t()
  def reconcile(issues, pulls, pr_issue_ids, prior_suspects, %Seams{} = seams, pods) do
    # UN SEUL `list_pods` par passe (BL-6-40 Phase 1). Per duty it would be 2 + N: two duties call
    # it, and `lock_diagnosis` once PER candidate lock. Each call is a `GenServer.call` at a 5 s
    # timeout to the Spawner — so a single wedged pod costs 5 s x (2 + N) x repo_count per tick,
    # and nothing says so (which is exactly what Phase 0 makes measurable).
    #
    # The snapshot is DATA, not a seam: it travels as an explicit parameter rather than entering
    # `%Seams{}`, whose contract is "the 5 seams reconcile/6 READS" and not "what it has read".
    # Adding it there would have made the struct carry a cache.
    #
    # The fail-safe lives here: an impossible enumeration yields `:error` and the whole pass
    # reclaims nothing — exactly what `live_owned_refs` answers on its own, with the three
    # consumers covered by the same read.
    case pods do
      {:error, _reason} ->
        prior_suspects

      pods when is_list(pods) ->
        reconcile_with_pods(issues, pulls, pr_issue_ids, prior_suspects, seams, pods)
    end
  end

  @doc """
  Photo UNIQUE des pods vivants, prise par le TICK et descendue en parametre (BL-6-40).

  Prise dans `reconcile/6`, elle le serait une fois par REPO — R appels `GenServer.call` a 5 s de
  timeout pour une donnee qui ne change pas utilement d'un repo a l'autre du meme tick. L'appelant
  la prend une fois avant sa boucle.

  Publique parce que l'appelant est dans un AUTRE module (`Fleet.Pilot.Poller`) : c'est le prix
  de sortir la lecture du callee. Le fail-safe reste ICI et pas chez l'appelant — `:error` fait
  que la passe entiere ne reclame rien, et cette regle appartient a la reconciliation, pas au
  poller qui ne fait que la declencher.
  """
  @spec snapshot_pods(module()) :: [map()] | {:error, term()}
  def snapshot_pods(spawner) do
    spawner.list_pods()
  rescue
    e -> {:error, e}
  catch
    kind, why -> {:error, {kind, why}}
  end

  defp reconcile_with_pods(issues, pulls, pr_issue_ids, prior_suspects, %Seams{} = seams, pods) do
    case live_owned_refs(seams, pods) do
      # Pod enumeration unavailable → fail-safe: we reclaim NOTHING (never unlock
      # blindly), we keep the suspects as is.
      :error ->
        prior_suspects

      owned ->
        repo = seams.repo

        # NB: we do NOT derive the PR lock from the ownership of the ISSUE.
        # Naive temptation: "a PR whose parent issue is owned is owned too". TWO reasons it stays wrong:
        #  (1) a DELIVERED engineer would protect the PR lock of a DEAD JUDGE (the PR lock in review belongs
        #      to the judge, not the producer) → judge never re-dispatched = WALL. The PR-lock churn
        #      during a REAL producer rework is minor and
        #      self-heals (serialize `:role_busy` prevents the double-spawn).
        #  (2) `pod_task_state/2` does not count `:completed` as active: `:completed` is
        #      TERMINAL (`WorkItem.active?/1`) — a delivered engineer's completion (push → open PR →
        #      unlock) is running-or-done, its lock is released at the END. Counting it as active would
        #      mask an orphaned ISSUE lock FOREVER when the completion is LOST before open_pr (permanent
        #      silent wedge). The legitimate publication window (push ≤30s) is covered by the 2-REGULAR-tick
        #      grace (~60s at the 30s interval — webhook kick-polls never enter reconcile, so the forge
        #      traffic of the completion sequence itself cannot compress this window)
        #      + the idempotent completion sequence (a late reclaim = a harmless replay), so excluding
        #      `:completed` reclaims the lost-completion orphan WITHOUT churning the nominal window.

        # REPO-QUALIFIED orphans (`{repo, :issue|:pr, n}`): the lock key carries the repo, so
        # `owned` (repo-scoped refs of the live pods of THIS repo) and `prior_suspects` (cross-tick,
        # repo-scoped by the caller) cannot collide on the number alone. An orphan #N/repoA is not
        # masked by a live pod #N/repoB, and the 2-tick grace does not contaminate across repos.
        issue_orphans =
          for i <- issues,
              n = i["number"],
              locked?(i),
              # an issue with an open PR is in JUDGE phase (lock on the PR side) → not an issue orphan
              not MapSet.member?(pr_issue_ids, n),
              not MapSet.member?(owned, {repo, :issue, n}),
              into: MapSet.new(),
              do: {repo, :issue, n}

        pr_orphans =
          for p <- pulls,
              n = p["number"],
              locked?(p),
              not MapSet.member?(owned, {repo, :pr, n}),
              into: MapSet.new(),
              do: {repo, :pr, n}

        # SYMMETRIC duty — the INVERSE orphan (pod without lock): a live per-brick pod whose
        # brick is quiesced. Same suspect set, same 2-tick grace: the entries are tagged
        # `{repo, :pod, pod_id}` — the same 3-tuple shape as the lock refs, so the core's
        # repo-filter (`fn {r, _type, _n} -> r == repo end`) threads them with ZERO plumbing.
        zombie_pods = quiesced_brick_pods(issues, pulls, seams, pods)

        orphaned_now = issue_orphans |> MapSet.union(pr_orphans) |> MapSet.union(zombie_pods)
        to_act = MapSet.intersection(orphaned_now, prior_suspects)

        # A FAILED reclaim STAYS a suspect: dropping it with the acted set would force a fresh
        # 2-tick re-suspicion before the retry (the label is still there, but the grace restarts) —
        # the honest retry is the NEXT tick, since the orphan was already confirmed once. Reap
        # failures keep the self-heal-by-re-suspicion path (safe_kill swallows by design; the pod
        # resurfaces in the scan next tick).
        failed_reclaims =
          to_act
          |> Enum.filter(fn
            {_repo, :pod, pod_id} ->
              # `_ =` EXPLICITE, et ce n'est pas un reflexe de style : depuis JG-120 le reap rend un
              # verdict classe, donc l'ignorer est un CHOIX qui doit se voir (dialyzer le dit sous
              # `unmatched_return`). Le choix est celui du paragraphe ci-dessus — un reap rate ne
              # devient pas un suspect retenu, il se repare par re-suspicion au tick suivant — et
              # son echec est deja TRACE dans `reap_pod/2`. Ce qui serait faux, c'est de le jeter
              # en silence maintenant qu'il existe.
              _ = reap_pod(seams, pod_id)
              false

            {_repo, _type, n} ->
              reclaim_lock(seams, n, lock_diagnosis(seams, n, pods)) == :failed
          end)
          |> MapSet.new()

        orphaned_now |> MapSet.difference(to_act) |> MapSet.union(failed_reclaims)
    end
  end

  # SYMMETRIC duty — the inverse orphan: a LIVE per-brick pod (pod_id encodes `-issue-N-`/`-pr-N-`
  # — judges, one-shot gatekeepers; resident/permanent pods carry no brick ref → structurally
  # exempt, their lifecycle is elsewhere: slot-freeze for the resident eng, forever for the
  # permanents) whose brick no longer holds the `lcars-in-flight` lock (verdict consumed,
  # awaits-arch park, merge done, brick closed) AND which holds no active task (belt — same
  # authority `pod_task_state/2` as the lock duty: a gatekeeper mid-eval is never reaped).
  #
  # Fail-safe : un echec d'enumeration rend un ensemble VIDE — on ne tue jamais a l'aveugle.
  defp quiesced_brick_pods(issues, pulls, %Seams{} = seams, pods) do
    locked_issues = for i <- issues, locked?(i), into: MapSet.new(), do: i["number"]
    locked_prs = for p <- pulls, locked?(p), into: MapSet.new(), do: p["number"]

    pods
    |> Enum.flat_map(fn pod ->
      pod_id = pod[:pod_id]

      case parse_pod_ref(pod_id, seams.repo) do
        [{repo, phase, n}] ->
          locked? =
            (phase == :issue and MapSet.member?(locked_issues, n)) or
              (phase == :pr and MapSet.member?(locked_prs, n))

          # Reap ONLY on an ESTABLISHED idle. `:unknown` (the queue did not answer) defers to the
          # next tick — see `pod_task_state/2` for why an uncertain pod is never classed dead.
          if locked? or pod_task_state(seams.task_queue, pod_id) != :idle,
            do: [],
            else: [{repo, :pod, pod_id}]

        _ ->
          []
      end
    end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  # The reap is the NOMINAL end-of-life of a per-brick pod (a one-shot never
  # "ends itself", cf. quiesced_brick_pods) → `info`, not warning (≠ reclaim_lock, which flags an
  # ANOMALY). Kill via the SINGLE authority `Spawn.safe_kill/2` (no fork of the kill wrapper);
  # a kill that fails is swallowed there — the next tick re-suspects, self-healing.
  # ⚠ NE PAS ANNONCER « reaped » AU PASSE AVANT L'APPEL. Une telle ligne est vraie de l'INTENTION et
  # jamais du fait : `safe_kill/2` avale par conception, et le seul lecteur de cette flotte — un
  # operateur qui grep `reaped` — lirait un kill accompli la ou il n'y a qu'un kill tente.
  #
  # L'avalement RESTE (le tick suivant re-suspecte et retente, c'est l'arbitrage du site appelant).
  # Ce qui compte, c'est que la trace SUIVE l'acte au lieu de le preceder, et qu'elle dise lequel des
  # trois etats a eu lieu. `{:error, :not_found}` n'est PAS un echec : le pod n'est plus la, le
  # devoir est accompli — le confondre avec un kill rate ferait crier la trace sur le cas nominal
  # d'une course benigne.
  defp reap_pod(%Seams{spawner: spawner, repo: repo}, pod_id) do
    outcome = Fleet.Pilot.StepDispatcher.Spawn.safe_kill(spawner, pod_id)

    case outcome do
      :ok ->
        Logger.info(
          "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} " <>
            "(brick unlocked, no active task) → REAPED (a re-dispatch re-spawns fresh)"
        )

      {:error, :not_found} ->
        Logger.info(
          "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} — already gone when the " <>
            "kill landed (nothing to do, the duty is satisfied)"
        )

      other ->
        Logger.warning(
          "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} but the kill did NOT " <>
            "land (#{inspect(other)}) — NOT reaped; the next tick re-suspects and retries " <>
            "(self-healing, nothing is blocked)"
        )
    end

    outcome
  end

  # Refs `{repo, :issue|:pr, n}` that a pod is REALLY working, derived from the deterministic STABLE pod_ids
  # (`<repo-slug>-issue-<n>-<role>` / `<repo-slug>-pr-<n>-<role>`; no timestamp suffix).
  # Filters by **active task** (TaskQueue): a lock is legitimately held ONLY while a pod has an active
  # task on it. A LIVE but IDLE pod (long-lived between two reworks, e.g. the engineer) does NOT "own"
  # the lock — otherwise it would mask a DEAD judge and the reconciliation would never reclaim (wedge).
  # `:error` if the enumeration fails (fail-safe: we reclaim nothing blindly).
  #
  # REPO SCOPE: we keep ONLY the pods of `seams.repo` (prefix `PodId.scope_prefix/1`), and the ref
  # yielded CARRIES the repo (`{repo, :issue|:pr, n}`). Without this, a live pod #N/repoB would "own" the global
  # ref `{:issue, N}` → it would MASK the orphan #N/repoA (lock never reclaimed = wedge) AND the 2-tick
  # grace would contaminate cross-repo (double-spawn). The REPO-QUALIFIED lock key = the real identity.
  #
  # A brick under GATEKEEPER EVAL is owned TOO: during the eval (a claude turn = minutes),
  # the PRODUCER pod is done (dead one-shot or idle) and the GATEKEEPER carries the eval task under a
  # pod_id `permanent-*` (no repo slug) → without `gate_eval_owned_refs`, the ref would look orphaned
  # and the 2-tick grace (~60s) would RECLAIM it mid-eval → re-dispatch of the concurrent step (double
  # workflow_run + ghost verdict on return). The union is done INSIDE the try: a failure to enumerate the
  # evals makes `:error` → the fail-safe "reclaim nothing" covers both sources.
  defp live_owned_refs(%Seams{task_queue: tq, repo: repo}, pods) do
    # ⚠ L'IGNORANCE SE PROPAGE, ELLE NE SE REPLIE PAS EN ABSENCE. Le fail-safe de cette fonction est
    # « un cycle qui ne voit pas tous les pods ne declare aucun orphelin » — et des `rescue` places
    # dans les helpers l'ANNULENT : une file redemarree revient alors en « ce pod ne possede rien »,
    # son verrou passe orphelin, et la reconciliation reclame un verrou tenu par un pod VIVANT,
    # re-dispatche le ticket, puis tue l'original.
    #
    # ⚠ ET RENDRE `:unknown` DEPUIS LES HELPERS NE MARCHE PAS : dans un `Enum.filter` il est TRUTHY,
    # donc le pod indetermine compterait comme POSSEDANT — l'inverse de l'intention. L'indetermination
    # doit voyager dans une forme que l'appelant DESTRUCTURE, et court-circuiter : un seul pod inconnu,
    # et le cycle entier est `:error`.
    #
    # ⚠ LA PROPRIETE EXIGE UNE TACHE TIREE, pas seulement enfilee (`@pulled_states`). Une tache
    # enfilee mais jamais tiree est une admission dont le reveil n'a jamais ATTERRI : le pod est
    # PARKE, pas au travail. C'est un etat « actif », donc le compter comme propriete laisserait un
    # pod parke masquer son verrou POUR TOUJOURS. Le pull est l'ACK durable que le reveil a atterri.
    pod_refs =
      Enum.reduce_while(pods, MapSet.new(), fn pod, acc ->
        pod_id = pod[:pod_id]

        case pod_pull_state(tq, pod_id) do
          :unknown ->
            {:halt, :error}

          :not_pulled ->
            {:cont, acc}

          :pulled ->
            case owned_refs_for_pod(pod_id, repo, tq) do
              :unknown -> {:halt, :error}
              {:ok, refs} -> {:cont, MapSet.union(acc, MapSet.new(refs))}
            end
        end
      end)

    case pod_refs do
      :error -> :error
      %MapSet{} -> MapSet.union(pod_refs, gate_eval_owned_refs(tq, repo))
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # G1 — refs owned by the ACTIVE GATEKEEPER EVALS of the broker. The source of truth already exists:
  # the eval task metadata is self-describing: it carries `gate_eval: true` + `resume_n` (issue number)
  # + `resume_payload.repository.full_name` (repo — multi-project: an eval of repoB does NOT own a
  # ref of repoA). Meme regle `@pulled_states` que pour les pods : une evaluation enfilee mais jamais
  # tiree est une admission SANS executant, et la compter comme propriete garderait le verrou pour
  # toujours au nom d'une evaluation que personne ne joue.
  #
  # TROC ASSUME : une evaluation tout juste enfilee peut depasser la grace et faire churner son
  # verrou — reclaim puis re-escalade, un rejeu inoffensif. Du churn transitoire contre un blocage
  # silencieux PERMANENT.
  #
  # ⚠ `function_exported?` REND CES VERROUS RECLAMABLES, ET CE N'EST PAS LE SENS SUR : c'est une
  # decision. Une fonction absente est une CAPACITE du module, decidee a la compilation et identique
  # a chaque tick — un stub de test, jamais une panne d'execution.
  defp gate_eval_owned_refs(tq, repo) do
    if Fleet.Opts.exported?(tq, :list_active, 0) do
      for %{metadata: meta, state: item_state} <- tq.list_active(),
          item_state in @pulled_states,
          meta["gate_eval"] == true,
          Payload.repository_full_name(meta["resume_payload"]) == repo,
          n = meta["resume_n"],
          is_integer(n),
          into: MapSet.new(),
          do: {repo, :issue, n}
    else
      MapSet.new()
    end
  end

  # Refs that an ACTIVE pod owns. Per-issue (instance): derived from the pod_id (`-issue-N-` / `-pr-N-`).
  # SLOT-FREEZE — project pipe (pod_id `<repo>-engineer`, NO `-issue-N-`): parse_pod_ref yields [] (its
  # id does not encode the brick), so we derive the brick from its ACTIVE TASK (`issue_id` = `issue-N`).
  # Otherwise the poller thinks the resident eng owns NO lock -> reclaims its own -> loops.
  defp owned_refs_for_pod(pod_id, repo, tq) do
    case parse_pod_ref(pod_id, repo) do
      [] -> project_pod_owned_refs(pod_id, repo, tq)
      refs -> {:ok, refs}
    end
  end

  # A project-scoped pod of THIS repo (scope prefix) owns the ref of its active task (`issue-N` ->
  # {repo, :issue, N}). Keeps the repo SCOPE: an eng of another repo does not own a ref of seams.repo.
  # `{:ok, refs}` = a MEASURED answer, `[]` included — out of this repo's scope, no active issue, an
  # unparseable issue_id: three facts, all of them "owns no ref here". `:unknown` = the TaskQueue
  # could not be asked at all, which is not the same fact and must not wear its clothes.
  #
  # `function_exported?/3` returning false stays `{:ok, []}` and NOT `:unknown`: a task_queue module
  # without that function is a CAPABILITY of the module, decided at compile time and identical on
  # every tick — a test stub, never a runtime failure. Reading it as indeterminacy would make every
  # cycle `:error` under such a stub, i.e. a reconciliation that never reclaims anything.
  defp project_pod_owned_refs(pod_id, repo, tq) do
    with true <- String.starts_with?(pod_id, Fleet.PodId.scope_prefix(repo)),
         true <- Fleet.Opts.exported?(tq, :pod_active_issue_id, 1),
         {:ok, issue_id} when is_binary(issue_id) <- tq.pod_active_issue_id(pod_id),
         {:ok, n} <- Fleet.Pilot.IssueId.parse(issue_id) do
      {:ok, [{repo, :issue, n}]}
    else
      _ -> {:ok, []}
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # Does a pod have an ACTIVE task (owns its slot/lock)? The state of the pod's latest task (`pod_status`)
  # must be ACTIVE per the SINGLE AUTHORITY `WorkItem.active?/1` (`:pending`/`:assigned`).
  # `{:ok, nil}` (idle) and the TERMINAL states (`:completed`/`:failed`/`:cleared`) → `false`: a delivered
  # (`:completed`) pod no longer owns its lock (F-C050 — else a completion LOST before open_pr wedges the
  # lock forever). An anomaly is NEVER `false` here — it is `:unknown`.
  # THREE STATES, and folding any two of them costs a reap.
  #
  # `{:ok, nil}` and the terminal states mean the queue ANSWERED and the pod owns nothing: an
  # established idle, and the orphan this duty exists to collect. An `exit`/timeout means the queue
  # did not answer AT ALL — `pod_status/1` is a `GenServer.call` with no explicit timeout (5 s) to
  # a single server shared by every pod, so a restart or a load spike lands here. Folding both into
  # `false` would reap a possibly-WORKING pod for a hiccup that is not its own.
  #
  # Same rule as `Spawn.pipe_rebrief_state/2` (F-C059): *"aliveness UNKNOWN: fail-CLOSED -> DEFER,
  # NEVER :dead. Classing an uncertain pod dead -> reap of a maybe-LIVING pipe. A transient failure
  # self-corrects next tick; a persistent one defers visibly rather than acting destructively."*
  # One answer to one question in one domain; this is the side with the destructive path.
  #
  # Deferring costs a tick, and it does NOT mask an orphan: an established idle still reaps, and an
  # unreachable queue means the fleet has a bigger problem than one uncollected pod.
  @spec pod_task_state(module(), term()) :: :active | :idle | :unknown
  defp pod_task_state(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, state} -> if Fleet.TaskQueue.WorkItem.active?(state), do: :active, else: :idle
      # A seam that does not honour the `{:ok, _}` contract tells us nothing — not "idle".
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp pod_task_state(_tq, _), do: :unknown

  # Has the pod PULLED its latest task (state `:assigned`)? The PULL (`get_work_item`,
  # which transitions `:pending → :assigned` and records the in-band ACK) is the DURABLE proof that
  # the wake LANDED and the agent activated — the distinction the orphan-lock duty needs to tell a
  # PARKED admission (task enqueued but never pulled, `wake_unreached`) from a working pod. Stricter
  # than `pod_task_state/2` on ONE state: `:pending` is active (owns the slot at enqueue, anti
  # double-spawn) but NOT pulled (no activation proven). Terminal states (`:completed`/`:failed`/
  # `:cleared`) are not pulled either — same non-ownership as `pod_task_state/2` (F-C050). Used by
  # `live_owned_refs` (lock ownership); the quiesced-pod duty keeps `pod_task_state/2` so a
  # freshly-briefed `:pending` pod is re-dispatched (via the lock reclaim), never REAPED.
  # THREE ANSWERS, because there are three facts. `:pulled` / `:not_pulled` are both MEASURED; a
  # broker that cannot answer is `:unknown`, and `live_owned_refs/2` turns that into `:error` for the
  # whole cycle. A boolean would fold the third onto `false` — "this pod has not pulled" — which is
  # precisely the reading that makes a live pod's lock look orphaned during a TaskQueue restart.
  #
  # A non-binary pod_id stays `:not_pulled`: that is a malformed entry in the Spawner snapshot, a
  # measured fact about the pod, not an unavailable broker.
  defp pod_pull_state(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, state} -> if state in @pulled_states, do: :pulled, else: :not_pulled
      _ -> :not_pulled
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp pod_pull_state(_tq, _), do: :not_pulled

  # Lock refs that an INSTANCE pod owns, deduced from its pod_id. The FORMAT (`issue|pr` + number)
  # lives in `Fleet.PodId.parse_ref/2` (the authority that builds it); here we only SCOPE to the
  # current repo and dress the ref. Effect of the scope: a pod of ANOTHER repo yields `:error` (its slug
  # differs) -> it does not "own" a ref of `seams.repo` -> end of the cross-repo masking (#N/repoB
  # masking the orphan #N/repoA). The ref yielded CARRIES the repo (`{repo, :issue|:pr, n}`) = the complete key
  # (the real identity of the lock).
  defp parse_pod_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    case Fleet.PodId.parse_ref(pod_id, repo) do
      {:ok, {phase, n}} -> [{repo, phase, n}]
      :error -> []
    end
  end

  defp parse_pod_ref(_, _), do: []

  defp locked?(item) do
    @in_flight in Payload.label_names(item)
  end

  # What the reconciliation actually MEASURED about the orphan's pod — for the log, never the
  # decision (the reclaim itself is correct for BOTH causes: dead pod AND live-but-idle pod, the
  # deliberate parked-pod repair of the moduledoc). Asserting "pod dead without completion" here
  # would say it over pods that are demonstrably ALIVE — measured on the faceproof bench, the pipe
  # idling between two rework rounds while the log declares it dead every tick: a diagnosis the code
  # never made, quoted as one. Report what was measured, and when the enumeration itself fails, say
  # UNKNOWN rather than guess.
  defp lock_diagnosis(%Seams{repo: repo}, number, pods) do
    live_for_ref =
      pods
      |> Enum.filter(fn pod ->
        parse_pod_ref(pod[:pod_id], repo)
        |> Enum.any?(fn {_repo, _type, n} -> n == number end)
      end)

    case live_for_ref do
      [] -> "no live pod (dead/reaped)"
      _ -> "pod ALIVE but idle — no pulled task (parked wake, or completed without publish)"
    end
  rescue
    _ -> "pod state UNKNOWN (enumeration failed)"
  catch
    _, _ -> "pod state UNKNOWN (enumeration failed)"
  end

  defp reclaim_lock(%Seams{forge: forge, repo: repo, forge_opts: forge_opts}, number, diagnosis) do
    # "reclaiming", NOT "reclaimed": the announce precedes the WRITE (remove_label). A premature "reclaimed"
    # would over-report — on a forge-down the label survives and the lock is NOT actually released.
    Logger.warning(
      "Poller: reconciliation : lock #{@in_flight} ORPHAN on " <>
        "#{repo}##{number} (#{diagnosis}) → reclaiming (re-dispatch on next tick)"
    )

    # Stopwatch: stopped ALSO here (dead pod = never went through `unlock`) — otherwise it would run until
    # the next real unlock, counting the dead time as work. Result discarded (`_ =`): the stopwatch is
    # time-tracking, not a pipeline invariant — a failed stop costs attribution minutes, never the reclaim
    # (the remove_label below carries the real op and logs error on failure). Symmetric to the spawn —
    # BUT signed with RAW forge_opts (system), NOT `as_role`: the dead pod TOOK its role identity with it
    # (no usable trace at this point, orphan = no live pod left to query). Gitea requires
    # the SAME identity to stop as to start (per-user) → THIS stop will NOT match the stopwatch
    # started `as_role` by the dead pod (known limit, assumed: pod failure case, not the nominal path
    # — cf. `Fleet.Pilot.StepDispatcher.Spawn`/`StepRunCompleter.unlock` for the nominal attribution).
    _ = forge.stop_stopwatch(repo, number, forge_opts)

    # The label removal IS the reclaim: a failed remove_label means the lock is NOT released (the
    # announced reclaim did not take). The verdict is RETURNED (`:failed`) so the caller KEEPS the
    # ref in the suspect set — the retry genuinely happens next tick (already-confirmed orphan, no
    # fresh 2-tick re-suspicion), which is what this log promises.
    case forge.remove_label(repo, number, @in_flight, forge_opts) do
      {:error, reason} ->
        Logger.error(
          "Poller: reconciliation : reclaim of #{repo}##{number} FAILED — #{@in_flight} NOT removed " <>
            "(#{inspect(reason)}) — lock persists, kept suspect, retry next tick"
        )

        :failed

      _ ->
        :ok
    end
  end
end

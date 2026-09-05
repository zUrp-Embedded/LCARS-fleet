defmodule Fleet.Pilot.StepDispatcher.Spawn do
  @moduledoc """
  SINGLE-AUTHORITY spawn leaf of `Fleet.Pilot.StepDispatcher`.

  The dispatcher's TWO flows — issue (`dispatch_issue`, producer) AND PR (`do_dispatch_review`,
  judge/rework/resolution) — CONVERGE here: a single spawn point (`spawn_step/9`), a single
  pod identity (`pod_id_for_scope/4`), a single scope serialization (decision
  `project_scope_decision/4` + gate `gate_scope_decision/1` BEFORE the project resolver,
  action `maybe_reprovision/5` after).
  This module DECIDES nothing (route, role, verdict, budget stay in the `StepDispatcher` core): it
  EXECUTES the spawn sequence. There is only ONE copy of each — never an issue/review fork.
  (The gatekeeper EVAL dispatch is a DELIBERATE separate rail — completion-triggered, lockless,
  enqueue-before-spawn, fail-loud — NOT merged here; the shared atoms are already factored, only the
  operational contract differs. See `Fleet.Pilot.StepRunConsumer.GatekeeperEscalation` for the why.)
  (The opts builders / naming — `feature_slug`/`maybe_put_route`/`resolve_repo_id` —
  live in the Naming cluster at the bottom of this module, quasi-pure, called by both flows.)

  ## LOAD-BEARING semantics

  - **Canonical order** `lock → pod → enqueue → wake` (wake LAST). The label-lock
    `lcars-in-flight` is set BEFORE the pod, else double-spawn.
  - **Compensation**: if a POST-lock step fails, we remove the lock AND kill the pod
    ONLY if it was just spawned fresh (`alive_before? == false`) — a re-brief on a living pod
    NEVER kills the eng or its context.
  - **Return `{:error, {:wake_unreached, pod_id, role, reason}}`**: the pod IS started (lock +
    brief + pod in place), only the tmux wake failed. The POLLER reads this return to TAKE the lease
    (the object is in-flight) and count it in `errors` (honest tally, not a silent success). This
    return contract does NOT change.

  ## Boundary: explicit seams struct (not the whole `ctx`/`opts`)

  `spawn_step/9` reads only 6 seams of the dispatch. We do NOT pass the whole `ctx`/`opts` — that would be
  a boundary leak. Each caller (issue via `opts`, review via `ctx`) builds a `%Seams{}`
  (narrow, TYPED contract): `@enforce_keys` forces the 6 fields at the call, and an access
  `seams.<other_field>` does not compile (static KeyError) — a bare map would let
  `Map.get(seams, :loader)` pass silently.

  The helpers SHARED with the core stay PUBLIC here and are called by `StepDispatcher`:
  `safe_kill/2` (compensation in `spawn_step` AND die-on-promote in `promote_pr`).
  """

  require Logger

  # Protocol vocabulary = single source Fleet.Labels (compile-time constant, as in
  # StepDispatcher which keeps ITS @in_flight_label for `decide/1`/`dispatch_review` — same source,
  # not a fork).
  @in_flight_label Fleet.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Boundary contract of the spawn leaf: the 6 seams (and NOTHING else) that `spawn_step/9`
    reads. `@enforce_keys` forces the 6 fields at construction; an access `seams.<other_field>` does
    not compile — the cluster never receives the whole `ctx`/`opts` of the dispatch.
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Forge.Client`).
            forge: module(),
            # Injected spawner (seam `:spawner`, prod default `Fleet.Spawner`).
            spawner: module(),
            # Injected brief broker (seam `:task_queue`, prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # The repo's `owner/name` (the locked object lives there).
            repo: String.t(),
            # Forge opts (base_url/token…) passed to the ForgeClient.
            forge_opts: keyword(),
            # Injected wake recovery (seam `:wake_recovery`, default `&Fleet.Pilot.WakeRecovery.wake/3`).
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()})
          }
  end

  # ============================================================
  # Cluster H — spawn leaf (SINGLE-AUTHORITY)
  # ============================================================

  @doc """
  Spawn LEAF shared by dispatch_issue (producer) AND do_dispatch_review (judge/rework).
  CANONICAL ORDER: label-lock `lcars-in-flight` BEFORE pod (else double-spawn) → pod
  (`maybe_spawn`: RE-BRIEFS if alive) → enqueue of the brief (that the pod pulls via get_work_item) →
  wake+recovery. POST-lock failure → compensation: removal of the lock (+ kill IF fresh spawn,
  NEVER a living re-brief). `lock_target` = the locked object (issue number | PR number);
  `issue_number` = the issue number for the `issue_id` AND the enqueue; `log_ctx` = caller log context.
  """
  @spec spawn_step(
          Seams.t(),
          String.t(),
          String.t(),
          Fleet.CapProfile.t(),
          String.t(),
          keyword(),
          integer(),
          integer(),
          String.t()
        ) ::
          {:ok, {:spawned, String.t(), String.t()}}
          | {:skipped, :role_at_capacity}
          | {:error, term()}
  def spawn_step(
        %Seams{} = seams,
        pod_id,
        role,
        profile,
        brief,
        spawn_opts,
        lock_target,
        issue_number,
        log_ctx
      ) do
    %Seams{spawner: spawner} = seams

    issue_id = Fleet.Pilot.IssueId.compose(issue_number)
    alive_before? = pod_alive?(spawner, pod_id)

    # ⚠ PRE-VOL DE CAPACITE AVANT LE VERROU FORGE. Le mur qui refuse vraiment est DANS le spawn,
    # donc apres le verrou : y decouvrir un seau plein coute un cycle verrou/deverrou par ticket et
    # par tick en saturation, et compte « plein » comme une ERREUR — donc un backoff du poller comme
    # si la forge etait tombee. Differer est un SKIP, ce qui est la verite : plein, en attente.
    #
    # ⚠ IL INTERROGE LE MEME SEAU QUE CE MUR. Un pre-vol sur un autre seau est PIRE que pas de
    # pre-vol : il differe sur un plafond qui n'est pas celui qui refuse.
    #
    # Un seul plafond arrive ici, les places du pool. Le maximum global est un FUSIBLE, pas une
    # politique : rien ne le consulte pour decider, et le faire sauter est une anomalie bruyante.
    #
    # `not alive_before?` is load-bearing: re-briefing a LIVE pipe pod starts no child, so gating it
    # at saturation would starve the very pipe holding the seat.
    cond do
      not alive_before? and not has_free_slot?(spawner, role, profile, spawn_opts) ->
        Logger.info(
          "StepDispatcher: role bucket FULL (max_pods_per_role) → defer role=#{role} " <>
            "pod=#{pod_id} #{log_ctx} (no lock taken; re-dispatch when a seat frees)"
        )

        {:skipped, :role_at_capacity}

      true ->
        locked_spawn_step(
          seams,
          pod_id,
          role,
          profile,
          brief,
          spawn_opts,
          lock_target,
          {issue_id, issue_number},
          alive_before?,
          log_ctx
        )
    end
  end

  # The lock→spawn→enqueue→wake sequence + compensation, reached only past the pre-flight gates.
  defp locked_spawn_step(
         %Seams{repo: repo} = seams,
         pod_id,
         role,
         profile,
         brief,
         spawn_opts,
         lock_target,
         {issue_id, issue_number},
         alive_before?,
         log_ctx
       ) do
    # Brief PHYSIQUE : materialise UNE fois avant le spawn, le pointeur partant a la fois dans les
    # opts de spawn et dans l'enfilement.
    #
    # Le refus est GRATUIT ici : on tourne AVANT la pose du verrou, donc il n'y a rien a compenser —
    # le ticket n'est simplement pas dispatche ce tour-ci.
    # Human-named (`issue-<n>-<role>`), routed by EFFECTIVE kind (worker → briefs/, judge →
    # gate-briefs/ — resolved by BriefBuilder), and PUBLISHED best-effort (F-15: an unpushed
    # triplet is unauditable from the forge and non-durable — a push failure warns and never
    # blocks the dispatch). The kind STAYS in spawn_opts (BL-6-20 — popping it as "dispatch data"
    # is the mistake): judge-ness is resolved ONCE here at dispatch (step || profile, by
    # BriefBuilder) and the pod's payload ECHOES it (`CompletedPayload`), so the completion never
    # re-derives it from a card that may not declare it — the fail-open default this closes.
    brief_kind = Keyword.get(spawn_opts, :brief_kind, "worker")

    # `:ops_root` — SEAM of the ops root, the exact twin of `StepRunCompleter`'s and for the
    # same reason: the real root is a hardcoded global path, so without injecting it NO dispatcher
    # test can walk the materialized branch — the hermetic suite runs with the work_dir absent,
    # i.e. on the DEGRADED rail, and the nominal order delivery is then untested.
    ops_root = Keyword.get(spawn_opts, :ops_root)

    case materialize_order(brief, repo, issue_number, role, brief_kind, ops_root) do
      {:error, _} = refusal ->
        refusal

      {:ok, brief, extra_opts} ->
        # UNE SEULE LIVRAISON DE L'ORDRE, ET C'EST LE POINTEUR.
        #
        # `materialize_order/6` rebinde la VARIABLE `brief` (elle devient le pointeur) mais rend des
        # `extra_opts` qui ne portent que `brief_sha`/`brief_ref` : un `Keyword.merge` laisse donc
        # intacte la cle `:brief` posee par l'appelant, avec le TEXTE INTEGRAL. Ce texte finit dans
        # `~/issues/<id>.md` — et `maybe_spawn/…` ne respawne pas un pod vivant, donc la copie n'est
        # JAMAIS reecrite : sur un engineer qui traverse trois rounds de rework, le fichier porte
        # l'ordre d'origine pendant que le pointeur avance de sha en sha. Son contenu depend de la LIVENESS
        # du pod, pas de l'etat du ticket.
        #
        # ⚖ user : le dedoublonnage vaut sur les DEUX rails, pas seulement sur celui de la queue. On
        # retire donc la copie — mais SEULEMENT
        # quand une adresse la remplace : `Pod.Brief` est deja ecrit pour ce cas et NOMME le
        # pointeur (`brief_ref` + `brief_sha`, poses par ce meme dispatch). Sur le rail DEGRADE il
        # n'y a pas d'adresse a nommer, et il n'y a pas de derive non plus : rien n'avance a cote
        # du fichier. Retirer la copie la ne corrigerait rien et retirerait un artefact utile.
        spawn_opts =
          spawn_opts
          |> Keyword.merge(extra_opts)
          |> drop_duplicated_order(extra_opts)

        locked_spawn_step_run(
          seams,
          pod_id,
          role,
          profile,
          brief,
          spawn_opts,
          lock_target,
          {issue_id, issue_number},
          alive_before?,
          log_ctx
        )
    end
  end

  # ⚠ L'ORDRE EST MATERIALISE AVANT LE VERROU, ET UN ECHEC REFUSE LE DISPATCH — « la provenance
  # degrade, la livraison ne casse jamais » se lit comme de la prudence et fait l'inverse : le
  # pointeur EST la livraison des qu'un sha existe, donc degrader couvrait l'echec bon marche et
  # laissait sans filet le cher, celui ou le pod ne peut pas lire son ordre.
  #
  # La plupart des causes sont PERMANENTES — projet jamais onboarde, dispatch sans brief, sans
  # depot. Degrader dessus transforme un defaut d'installation en mode permanent SILENCIEUX : rien
  # n'echoue, le travail cesse simplement d'etre prouvable. Un brief n'est pas de l'instrumentation,
  # c'est l'ORDRE — le perdre, c'est ne plus pouvoir repondre « qu'a-t-on demande a ce pod ? » sur
  # un livrable parti en production.
  # La copie ne part que si une ADRESSE la remplace. `brief_ref` est le marqueur de la
  # materialisation : present, l'ordre est un objet git que le pod resout par son pointeur ; absent
  # (rail degrade), il n'y a rien vers quoi pointer.
  #
  # La question « ce qui reste est-il encore un ordre ? » se pose a `Fleet.Spawner.order_present?/1`
  # — l'AUTORITE PARTAGEE, celle que le spawn consultera juste apres. Ecrite ici en dur, elle
  # diverge de celle du garde : retirer la copie sur la presence du `ref` pendant que le garde ne
  # regarde que le TEXTE fait refuser au spawn tout pod one-shot dont le brief est materialise —
  # indefiniment, la reconciliation redispatchant toutes les 30 s. On interroge
  # donc le RESTE, pas ce qu'on retire : si la reponse est non, la copie ne part pas.
  defp drop_duplicated_order(spawn_opts, extra_opts) do
    without_copy = Keyword.delete(spawn_opts, :brief)

    if Keyword.has_key?(extra_opts, :brief_ref) and Fleet.Spawner.order_present?(without_copy),
      do: without_copy,
      else: spawn_opts
  end

  defp materialize_order(brief, repo, issue_number, role, brief_kind, ops_root) do
    materialize_opts =
      [name_hint: "issue-#{issue_number}-#{role}", kind: brief_kind, push: :ops]
      |> then(fn o -> if ops_root, do: Keyword.put(o, :ops_root, ops_root), else: o end)

    case Fleet.Workflow.BriefArtifact.materialize(brief, repo, materialize_opts) do
      {:ok, {ref, sha}} ->
        # LE CONTENU, PAS UN POINTEUR VERS UN ARBRE MONTE. `materialize/3` vient de commiter
        # EXACTEMENT `brief` a `sha` : le contenu pinne est celui qu'on tient deja, aucune relecture
        # git n'y ajoute quoi que ce soit. L'adresse voyage a cote (`brief_ref`/`brief_sha`) : le
        # RUNTIME la grave en provenance a la completion (`put_runtime_brief`), et un tiers rejoue
        # depuis la forge. Le pod ne la cite pas, et ne monte pas l'arbre ops : un pointeur vers
        # `$LCARS_PROJECT_OPS/<ref>` exigerait de monter l'arbre d'operations ENTIER — tous les
        # briefs, tous les verdicts — pour qu'il lise UN objet.
        {:ok, brief, [brief_sha: sha, brief_ref: ref]}

      # The only genuinely transient cause, and the only one that still degrades. But the ARTIFACT
      # says so: the order carries the fact that its version is unprovable (no ops sha the runtime
      # could engrave), instead of that fact living for one second in a log nobody re-reads. A
      # degraded mode visible only in real time is not a visible degraded mode.
      {:error, {:git, reason}} ->
        Logger.warning(
          "StepDispatcher: brief materialization failed transiently for #{repo}##{issue_number} " <>
            "(#{inspect(reason)}) — dispatching the INLINE order, marked unprovable"
        )

        {:ok, degraded_order(brief), []}

      # `{:work_dir_missing, _}` is governed by the SAME lever as the poller's admission gate
      # (`:require_onboarded`), not by a second one: both enforce the one policy "a project this
      # fleet serves exists on disk", at two depths. The hermetic test baseline turns it off
      # because the suite drives fictional repos — and there it degrades to the plain inline brief,
      # so a test asserting a dispatch is asserting a dispatch and not this gate. Two keys for one policy would diverge at the first change.
      {:error, {:work_dir_missing, _} = cause} ->
        if require_onboarded?() do
          refuse_order(repo, issue_number, role, cause)
        else
          {:ok, brief, []}
        end

      {:error, cause} ->
        refuse_order(repo, issue_number, role, cause)
    end
  end

  defp require_onboarded?, do: Application.get_env(:lcars_fleet, :pilot_require_onboarded, true)

  defp refuse_order(repo, issue_number, role, cause) do
    Logger.error(
      "StepDispatcher: REFUSING to dispatch #{repo}##{issue_number} role=#{role} — the order " <>
        "cannot be materialized (#{inspect(cause)}), and the cause is PERMANENT. Dispatching " <>
        "would produce work nobody can prove was asked for."
    )

    {:error, {:order_not_materialized, cause}}
  end

  # Emitted payload → French with its accents (operator/agent-facing data, cf. CLAUDE.md).
  defp degraded_order(brief) do
    "⚠ PROVENANCE ABSENTE — cet ordre n'a pas pu être commité dans le ops du projet (panne " <>
      "transitoire). Le runtime n'a donc pas de sha à graver : ce livrable ne portera pas " <>
      "d'adresse d'ordre auditable. Tu n'as rien à faire de plus — livre normalement.\n\n" <>
      brief
  end

  # `%Seams{}` all the way down — the armored boundary is only as deep as the last struct: a
  # positional tuple here would have no key and no `@enforce_keys` to refuse a typo.
  defp locked_spawn_step_run(
         %Seams{
           forge: forge,
           spawner: spawner,
           task_queue: task_queue,
           repo: repo,
           forge_opts: forge_opts,
           wake_recovery: wake_recovery
         },
         pod_id,
         role,
         profile,
         brief,
         spawn_opts,
         lock_target,
         {issue_id, issue_number},
         alive_before?,
         log_ctx
       ) do
    with {:ok, _} <- forge.add_label(repo, lock_target, @in_flight_label, forge_opts),
         _ = start_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role),
         {:ok, _} <- maybe_spawn(spawner, alive_before?, profile, issue_id, spawn_opts),
         :ok <- enqueue_brief(task_queue, pod_id, role, issue_id, issue_number, brief, spawn_opts) do
      # The return of `WakeRecovery.wake` is LOAD-BEARING: `{:error, {:escalated, _}}`
      # (pod unreachable, escalated to starfleet) or `{:error, _}` (re-wake failed) means the pod is
      # NOT woken. Discarding this return (`_ = wake(...)`) would always make `spawn_step` return
      # `{:ok, {:spawned}}` → the poller would count `dispatched +1 / errors 0` LYING (pod never woken,
      # but a clean tally). So we MATCH it: the lock + the brief + the pod STAY in place (the
      # brief is enqueued, the system escalation exists → not a dead-end, re-wake at the next tick), but
      # the dispatch is NOT a silent success — it surfaces `{:error, {:wake_unreached, …}}` → the poller
      # counts it in `errors` (honest tally + err_streak/telemetry reflect the real unreachability).
      case wake_recovery.(
             pod_id,
             fn -> maybe_spawn(spawner, false, profile, issue_id, spawn_opts) end,
             wake_fun: fn p -> safe_wake(spawner, p) end
           ) do
        :ok ->
          Logger.info(
            "StepDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx}"
          )

          {:ok, {:spawned, pod_id, role}}

        {:error, reason} ->
          # AUCUNE compensation : verrou garde — le pod EST dispatche, l'objet EST en vol — brief
          # garde, pod garde. Seul le reveil a rate.
          #
          # ⚠ ET LA REPRISE NE VIENT PAS D'UN RE-WAKE : le dispatcher ne repasse pas tant que
          # `lcars-in-flight` est pose, et aucun site de wake n'est periodique. Elle vient de la
          # RECLAMATION D'ORPHELIN du poller, dont la regle de propriete est `@pulled_states` : un
          # brief enfile mais jamais TIRE ne possede pas son verrou, le pull etant l'ACK durable que
          # le reveil a atterri. Le verrou devient donc suspect, la grace court, il est reclame, et
          # le dispatch peut reprendre.
          #
          # La nuance explique le DELAI — une grace, pas un tick — et dit ou regarder quand ca ne
          # repart pas.
          Logger.warning(
            "StepDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx} " <>
              "BUT wake UNREACHABLE → #{inspect(reason)} (lock+brief kept, re-wake on next tick ; " <>
              "tally = error, not silently dispatched)"
          )

          {:error, {:wake_unreached, pod_id, role, reason}}
      end
    else
      {:error, _} = err ->
        # A POST-lock step failed → compensation (removal of the lock, else stuck forever).
        # Kill ONLY if fresh spawn (a re-brief NEVER kills the living eng + its context).
        #
        # `_ =` EXPLICITE : depuis JG-120, `safe_kill/2` rend un verdict classe, donc l'ignorer est
        # un CHOIX. Il est ASSUME ici — la compensation qui compte est le retrait du VERROU, juste
        # en dessous, et son verdict est capture (CI-10). Un pod qui survit a son kill de
        # compensation est ramasse par la reconciliation du poller au tick suivant ; un verrou qui
        # survit, lui, bloque la brique pour toujours. Les deux echecs n'ont pas le meme poids, et
        # c'est pour ca qu'un seul est propage.
        _ = if not alive_before?, do: safe_kill(spawner, pod_id)

        # CI-10: the compensation's OWN verdict. A discarded `remove_label` return plus a flat
        # "lock removed" log LIES when the removal fails — the issue stays in-flight while the
        # message claims the opposite. Capture it and log the FACT. A failed removal is
        # auto-repairable (unlike a teardown that erases its proof, CI-05): the Poller reconciliation
        # reclaims the orphan lock in ≤2 ticks — but we name the real cause instead of absorbing the
        # recovery time under a false success.
        lock_state =
          case forge.remove_label(repo, lock_target, @in_flight_label, forge_opts) do
            {:ok, _} ->
              "lock removed"

            other ->
              "lock removal FAILED (#{inspect(other)}) — issue stays lcars-in-flight, " <>
                "Poller reconciliation reclaims (≤2 ticks)"
          end

        # Stopwatch started with the lock → stopped with it (the dispatch never succeeded, the elapsed
        # time would be noise, not real work).
        _ = stop_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role)

        Logger.warning(
          "StepDispatcher: dispatch role=#{role} pod=#{pod_id} #{log_ctx} → #{inspect(err)} " <>
            "(#{lock_state}#{if(alive_before?, do: "", else: ", pod killed")} — re-dispatch on next tick)"
        )

        compensated_verdict(err)
    end
  end

  # THE FORGE STOPWATCH, SIGNED AS THE WORKER — one home for the rule the two gestures share.
  # A pure Gitea metric, never load-bearing: a start that fails is not surfaced (the time is simply
  # not tracked for this run), and the `with` above reads `_ =` on purpose.
  #
  # ⚠ SIGNE AU NOM DU TRAVAILLEUR, pas du systeme comme le label : la forge attribue le temps a
  # l'utilisateur AUTHENTIFIE, donc un chronometre systeme compterait tout sous le compte systeme.
  # Et elle exige la MEME identite au demarrage ET a l'arret — le stop porte donc le meme role.
  #
  # Un role qui ne DECLARE aucune identite de forge n'est pas un trou de provisioning : ses
  # ecritures passent par le systeme par design, donc il n'y a rien a tenter ni a signaler. A role
  # whose token is MISSING is one (the four-list class), and its only forge-visible symptom is
  # « the worker never shows up on the ticket » — so it is said, once, at the start.
  defp start_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role) do
    case forge_identity_or_none(profile, forge_opts, role) do
      {:ok, ro} ->
        forge.start_stopwatch(repo, lock_target, ro)

      :no_identity ->
        :ok

      {:error, :role_token_unavailable} ->
        Logger.warning(
          "StepDispatcher: no forge token for role #{inspect(role)} — stopwatch NOT " <>
            "started on #{repo}##{lock_target} (the ticket will not show the worker " <>
            "arriving; check the role account/token provisioning)"
        )
    end
  end

  # Same identity as the start — Gitea accepts the stop ONLY from the user who started it.
  defp stop_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role) do
    with {:ok, ro} <- forge_identity_or_none(profile, forge_opts, role) do
      forge.stop_stopwatch(repo, lock_target, ro)
    end
  end

  # ⚠ LA SATURATION ATTEINTE AU MUR EST LA MEME VERITE QUE CELLE ATTRAPEE AU PRE-VOL — « plein, en
  # attente » — et la compensation vient de tout defaire, donc rien n'a demarre. La rendre en erreur
  # ferait diverger les deux chemins sur un seul fait : le TOCTOU residuel, la derniere place prise
  # entre le controle et le spawn, produirait un ticket silencieusement non dispatche et compte
  # comme un echec.
  #
  # SEULE cette raison convertit. Tout autre echec post-verrou reste une erreur : c'en est une.
  defp compensated_verdict({:error, :role_at_capacity}), do: {:skipped, :role_at_capacity}
  defp compensated_verdict(err), do: err

  defp maybe_spawn(_spawner, true = _alive?, _profile, _issue_id, _spawn_opts),
    do: {:ok, :rebriefed}

  defp maybe_spawn(spawner, false = _alive?, profile, issue_id, spawn_opts) do
    case spawner.spawn_pod(profile, issue_id, spawn_opts) do
      {:ok, _pid} -> {:ok, :spawned}
      {:error, _} = err -> err
    end
  end

  defp disposition(true = _alive_before?), do: "re-briefed (pod alive, context kept)"
  defp disposition(false = _alive_before?), do: "spawned"

  # Enqueues the brief in the `Fleet.TaskQueue` broker targeted at pod_id — the claude REPL pulls it via
  # `mcp__fleet__get_work_item` → `PodTools.get_work_item` → `TaskQueue.get_for_pod` (NOT a file Read).
  # Without this enqueue, `TaskQueue.pod_status(pod_id) == nil` → the pod thinks it is bootstrap
  # (nothing to pull) → idle.
  # The `brief` = the role-aware BRIEF already built (build_brief): disarmed GateBrief for the
  # gatekeeper, issue body for a worker. A raw `issue["body"]` would make
  # the judge pull the executable BUILD brief. `metadata.issue` correlates to the issue.
  defp enqueue_brief(task_queue, pod_id, role, issue_id, number, payload, spawn_opts) do
    # `payload` is ALREADY the final order — the pointer when the brief was materialized, the
    # marked inline text on the one transient degradation. It is decided at `materialize_order/5`
    # and not re-derived here: rebuilding it from `{brief_ref, brief_sha}` would let two places
    # disagree about what the pod receives. The pointer/inline arbitration lives at ONE site
    # (⚖ user — no inline-blob and pointer cohabiting).
    attrs = %{
      issue_id: issue_id,
      role: role,
      brief: payload,
      brief_ref: Keyword.get(spawn_opts, :brief_ref),
      brief_sha: Keyword.get(spawn_opts, :brief_sha),
      metadata: %{"issue" => number}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp safe_wake(spawner, pod_id) do
    if function_exported?(spawner, :wake_pod, 1), do: spawner.wake_pod(pod_id), else: :ok
  rescue
    e ->
      # A RAISE from wake_pod is NOT a successful wake — returning `:ok` would report a woken pod that never
      # woke (false `dispatched` tally, silent). Surface it as `{:error}` so WakeRecovery re-rolls/escalates.
      Logger.warning(
        "StepDispatcher: safe_wake — wake_pod RAISED for #{inspect(pod_id)} (#{inspect(e)}) → {:error}"
      )

      {:error, {:wake_raised, pod_id}}
  end

  @doc """
  Compensation kill: kills the pod (if it spawned) before removing the lock.
  Silent no-op if the spawner does not expose `kill_pod/1` (test stubs) or if the pod does not
  exist; a raise is swallowed (`:ok`). A kill that genuinely fails is NOT retried here — what
  catches it: on the compensation path the lock is removed, so the next tick re-dispatches and the
  still-alive pod is RE-BRIEFED (idempotent dispatch, `pod_alive?` path); on die-on-promote the
  `one-shot` producer ends itself at end-of-run; orphaned pod substrate (tmux socket without its
  Pod process) is swept by Spawner's PodWarden.

  PUBLIC because shared with the core: `spawn_step/9` (compensation) AND `ReviewLifecycle.promote_pr`
  (die-on-promote of the eng). One copy, no fork.
  """
  # LE SILENCE RESTE, LE FAIT N'EST PAS FABRIQUE. Cette fonction avale toujours l'echec — c'est
  # l'arbitrage, ecrit chez ses trois appelants : un kill rate ne bloque rien, le tick suivant
  # re-suspecte et retente. Mais un `:ok` unique pour QUATRE situations differentes — kill reussi,
  # pod deja absent, `kill_pod/1` non exporte (doublure de test), exception — interdit a l'appelant
  # de dire ce qui s'est passe, et l'un d'eux annoncerait « reaped » sur cette base (JG-120).
  #
  # Le retour est donc CLASSE : les trois sites l'ignorent, personne ne branche dessus, mais un
  # `@spec … :: any()` dirait qu'il n'est pas defini — et ce qui n'est pas defini ne peut pas etre
  # lu le jour ou quelqu'un le veut.
  @spec safe_kill(module(), String.t()) :: :ok | :unsupported | {:error, term()}
  def safe_kill(spawner, pod_id) do
    if function_exported?(spawner, :kill_pod, 1) do
      case spawner.kill_pod(pod_id) do
        :ok -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_kill_result, other}}
      end
    else
      :unsupported
    end
  rescue
    e -> {:error, {:kill_raised, Exception.message(e)}}
  end

  # `as_role`, unless the role DECLARES it has no forge identity — in which case there is nothing to
  # resolve and no anomaly to report. Same shape as the predicate it wraps; `:no_identity` is a
  # third answer, not an error, so a caller cannot fold it into the failure branch by accident.
  defp forge_identity_or_none(profile, forge_opts, role) do
    if Fleet.CapProfile.forge_identity?(profile) do
      Fleet.Forge.Client.as_role(forge_opts, role)
    else
      :no_identity
    end
  end

  # Capacity pre-flight. Default-ALLOW when the seam does not expose the predicate (test stubs — mirror of
  # safe_wake/pod_alive?) and fail-OPEN on raise: this gate is an admission OPTIMIZATION, and
  # `PoolSlot.allocate/3` is still the wall. A broken capacity check must never STARVE the dispatch
  # (a wrong "full" would freeze the fleet); a wrong "room" at worst pays one lock/unlock cycle.
  # The `slot_scope` comes from the cap-profile via its single accessor — a second derivation of
  # "is this role project-keyed" is how a pre-flight ends up asking a bucket nobody enforces.
  defp has_free_slot?(spawner, role, profile, spawn_opts) do
    not function_exported?(spawner, :has_free_slot?, 3) or
      spawner.has_free_slot?(
        role,
        Keyword.get(spawn_opts, :repo_id),
        Fleet.CapProfile.slot_scope(profile)
      )
  rescue
    e ->
      Logger.warning(
        "StepDispatcher: has_free_slot? RAISED (#{inspect(e)}) → assume a seat " <>
          "(fail-open; PoolSlot.allocate/3 still enforces)"
      )

      true
  end

  # Idempotent dispatch. An already-ALIVE pod (stable deterministic id) = the long-lived pipe eng
  # → we RE-BRIEF it (enqueue + wake, keeps its context), no re-spawn (no leak, no orphan).
  # `pod_alive?` defaults to `false` if the spawner does not expose `pod_info/1` (test stubs) → spawn
  # path unchanged.
  defp pod_alive?(spawner, pod_id) do
    function_exported?(spawner, :pod_info, 1) and
      case spawner.pod_info(pod_id) do
        {:ok, _} -> true
        # UNREACHABLE (info call timed out): may be ALIVE and slow — same fail-closed
        # posture as the RAISE below (assume alive; a wrong "alive" wastes a rebrief,
        # a wrong "dead" double-spawns then reaps the living eng).
        {:error, :unreachable} -> true
        {:error, _} -> false
      end
  rescue
    e ->
      # A RAISE from pod_info leaves aliveness UNKNOWN. Defaulting to `false` (dead) is UNSAFE: a live pod
      # classed dead → double-spawn on the deterministic pod_id AND `safe_kill` of the LIVING eng + its
      # context. Fail-CLOSED → assume ALIVE (no destructive action; a wrong "alive" at worst wastes a rebrief).
      Logger.warning(
        "StepDispatcher: pod_alive? — pod_info RAISED for #{inspect(pod_id)} (#{inspect(e)}) → assume ALIVE (fail-closed)"
      )

      true
  end

  # ============================================================
  # Cluster I — pod identity + scope serialization (SINGLE-AUTHORITY)
  # ============================================================

  @doc """
  Pod identity granularity, derived from the catalogue (`slot_scope` of the cap-profile, single source):
    "instance" → keyed on ISSUE (`for_issue`): fan-out, a distinct id per issue/PR (ephemeral judges).
    "project"  → keyed on REPO alone (`for_repo`): ONE identity per (repo, role) → a stable Desktop slot.
  Total over the slot_scope enum (the `Fleet.CapProfile.slot_scope/1` accessor guarantees project|instance).
  """
  @spec pod_id_for_scope(String.t(), String.t(), integer(), String.t()) :: String.t()
  def pod_id_for_scope("project", repo, _number, role),
    do: Fleet.PodId.for_repo(repo, role)

  def pod_id_for_scope("instance", repo, number, role),
    do: Fleet.PodId.for_issue(repo, number, role)

  @doc """
  Scope-serialization DECISION (split from the reprovision ACTION so the call sites
  can gate BEFORE the network project resolver — otherwise a `:role_busy` tick re-pays 1-2×
  `git ls-remote` (~15-30s) just to throw the result away and, under a slow forge, stalls
  the whole sequential poll tick).

  ONE identity (repo, role) alive at a time (1 Desktop slot), keyed on the SINGLE worker axis
  `lifetime_scope` (`role_busy` derives from the ROOT axis "context-long vs one-shot",
  never from the derived `slot_scope` — a mimicking second property):
    one-shot (fan-out)    -> `:proceed` (never gated: distinct ids per issue, cold + independent).
    context-long (pipe/…) -> RESIDENT (repo,role) process, per its state (pipe_rebrief_state):
                               dead  -> `:proceed` (fresh spawn, 1st issue);
                               busy  -> `:role_busy` (still working a task OR publishing its last
                                        deliverable: resetting its workspace now would corrupt it /
                                        race the push);
                               ready -> `:ready_needs_reprovision` — the ACTION (cold in-place reset,
                                        needs the resolved `project["base_sha"]`) runs AFTER the
                                        resolver via `maybe_reprovision/5`, on the passing path only.
  There is NO `project one-shot` branch: a cold pod serialized per project is a contradiction
  (one-shot ⟹ instance ⟹ fan-out) — no role matches it (cf. `CapProfile.slot_scope/1`).

  Requires NO project (pure liveness/slot reads) — that is the point of the split. The decision→
  action gap spans the resolver call (~15s worst case); the single sequential dispatcher per
  poller keeps the same (repo, role) from racing itself, and the downstream gates/compensation
  still hold if the pipe state moved meanwhile.

  `slot_scope` is REQUIRED, with no default. It carries the whole difference between re-briefing a
  pod in place and wiping its context, so a caller that omits it is a caller that has not decided —
  and a default would answer for them, silently, on the side that reintroduces the `/clear`. The
  compiler asking the question is the cheapest possible wall; the alternative is a new call site
  inheriting the old semantics with nothing to see in review.
  """
  @spec project_scope_decision(String.t(), module(), String.t(), String.t()) ::
          :proceed | :role_busy | :ready_needs_reprovision
  def project_scope_decision("one-shot", _spawner, _pod_id, _slot), do: :proceed

  # TICKET-LIVE — a context-long producer keyed on the ISSUE.
  # `:ready` does NOT mean the same thing under the two keyings, and reading it as one thing is the
  # defect: under `project` the pod is shared, so `:ready` = "free for ANOTHER subject" and the
  # workspace reset + `/clear` are the price of the switch. Under `instance` the pod belongs to ONE
  # ticket, so `:ready` = "MY ticket is coming back" (rework after REQUEST_CHANGES) — and clearing
  # there destroys exactly what makes the rework cheap: what the producer built and why. Measured
  # in production: a deliverable came back to the engineer WITH a `/clear`, and it re-read
  # everything cold while the reviews faulted decisions it no longer remembered making.
  # So: re-brief in place, no reset, no `/clear`. The context is an asset of the ticket and lives
  # until the merge.
  def project_scope_decision(_context_long, spawner, pod_id, "instance") do
    case pipe_rebrief_state(spawner, pod_id) do
      :busy -> :role_busy
      _dead_or_ready -> :proceed
    end
  end

  def project_scope_decision(_context_long, spawner, pod_id, _project) do
    case pipe_rebrief_state(spawner, pod_id) do
      :dead -> :proceed
      :busy -> :role_busy
      :ready -> :ready_needs_reprovision
    end
  end

  @doc """
  `with`-friendly gate on the decision: `:role_busy` → `{:skipped, :role_busy}` (surfaces to the
  poller, retry next tick), anything else → `:ok`. Placed BEFORE the project resolver at both
  call sites (dispatch_issue + RoleDispatch — SAME rule, lockstep).
  """
  @spec gate_scope_decision(:proceed | :role_busy | :ready_needs_reprovision) ::
          :ok | {:skipped, :role_busy}
  def gate_scope_decision(:role_busy), do: {:skipped, :role_busy}
  def gate_scope_decision(_proceed_or_reprovision), do: :ok

  @doc """
  The reprovision ACTION, on the passing path (project resolved): `:ready_needs_reprovision` →
  cold in-place workspace reset for the new brief + /clear (`spawn_step` then re-briefs on a
  clean workspace). The reset base = `project["base_sha"]`: new issue -> main tip (fresh);
  rework -> tip of the PR (continues the eng's work). Other decisions → no-op `:ok`.
  """
  @spec maybe_reprovision(
          :proceed | :ready_needs_reprovision,
          module(),
          String.t(),
          map() | nil,
          String.t()
        ) :: :ok | {:skipped, :role_busy}
  def maybe_reprovision(:ready_needs_reprovision, spawner, pod_id, project, slug),
    do: reprovision_then_proceed(spawner, pod_id, project, slug)

  def maybe_reprovision(:proceed, _spawner, _pod_id, _project, _slug), do: :ok

  # State of a project-scoped pipe facing a NEW brief. :ready = idle (no active task) AND :publishing absent.
  # Resetting the workspace is safe ONLY under the premise "the push already read the workspace, the agent writes
  # no more" — and that premise covers just ONE of the two paths that clear :publishing: (a) `deliverable.published`
  # confirmed → holds; (b) the `:publish_deadline` fail-safe cleared the flag WITHOUT that confirmation → does NOT
  # hold (see Pod's reprovision/deadline handler). pod_info exposes conditions + has_active_task (the pod knows both).
  defp pipe_rebrief_state(spawner, pod_id) do
    case safe_pod_info(spawner, pod_id) do
      {:ok, %{conditions: conds, has_active_task: active}} ->
        cond do
          active -> :busy
          :publishing in conds -> :busy
          true -> :ready
        end

      # pod_info without has_active_task (partial stub): conservative -> :busy (a living pipe of unknown
      # state is NOT reset, just deferred).
      {:ok, _partial} ->
        :busy

      # F-C059 — aliveness UNKNOWN (pod_info RAISED or UNREACHABLE): fail-CLOSED -> :busy (DEFER), NEVER
      # :dead. Classing an uncertain pod dead -> serialize `:ok` -> fresh spawn on the deterministic id ->
      # reap/`safe_kill` of a maybe-LIVING pipe eng + its context (the exact destructive path `pod_alive?`
      # guards with "assume ALIVE"). A transient failure self-corrects next tick; a persistent one defers
      # visibly rather than acting destructively. The spawner's pod_info contract keeps the three states
      # distinct (absent / alive / unreachable) — `:unreachable` (a live-but-slow pod whose info call
      # timed out) maps HERE to :unknown, never to :dead.
      :unknown ->
        :busy

      # Genuinely absent / a reachable `{:error}` from pod_info -> dead -> fresh spawn (1st issue).
      :error ->
        :dead
    end
  end

  defp safe_pod_info(spawner, pod_id) do
    if function_exported?(spawner, :pod_info, 1) do
      case spawner.pod_info(pod_id) do
        {:ok, info} -> {:ok, info}
        {:error, :unreachable} -> :unknown
        _ -> :error
      end
    else
      :error
    end
  rescue
    e ->
      # A RAISE from pod_info leaves the pod state UNKNOWN — distinct from a reachable `{:error}` (absent).
      # We return `:unknown` (NOT `:error`): `pipe_rebrief_state` DEFERS on unknown (fail-closed), never
      # cold-resets/kills a maybe-LIVING pipe. Surfaced. (Mirror of `pod_alive?`'s "assume ALIVE" on raise.)
      Logger.warning(
        "StepDispatcher: safe_pod_info — pod_info RAISED for #{inspect(pod_id)} (#{inspect(e)}) → :unknown (fail-closed defer)"
      )

      :unknown
  end

  # COLD in-place reset of the workspace + /clear BEFORE the rebrief, then :ok (proceed). Reset failed -> DEFERRED
  # (retry at the next tick). No project (legacy) or spawner without the fn (stub) -> :ok without reset
  # (honest degrade: we do not block, but without the cold guarantee of this round).
  @doc """
  A0.5 — on a CONFLICT rework, the base has moved by definition; a live instance-scoped pod is
  re-briefed in place (`:proceed`, context kept) and its `refs/lcars/base` must
  follow anyway. `:ready_needs_reprovision` already re-pins inside the cold reset (6-135);
  `:proceed` on a DEAD pod pins at clone; only `:proceed` on a LIVE pod carries the hole —
  measured on the bench: two rework rounds merging a stale base ("Already up to
  date"), a burned budget, and an arch escalated over a conflict the pod was never shown.

  Fail direction: a live pod whose refresh FAILS is NOT briefed (skip → retry next tick) —
  briefing it would replay the measured failure, one round of budget per tick, politely.
  """
  @spec refresh_conflict_base(
          :proceed | :ready_needs_reprovision,
          module(),
          String.t(),
          map() | nil
        ) :: :ok | {:skipped, :stale_base_unrefreshed}
  def refresh_conflict_base(:ready_needs_reprovision, _spawner, _pod_id, _project), do: :ok

  def refresh_conflict_base(:proceed, spawner, pod_id, project) do
    if is_map(project) and function_exported?(spawner, :refresh_work_base, 2) do
      case spawner.refresh_work_base(pod_id, project) do
        :ok -> :ok
        # Not registered = fresh spawn ahead: it pins its own base at clone.
        {:error, :not_found} -> :ok
        {:error, _} -> {:skipped, :stale_base_unrefreshed}
      end
    else
      :ok
    end
  end

  defp reprovision_then_proceed(spawner, pod_id, project, slug) do
    if is_map(project) and function_exported?(spawner, :reprovision_pipe_workspace, 3) do
      case spawner.reprovision_pipe_workspace(pod_id, project, slug: slug) do
        :ok -> :ok
        {:error, _} -> {:skipped, :role_busy}
      end
    else
      :ok
    end
  end

  # ── Naming — everything that NAMES/RESOLVES an identity embedded in the spawn_opts:
  # feature_slug, maybe_put_route, resolve_repo_id. Quasi-pure, shared by the
  # TWO dispatcher flows — the leaf keeps the spawn MECHANIC, this cluster keeps the NAMES.
  # (The human-facing pod label is NOT here: it is `Fleet.Layout.pod_label/3`, foundation, because
  # the spawner-side producers — recall, architect — must reach the same single builder.) ──

  @doc """
  Speaking slug from the issue title for the LOCAL branch (`feature/<slug>`).
  Sanitized + truncated; empty → `work`. No pod_id/human leak.
  """
  @spec feature_slug(map()) :: String.t()
  def feature_slug(issue) do
    (issue["title"] || "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "work"
      s -> s
    end
  end

  # (The conditional puts of ONE key — `:project`, `:repo_id` — go through the single source
  # `Fleet.Opts.maybe_put/3` at the call sites: no fixed-key wrapper here. Only
  # `maybe_put_route/2` lives here — it puts TWO coupled keys, which is not the maybe_put idiom.)

  @doc "Puts `:workflow_map`/`:step` into the spawn_opts if the route is present (nil = no-op)."
  @spec maybe_put_route(keyword(), {String.t(), String.t()} | nil) :: keyword()
  def maybe_put_route(spawn_opts, nil), do: spawn_opts

  def maybe_put_route(spawn_opts, {workflow_map_name, step}),
    do: spawn_opts |> Keyword.put(:workflow_map, workflow_map_name) |> Keyword.put(:step, step)

  @doc """
  Resolves the forge `repo_id` (the RAW forge id) — the project's forge id makes the deterministic
  session_id of project-bound roles (eng, judges) via `Fleet.Spawner.SessionId` (DECIMAL `<REPO4>`
  segment). Forge without `repo_id/2` (stub) / forge down / absent id → `nil` (no `:repo_id` put —
  `Opts.maybe_put` swallows the nil at the call site). A project-bound role spawned WITHOUT a repo is
  then an ANOMALY: the mint (`Fleet.Spawner.Pod.SessionMint`) FAILS-LOUD (raises) — we NEVER fabricate a
  random UUID to mask an unresolved forge (forge = organ of LCARS, forge down = stop).

  DR-020: the `<REPO4>` bound (0..9999) is enforced at the MINT, LOUD — a forge id > 9999
  is REFUSED, NEVER folded by `rem(id, 10_000)`. A silent modulo would be a HIDDEN collision: repo 10000
  and repo 0 would encode the SAME deterministic identity, handing two projects one JSONL-recall / Desktop
  slot / reconstructible id. We pass the raw id through and let the mint refuse an out-of-format id
  explicitly (widening `<REPO4>` = a SessionId FORMAT redesign, deferred) rather than corrupt identity.
  """
  @spec resolve_repo_id(module(), String.t(), keyword()) :: non_neg_integer() | nil
  def resolve_repo_id(forge, repo, forge_opts) do
    case Fleet.Forge.repo_id(forge, repo, forge_opts) do
      {:ok, id} -> id
      {:error, _reason} -> nil
    end
  end

  @doc """
  Reads the engraved route (`{workflow_map, step}` | nil) — wrapper of `forge.get_route` shared
  by BOTH flows (issue via resolve_route, review via RoleDispatch/Remediation). Same
  single-authority rule as the rest of this module — never a per-flow capture.
  """
  @spec route_for(module(), String.t(), integer(), keyword()) ::
          {:ok, {String.t(), String.t()} | nil} | {:error, term()}
  def route_for(forge, repo, number, forge_opts) do
    case forge.get_route(repo, number, forge_opts) do
      {:ok, {_p, _s} = route} -> {:ok, route}
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Fleet.Pilot.IncidentRegistry.Escalation do
  @moduledoc """
  SYSADMIN escalation of an incident (opening an `error_system` forge issue), extracted
  from `Fleet.Pilot.IncidentRegistry`: the registry is the MEMORY (GenServer, WAL + forge
  sync); the escalation is a STATELESS act (no read of the GenServer — everything comes
  from the arguments + config) that builds and posts the issue. Two concerns, two modules.

  Shared by `WakeRecovery` and the failure consumers via the facade
  `IncidentRegistry.escalate/5` (DRY — a single writer of the sysadmin issue).

  ## Contract

    * Label `error_system` = DURABLE signal (the poller/human finds the issue by it); added with a
      BOUNDED retry. A PERSISTENT label failure (F-C075) → `{:error, {:discovery_label_failed, num, _}}`
      → `record_or_escalate` renders `{:escalation_failed, _}` (never a lying `{:escalated}` for an
      unfindable incident). The sysadmin assignee is a SECONDARY discovery path (account absent →
      retry WITHOUT assignee: escalation takes precedence over naming; the durable path is the
      label, and a missing assignee is visible on the issue itself).
    * Forge down (create) → `{:error, _}` propagated (`record_or_escalate` renders it as
      `{:escalation_failed, _}`, never a lying `{:escalated}`).
    * `kind` qualifies the MESSAGE (recurrence / failed re-roll / recurrent pod /
      SP suspect / Cat-5 max severity) — the diagnosis guides the sysadmin toward the root-cause.

  **Last revised**: 2026-07-21
  """

  require Logger

  @doc """
  Opens a system issue (default label `error_system` — `opts[:label]` overrides, e.g. `error_cat5`;
  assignee `starfleet`=sysadmin) for an incident. `kind`: `:recurrence` | `:reroll_failed` |
  `:pod_failed` | `:sp_suspect` | `:cat5`. The label is a DURABLE discovery signal (always set,
  bounded retry); the assignee is not load-bearing — if the account does not exist the issue is
  retried WITHOUT assignee (the escalation itself must land; naming is secondary and its absence
  is visible on the issue). `opts[:correlation_id]` engraves the incident↔mandate link in the body;
  `opts[:reason_detail]` engraves the full failure term (producers put the stable dedup CATEGORY in
  `reason` and the variable detail aside — see `Fleet.Event.reason_fields/1`).
  Returns `{:ok, number}` | `{:error, term}`.
  """
  @spec escalate(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def escalate(kind, subject, reason, sig, opts \\ []) do
    create_fun = Keyword.get(opts, :create_issue_fun, &Fleet.Pilot.ForgeClient.create_issue/4)
    add_label_fun = Keyword.get(opts, :add_label_fun, &Fleet.Pilot.ForgeClient.add_label/4)
    list_fun = Keyword.get(opts, :list_issues_fun, &Fleet.Pilot.ForgeClient.list_open_issues/2)
    repo = opts[:repo] || Application.get_env(:fleet_pilot, :system_issue_repo) || ops_repo()

    label =
      opts[:label] || Application.get_env(:fleet_pilot, :system_issue_label, "error_system")

    assignee =
      opts[:assignee] || Application.get_env(:fleet_pilot, :system_issue_assignee, "starfleet")

    {kind_label, kind_note} = kind_describe(kind)
    title = "[#{label}] #{kind_label} : #{subject}"

    # STABLE machine key of THIS incident occurrence, hidden in the body. create_issue is not
    # idempotent: a create that TIMES OUT after the forge committed, then a retry (or a recurrence
    # before the cooldown stamp is written — the stamp only lands on a successful escalation), would
    # open a SECOND issue for the same occurrence. Before creating, we read back the open issues and
    # reuse the one already carrying this marker — the forge's own state is the idempotency key.
    marker = incident_marker(sig)

    body = """
    Incident `#{sig}` sur `#{subject}`.
    Raison : `#{inspect(reason)}`.

    #{kind_note}

    Domaine SYSADMIN (substrat : tmux / bwrap / launch / REPL) — PAS un problème de projet.
    (Issue auto — durcissement #5.2.)
    #{detail_block(opts[:reason_detail])}#{correlation_block(opts[:correlation_id])}#{pane_block(opts[:pane])}
    #{marker}
    """

    case find_open_incident(list_fun, repo, marker) do
      {:ok, existing} ->
        # An open issue already carries this occurrence's marker — the create either landed and its
        # ack was lost, or a concurrent escalation won. Reuse it (ensure the discovery label), never
        # a duplicate. `nil` = readback said "none" (or was unreadable → create, fail-closed toward
        # having an issue rather than suppressing an alarm).
        Logger.info(
          "IncidentRegistry: incident #{inspect(sig)} already open as ##{existing} — reusing (idempotent), no duplicate"
        )

        finalize_escalation(add_label_fun, repo, existing, label)

      nil ->
        create_and_label(create_fun, add_label_fun, repo, title, body, assignee, label)
    end
  end

  defp create_and_label(create_fun, add_label_fun, repo, title, body, assignee, label) do
    # `create_issue` expects INTEGER label IDs (ForgeClient contract), NOT names. So we follow the
    # established pattern (`PodTools.do_create_issue`): create the issue (with the assignee) THEN set the label by
    # NAME via `add_label` (name->id resolution + org-label auto-creation on the ForgeClient side). Passing
    # `labels: [name-string]` to the POST -> 422 Gitea "cannot unmarshal string into int64" — the
    # sysadmin escalation would create NO issue (silent dead rail).
    with {:ok, number} <- create_system_issue(create_fun, repo, title, body, assignee) do
      finalize_escalation(add_label_fun, repo, number, label)
    end
  end

  defp finalize_escalation(add_label_fun, repo, number, label) do
    # `error_system` is THE durable DISCOVERY label — the moduledoc's contract is « the poller/human finds
    # the issue BY this label ». `add_label` is NOT fail-loud on the ForgeClient side (bare tuple, no log).
    case add_discovery_label(add_label_fun, repo, number, label) do
      :ok ->
        {:ok, number}

      {:error, reason} ->
        # F-C075 — a PERSISTENTLY failing discovery label (after retries) leaves the sysadmin issue
        # INVISIBLE to label-filtered discovery. We do NOT report a clean `{:ok, number}` (which
        # `record_or_escalate` turns into a LYING `{:escalated}` — the alarm looks delivered while the
        # incident is unfindable). We SURFACE it → mapped to `{:escalation_failed, _}`: the alarm keeps
        # firing on recurrence, an operator must act. The issue EXISTS (created + usually assigned); its
        # number rides in the reason for cleanup / label-repair.
        Logger.error(
          "IncidentRegistry: sysadmin issue ##{number} created but discovery label " <>
            "#{inspect(label)} NOT added after retries (#{inspect(reason)}) — NOT label-discoverable, " <>
            "escalation SURFACED as failed (never a lying {:escalated})"
        )

        {:error, {:discovery_label_failed, number, reason}}
    end
  end

  # Hidden, stable per-occurrence marker (an HTML comment — invisible in the rendered issue, exact in
  # the body text). The idempotency key of the create.
  defp incident_marker(sig), do: "<!-- lcars-incident:#{sig} -->"

  # Readback idempotency: an OPEN issue already carrying this occurrence's marker → its number;
  # `nil` if none, OR if the listing is unreadable — a readback failure must NOT suppress an alarm,
  # so we fall through to create (fail-closed toward having an issue, the duplicate risk is the lesser
  # evil than a silent non-escalation). The `body` field is present on Gitea's issue-list payloads.
  defp find_open_incident(list_fun, repo, marker) do
    case list_fun.(repo, []) do
      {:ok, issues} when is_list(issues) ->
        Enum.find_value(issues, fn issue ->
          body = Map.get(issue, "body") || ""
          num = Map.get(issue, "number")
          if is_integer(num) and String.contains?(body, marker), do: {:ok, num}
        end)

      _ ->
        nil
    end
  end

  @doc """
  The fleet's OPS repo — SINGLE authority (`:fleet_pilot, :ops_repo`, default `"fleet/lcars"`).

  Two things land there and must never drift apart: the incident REGISTRY file (branch `work/ops`,
  `IncidentRegistry`) and the sysadmin ISSUES opened from it (here). They are two faces of one
  incident — a registry on repo A whose issues open on repo B is an alarm nobody finds. The two
  specific knobs (`:incident_registry_repo` / `:system_issue_repo`) remain as explicit overrides.
  """
  @spec ops_repo() :: String.t()
  def ops_repo, do: Application.get_env(:fleet_pilot, :ops_repo, "fleet/lcars")

  # F-C075 — BOUNDED retry of the DISCOVERY label (`error_system`): a transient forge blip (name→id
  # resolution / org-label auto-create / HTTP 500) self-heals; a persistent failure is SURFACED by
  # `escalate/5` (no lying `{:escalated}`). Immediate retries (no sleep): `escalate` is a stateless act off
  # the hot path, the dominant cause is a momentary forge hiccup.
  @label_attempts 3
  defp add_discovery_label(add_label_fun, repo, number, label, attempt \\ 1) do
    case add_label_fun.(repo, number, label, []) do
      {:ok, _} ->
        :ok

      {:error, reason} when attempt < @label_attempts ->
        Logger.warning(
          "IncidentRegistry: issue ##{number} discovery label #{inspect(label)} attempt " <>
            "#{attempt}/#{@label_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        add_discovery_label(add_label_fun, repo, number, label, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Creates the system issue with the sysadmin assignee; nonexistent assignee (account absent) -> retry WITHOUT
  # assignee (escalation takes precedence over naming: the issue must land; the durable discovery path is the
  # label, and the missing assignee is visible on the issue). Forge down on both attempts -> {:error, _}
  # propagated (record_or_escalate renders it as {:escalation_failed, _}, never a lying {:escalated}).
  #
  # KEEP: the retry drops the assignee on ANY first error, not only an invalid-assignee 422.
  # Assessed harmless → KEPT: a real forge-down fails BOTH attempts (→ {:error}, no spurious drop); the
  # invalid-assignee case is exactly when dropping is correct; only a transient error resolving BETWEEN the
  # two attempts drops a valid assignee — a rare race. And the assignee is a SECONDARY discovery path: the
  # DURABLE one is the `error_system` label (retried + fail-loud-surfaced, F-C075), so a dropped assignee
  # loses NO discoverability. A precise "drop only on a 422-assignee error" would couple to the forge HTTP
  # error shape (fragile) for a negligible gain — not worth it.
  defp create_system_issue(create_fun, repo, title, body, assignee) do
    case create_fun.(repo, title, body, assignees: [assignee]) do
      {:ok, _} = ok -> ok
      {:error, _} -> create_fun.(repo, title, body, [])
    end
  end

  # Full failure detail (producer-side `inspect/1` of the original reason term) — "Raison"
  # above carries the STABLE dedup category only; this block restores the variable part for
  # the human diagnosis. Empty when the producer had nothing beyond the category.
  defp detail_block(detail) when is_binary(detail) and detail != "" do
    "Détail : `#{detail}`.\n"
  end

  defp detail_block(_), do: ""

  # "Captured screen" block (offloaded fallback-ACK) attached to the issue — empty if no pane.
  defp pane_block(pane) when is_binary(pane) and pane != "" do
    "\n## Écran capturé (ce que l'agent affichait au moment de l'échec)\n```\n#{pane}\n```\n"
  end

  defp pane_block(_), do: ""

  # Incident ↔ mandate link (correlation_id = the source issue, threaded end-to-end): the
  # operator walks back from the Cat-5 symptom to the causing mandate without digging the logs.
  defp correlation_block(corr) when is_binary(corr) and corr != "" do
    "Mandat lié (correlation_id) : `#{corr}`.\n"
  end

  defp correlation_block(_), do: ""

  defp kind_describe(:recurrence),
    do: {"récurrence", "Déjà vu (registre `work/ops`) — pattern, pas random → ROOT-CAUSE requis."}

  defp kind_describe(:reroll_failed),
    do:
      {"re-roll échoué",
       "Le re-roll (re-spawn + re-wake) n'a PAS réparé → problème actif, ici et maintenant."}

  defp kind_describe(:pod_failed),
    do:
      {"pod en échec récurrent",
       "Pod déjà tombé sur la même cause (registre `work/ops`) → pattern → ROOT-CAUSE requis."}

  defp kind_describe(:sp_suspect),
    do:
      {"SP suspect (wake récurrent)",
       "Le wake-fallback de ce rôle a déjà raté (registre `work/ops`). Avec de l'inférence, 1× = random ; " <>
         "récurrent = ce n'est PAS « l'agent est con » → le **SP est mauvais / a dérivé / le modèle réagit " <>
         "autrement**. ROOT-CAUSE = le PROMPT du rôle, pas l'agent."}

  defp kind_describe(:cat5),
    do:
      {"Cat-5 (sévérité MAX)",
       "Escalade Cat-5 (seed permanent corrompu / workflow_map illisible / oauth) — issue dès la " <>
         "PREMIÈRE occurrence, PAS de gate de récurrence : la sévérité max ne s'échantillonne pas."}
end

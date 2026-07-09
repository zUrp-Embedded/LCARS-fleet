defmodule Fleet.Pilot.IncidentRegistry.Escalation do
  @moduledoc """
  SYSADMIN escalation of an incident (opening an `error_system` forge issue), extracted
  from `Fleet.Pilot.IncidentRegistry`: the registry is the MEMORY (GenServer, WAL + forge
  sync); the escalation is a STATELESS act (no read of the GenServer — everything comes
  from the arguments + config) that builds and posts the issue. Two concerns, two modules.

  Shared by `WakeRecovery` and the failure consumers via the façade
  `IncidentRegistry.escalate/5` (DRY — a single writer of the sysadmin issue).

  ## Contract

    * Label `error_system` = DURABLE signal (the poller/human finds the issue by it);
      sysadmin assignee best-effort (account absent → retry WITHOUT assignee: escalation
      takes precedence over naming).
    * Forge down → `{:error, _}` propagated (`record_or_escalate` renders it as
      `{:escalation_failed, _}`, never a lying `{:escalated}`).
    * `kind` qualifies the MESSAGE (recurrence / failed re-roll / recurrent pod /
      SP suspect) — the diagnosis guides the sysadmin toward the root-cause.
  """

  require Logger

  @doc """
  Opens a system issue (`fleet/lcars`, label `error_system`, assignee `starfleet`=sysadmin) for an
  incident. `kind`: `:recurrence` | `:reroll_failed` | `:pod_failed` | `:sp_suspect`. Label = DURABLE
  signal (always); assignee best-effort (label-only fallback if the account does not exist).
  Returns `{:ok, number}` | `{:error, term}`.
  """
  @spec escalate(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def escalate(kind, subject, reason, sig, opts \\ []) do
    create_fun = Keyword.get(opts, :create_issue_fun, &Fleet.Pilot.ForgeClient.create_issue/4)
    add_label_fun = Keyword.get(opts, :add_label_fun, &Fleet.Pilot.ForgeClient.add_label/4)
    repo = opts[:repo] || Application.get_env(:fleet_pilot, :system_issue_repo, "fleet/lcars")

    label =
      opts[:label] || Application.get_env(:fleet_pilot, :system_issue_label, "error_system")

    assignee =
      opts[:assignee] || Application.get_env(:fleet_pilot, :system_issue_assignee, "starfleet")

    {kind_label, kind_note} = kind_describe(kind)
    title = "[#{label}] #{kind_label} : #{subject}"

    body = """
    Incident `#{sig}` sur `#{subject}`.
    Raison : `#{inspect(reason)}`.

    #{kind_note}

    Domaine SYSADMIN (substrat : tmux / bwrap / launch / REPL) — PAS un problème de projet.
    (Issue auto — durcissement #5.2.)
    #{pane_block(opts[:pane])}
    """

    # `create_issue` expects INTEGER label IDs (ForgeClient contract), NOT names. So we follow the
    # established pattern (`PodTools.do_create_issue`): create the issue (with the assignee) THEN set the label by
    # NAME via `add_label` (name->id resolution + org-label auto-creation on the ForgeClient side). Passing
    # `labels: [name-string]` to the POST -> 422 Gitea « cannot unmarshal string into int64 »: seen LIVE
    # 2026-07-04 (run poc-morse), the sysadmin escalation created NO issue (silent dead rail).
    with {:ok, number} <- create_system_issue(create_fun, repo, title, body, assignee) do
      # `error_system` is THE durable DISCOVERY label — the moduledoc's contract is « the poller/human finds
      # the issue BY this label ». `add_label` is NOT fail-loud on the ForgeClient side (bare tuple, no log)
      # → a failed label would leave the sysadmin issue INVISIBLE to label-filtered discovery (and, combined
      # with the assignee-retry, possibly with no assignee either) under a LYING `{:ok}`. So we LOG LOUD on
      # failure: the issue still exists + is usually assigned (the escalation happened), but its discovery
      # signal is degraded — an operator must KNOW, not a silent swallow.
      case add_label_fun.(repo, number, label, []) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "IncidentRegistry.Escalation: sysadmin issue ##{number} created but discovery label " <>
              "#{inspect(label)} NOT added (#{inspect(reason)}) — findable by assignee only, not by label filter"
          )
      end

      {:ok, number}
    end
  end

  # Creates the system issue with the sysadmin assignee; nonexistent assignee (account absent) -> retry WITHOUT
  # assignee (best-effort: escalation takes precedence over naming). Forge down on both attempts -> {:error, _}
  # propagated (record_or_escalate renders it as {:escalation_failed, _}, never a lying {:escalated}).
  defp create_system_issue(create_fun, repo, title, body, assignee) do
    case create_fun.(repo, title, body, assignees: [assignee]) do
      {:ok, _} = ok -> ok
      {:error, _} -> create_fun.(repo, title, body, [])
    end
  end

  # « Captured screen » block (offloaded fallback-ACK) attached to the issue — empty if no pane.
  defp pane_block(pane) when is_binary(pane) and pane != "" do
    "\n## Écran capturé (ce que l'agent affichait au moment de l'échec)\n```\n#{pane}\n```\n"
  end

  defp pane_block(_), do: ""

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
end

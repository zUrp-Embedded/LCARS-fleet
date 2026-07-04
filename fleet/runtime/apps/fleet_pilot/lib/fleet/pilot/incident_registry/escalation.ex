defmodule Fleet.Pilot.IncidentRegistry.Escalation do
  @moduledoc """
  Escalade SYSADMIN d'un incident (ouverture d'une issue forge `error_system`), extraite
  de `Fleet.Pilot.IncidentRegistry` : le registre est la MÉMOIRE (GenServer, WAL + sync
  forge) ; l'escalade est un acte STATELESS (aucune lecture du GenServer — tout vient
  des arguments + config) qui construit et poste l'issue. Deux concerns, deux modules.

  Partagée par `WakeRecovery` et les consumers d'échec via la façade
  `IncidentRegistry.escalate/5` (DRY — un seul writer de l'issue sysadmin).

  ## Contrat

    * Label `error_system` = signal DURABLE (le poller/humain trouve l'issue par lui) ;
      assignee sysadmin best-effort (compte absent → retry SANS assignee : l'escalade
      prime sur le nommage).
    * Forge down → `{:error, _}` propagé (`record_or_escalate` le rend en
      `{:escalation_failed, _}`, jamais un `{:escalated}` menteur).
    * `kind` qualifie le MESSAGE (récurrence / re-roll échoué / pod récurrent /
      SP suspect) — le diagnostic guide le sysadmin vers la root-cause.
  """

  require Logger

  @doc """
  Ouvre un issue système (`fleet/lcars`, label `error_system`, assignee `starfleet`=sysadmin) pour un
  incident. `kind` : `:recurrence` | `:reroll_failed` | `:pod_failed` | `:sp_suspect`. Label = signal
  DURABLE (toujours) ; assignee best-effort (fallback label-only si le compte n'existe pas).
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

    # `create_issue` attend des IDs de label ENTIERS (contrat ForgeClient), PAS des noms. On suit donc le
    # pattern etabli (`PodTools.do_create_issue`) : creer l'issue (avec l'assignee) PUIS poser le label par
    # NOM via `add_label` (resolution name->id + auto-creation du label d'org cote ForgeClient). Passer
    # `labels: [nom-string]` au POST -> 422 Gitea « cannot unmarshal string into int64 » : vu LIVE
    # 2026-07-04 (run poc-morse), l'escalade sysadmin ne creait AUCUNE issue (rail mort silencieux).
    with {:ok, number} <- create_system_issue(create_fun, repo, title, body, assignee) do
      # Label = signal DURABLE (le poller/humain trouve l'issue par ce label). add_label est fail-loud cote
      # ForgeClient mais on ignore ici : l'ISSUE existe = l'escalade a eu lieu ; le label auto-cree son
      # org-label et retry, echec tres improbable. Meme choix que do_create_issue (type:feature).
      _ = add_label_fun.(repo, number, label, [])
      {:ok, number}
    end
  end

  # Cree l'issue systeme avec l'assignee sysadmin ; assignee inexistant (compte absent) -> retry SANS
  # assignee (best-effort : l'escalade prime sur le nommage). Forge down aux deux tentatives -> {:error, _}
  # propage (record_or_escalate le rend en {:escalation_failed, _}, jamais un {:escalated} menteur).
  defp create_system_issue(create_fun, repo, title, body, assignee) do
    case create_fun.(repo, title, body, assignees: [assignee]) do
      {:ok, _} = ok -> ok
      {:error, _} -> create_fun.(repo, title, body, [])
    end
  end

  # Bloc « écran capturé » (fallback-ACK déporté) attaché au issue — vide si pas de pane.
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

defmodule Fleet.Pilot.IncidentRegistry.Escalation do
  @moduledoc """
  Creates or reuses a sysadmin incident issue without registry-memory access.
  The open-issue marker read reduces duplicates but is not atomic with creation.
  An unreadable listing still permits creation, with the uncertainty in its body.

  Success requires the discovery label (default error_system), with three immediate
  attempts. A label failure returns the existing issue number for repair. Assignment
  is secondary: any create error with an assignee retries once without it, without
  another dedup read. Callback exceptions are not caught here.

  kind_describe/1 is a closed set: unsupported kinds raise. Declarative immediate
  routes are checked by Catalog; code-origin kinds also need a supported clause.
  """

  require Logger

  @doc """
  Opens or reuses the issue for sig and ensures its discovery label. Repository,
  label and assignee can be overridden by opts or configuration. Otherwise the
  assignee is read from the provisioned seat projection.

  :reason_detail preserves variable failure diagnostics outside the dedup category;
  :correlation_id links the source mandate and :pane supplies captured output.
  """
  alias Fleet.Forge.Client

  @spec escalate(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def escalate(kind, subject, reason, sig, opts \\ []) do
    create_fun = Keyword.get(opts, :create_issue_fun, &Client.create_issue/4)
    add_label_fun = Keyword.get(opts, :add_label_fun, &Client.add_label/4)
    list_fun = Keyword.get(opts, :list_issues_fun, &Client.list_open_issues/2)

    repo =
      opts[:repo] || Application.get_env(:lcars_fleet, :pilot_system_issue_repo) || ops_repo()

    label =
      opts[:label] || Application.get_env(:lcars_fleet, :pilot_system_issue_label, "error_system")

    assignee = resolve_assignee(opts)

    {kind_label, kind_note} = kind_describe(kind)
    title = "[#{label}] #{kind_label} : #{subject}"

    # Reuse open issues carrying this signature marker after an ambiguous create.
    # Read and create are separate: concurrent calls can still create duplicates.
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

    dedup = find_open_incident(list_fun, repo, marker)

    result =
      case dedup do
        {:ok, existing} ->
          # Repair the existing issue's discovery label without another create.
          Logger.info(
            "IncidentRegistry: incident #{inspect(sig)} already open as ##{existing} — reusing (idempotent), no duplicate"
          )

          finalize_escalation(add_label_fun, repo, existing, label)

        :none ->
          create_and_label(create_fun, add_label_fun, repo, title, body, assignee, label)

        {:unverified, why} ->
          Logger.warning(
            "IncidentRegistry: dedup readback FAILED for #{inspect(sig)} (#{inspect(why)}) — " <>
              "opening the issue anyway (a silent non-escalation is worse), and SAYING SO in its " <>
              "body: a twin carrying the same marker may already be open"
          )

          create_and_label(
            create_fun,
            add_label_fun,
            repo,
            title,
            body <> dedup_warning(dedup),
            assignee,
            label
          )
      end

    result
  end

  # Provisioning writes <LCARS_STORE_ROOT>/state/pilot.assignee at each boot
  # (`services/container/init.sh`, the resolved seat). Read the seat's login, not its display name
  # or a guessed role login. Missing/empty projection with a store logs a warning; no store
  # silently omits assignment. Explicit opts/config take precedence.
  defp resolve_assignee(opts) do
    case opts[:assignee] || Application.get_env(:lcars_fleet, :pilot_system_issue_assignee) do
      name when is_binary(name) and name != "" ->
        name

      _unset ->
        read_projected_assignee()
    end
  end

  defp read_projected_assignee do
    case System.get_env("LCARS_STORE_ROOT") do
      root when is_binary(root) and root != "" ->
        path = Path.join([root, "state", "pilot.assignee"])

        case File.read(path) do
          {:ok, body} ->
            projected_login(String.trim(body), path)

          {:error, _} ->
            warn_projection_missing(path, :absent)
            nil
        end

      _no_store ->
        nil
    end
  end

  defp warn_projection_missing(path, why) do
    Logger.warning(
      "Escalation: magasin present mais la projection du siege est #{why} (#{path}) — issue " <>
        "ouverte SANS assignee. L'init du conteneur (services/container/init.sh) la pose a chaque boot ; " <>
        "si elle manque, le siege n'est pas resolu ou l'init n'a pas tourne."
    )
  end

  defp create_and_label(create_fun, add_label_fun, repo, title, body, assignee, label) do
    # Creation accepts integer label IDs; add_label resolves the name afterwards.
    with {:ok, number} <- create_system_issue(create_fun, repo, title, body, assignee) do
      finalize_escalation(add_label_fun, repo, number, label)
    end
  end

  defp finalize_escalation(add_label_fun, repo, number, label) do
    case add_discovery_label(add_label_fun, repo, number, label) do
      :ok ->
        {:ok, number}

      {:error, reason} ->
        # The issue exists but label-filtered discovery misses it. Return its number
        # with the failure so later attempts or an operator can repair the label.
        Logger.error(
          "IncidentRegistry: sysadmin issue ##{number} created but discovery label " <>
            "#{inspect(label)} NOT added after retries (#{inspect(reason)}) — NOT label-discoverable, " <>
            "escalation SURFACED as failed (never a lying {:escalated})"
        )

        {:error, {:discovery_label_failed, number, reason}}
    end
  end

  # Hidden stable signature marker; shared across recurrences, not a unique occurrence.
  defp incident_marker(sig), do: "<!-- lcars-incident:#{sig} -->"

  # A failed listing must not suppress the alarm. Distinguish it from an empty
  # listing so the created issue warns its reader about a possible duplicate.
  defp find_open_incident(list_fun, repo, marker) do
    case list_fun.(repo, []) do
      {:ok, issues} when is_list(issues) ->
        Enum.find_value(issues, :none, &issue_bearing_marker(&1, marker))

      other ->
        {:unverified, other}
    end
  end

  # Treat an empty projection as absent, avoiding an invalid assignees option.
  defp projected_login("", path) do
    warn_projection_missing(path, :empty)
    nil
  end

  defp projected_login(login, _path), do: login

  defp issue_bearing_marker(issue, marker) do
    num = Map.get(issue, "number")
    if is_integer(num) and String.contains?(Map.get(issue, "body") || "", marker), do: {:ok, num}
  end

  # Put dedup uncertainty in the issue body, where its reader can see it.
  defp dedup_warning({:unverified, why}) do
    """

    > ⚠ **Déduplication NON vérifiée** : la relecture des issues ouvertes a échoué
    > (`#{inspect(why)}`). Une issue portant le même marqueur peut déjà exister — cherchez-la avant
    > d'agir. L'alarme a été ouverte quand même : une escalade silencieuse serait pire qu'un doublon.
    """
  end

  @doc """
  Shared default repository for registry backing and incident issues, configured
  by :pilot_ops_repo. :pilot_incident_registry_repo and :pilot_system_issue_repo
  remain explicit overrides for splitting their destinations.
  """
  @spec ops_repo() :: String.t()
  def ops_repo, do: Application.get_env(:lcars_fleet, :pilot_ops_repo, "lcars/_ops")

  # Retry returned label errors immediately, without sleep.
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

  # With an assignee, retry ANY returned create error once without assignment.
  # This avoids coupling fallback to HTTP error shapes but may drop a valid login
  # or duplicate a create whose acknowledgement was lost. Without an assignee,
  # omit the option and make one attempt. The discovery label remains required.
  defp create_system_issue(create_fun, repo, title, body, nil) do
    create_fun.(repo, title, body, [])
  end

  defp create_system_issue(create_fun, repo, title, body, assignee) do
    case create_fun.(repo, title, body, assignees: [assignee]) do
      {:ok, _} = ok -> ok
      {:error, _} -> create_fun.(repo, title, body, [])
    end
  end

  # Restore variable diagnostics omitted from the stable reason category.
  defp detail_block(detail) when is_binary(detail) and detail != "" do
    "Détail : `#{detail}`.\n"
  end

  defp detail_block(_), do: ""

  # "Captured screen" block (offloaded fallback-ACK) attached to the issue — empty if no pane.
  defp pane_block(pane) when is_binary(pane) and pane != "" do
    "\n## Écran capturé (ce que l'agent affichait au moment de l'échec)\n```\n#{pane}\n```\n"
  end

  defp pane_block(_), do: ""

  # Link back to the source mandate without requiring log correlation.
  defp correlation_block(corr) when is_binary(corr) and corr != "" do
    "Mandat lié (correlation_id) : `#{corr}`.\n"
  end

  defp correlation_block(_), do: ""

  defp kind_describe(:repo_poll_crash),
    do:
      {"depot qui leve a chaque poll",
       "Le cycle de ce depot a leve une exception. Les autres depots sont servis, lui non — et la " <>
         "cause est le plus souvent deterministe (la meme PR, le meme fichier), donc elle se " <>
         "represente a chaque tick. Ce depot est hors service tant que personne ne regarde."}

  defp kind_describe(:issue_lock_residual),
    do:
      {"verrou residuel sur une issue FERMEE",
       "Le merge a reussi, l'issue est close, mais `lcars-in-flight` est reste pose et le " <>
         "chronometre court encore. Aucun rail ne le rattrape : le poller ne lit que les issues " <>
         "OUVERTES, et les wardens portent sur les pods. Retrait manuel de l'etiquette + arret du " <>
         "chronometre ; les metriques de duree de ce ticket sont faussees d'ici la."}

  defp kind_describe(:ops_root_missing),
    do:
      {"racine des faces absente",
       "La racine `ops` a disparu (demontage, permissions) — le rail d'etapes est saute pour TOUS " <>
         "les depots, pas un seul. La flotte tourne a vide et la telemetrie rapporte des comptes " <>
         "nuls, indistinguables d'une flotte au repos."}

  defp kind_describe(:recurrence),
    do: {"récurrence", "Déjà vu (registre `ops`) — pattern, pas random → ROOT-CAUSE requis."}

  defp kind_describe(:reroll_failed),
    do:
      {"re-roll échoué",
       "Le re-roll (re-spawn + re-wake) n'a PAS réparé → problème actif, ici et maintenant."}

  defp kind_describe(:sp_suspect),
    do:
      {"SP suspect (wake récurrent)",
       "Le wake-fallback de ce rôle a déjà raté (registre `ops`). Avec de l'inférence, 1× = random ; " <>
         "récurrent = ce n'est PAS « l'agent est con » → le **SP est mauvais / a dérivé / le modèle réagit " <>
         "autrement**. ROOT-CAUSE = le PROMPT du rôle, pas l'agent."}

  # Drain tests stub escalation; a real escalation test must cover this kind.
  defp kind_describe(:awaits_arch_stuck),
    do:
      {"awaits-arch NON draine — ticket sorti du pipeline",
       "Le drain de `lcars-awaits-arch` a echoue : le label RESTE pose et le dispatcher saute " <>
         "toute issue qui le porte. Ce ticket a quitte le pipeline et aucun tick ne le " <>
         "re-proposera — seul un retrait manuel du label le debloque."}

  defp kind_describe(:workflow_map_failed),
    do:
      {"workflow_map illisible — le dispatch est saute",
       "La carte de workflow de ce depot ne se charge pas : le rail d'etapes le SAUTE tant que " <>
         "personne ne corrige. Une carte illisible bloque le dispatch de TOUTES ses issues — " <>
         "d'ou l'issue des la premiere occurrence, pas a la recidive."}

  defp kind_describe(:project_card_failed),
    do:
      {"carte declaree illisible — le projet tourne sur la carte par defaut",
       "La carte que ce depot DECLARE ne se charge pas : chaque dispatch retombe sur la carte de " <>
         "delegation par defaut — une criticite que personne n'a choisie pour lui. Corriger la " <>
         "declaration du projet (ou la carte du catalogue qu'elle nomme)."}

  defp kind_describe(:project_declaration_invalid),
    do:
      {"declaration d'intensite illisible — pipeline par defaut applique",
       "Le `.lcars.json` de ce depot est illisible ou invalide : le projet tourne sur le " <>
         "pipeline de delegation par defaut. Re-declarer pour reparer — d'ici la, la " <>
         "substitution rejouera a chaque lecture."}
end

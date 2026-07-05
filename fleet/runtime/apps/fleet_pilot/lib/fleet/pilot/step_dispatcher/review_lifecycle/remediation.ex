defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation do
  @moduledoc """
  Remédiation BORNÉE du flux review, extraite de `ReviewLifecycle` : re-spawn du
  producteur pour REWORK (verdict `changes_requested`) et RÉSOLUTION de conflit de
  merge — toujours sous un frein, jamais de churn infini.

  ## Les deux freins (le concern nommable de ce module)

    * **Rework** — compteur FORGE-NATIF (`count_change_request_rounds` = nb de reviews
      REQUEST_CHANGES, monotone), budget `:max_pr_rework_rounds` (défaut 2, aligné sur
      le frein workflow_map `max_rework_rounds`). Au-delà → ESCALADE ARCH. Budget
      illisible → on NE re-spawn PAS à l'aveugle : escalade (symétrique de `rebound`
      côté StepRunConsumer qui surface).
    * **Conflit** — l'`IncidentRegistry` (cross-session, work/ops) EST le frein :
      1ʳᵉ occurrence → résolution (rebase producteur) ; récurrence → escalade arch.
      Le dédup par signature EST le throttle.

  La DÉCISION vit ici ; l'EXÉCUTION du re-spawn descend vers `RoleDispatch` (feuille
  partagée avec le spawn de juge — pas de fork de la mécanique) ; l'ÉCRITURE de
  l'escalade humaine descend vers `ArchEscalation` (seams étroits reconstruits ICI,
  jamais le `Ctx` entier).
  """

  require Logger

  # Écriture de l'escalade humaine (cluster IMPUR) : Remediation DÉCIDE (budget rework /
  # IncidentRegistry), ArchEscalation ÉCRIT (comment gatekeeper dédupliqué + verrou `awaits-arch`).
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  @doc """
  Rework juge : la PR porte un verdict REQUEST_CHANGES courant (l'état a déjà été lu par
  `dispatch_review` → pas de re-lecture ici) → le PRODUCTEUR (rôle git_native de head.ref)
  reprend pour corriger sur la même PR. Idempotent (verrou PR).

  FREIN ANTI-CHURN : sans compteur, ce chemin re-spawnerait le producteur à chaque tick —
  le frein `rebound` (budget workflow_map, StepRunConsumer) n'est JAMAIS appelé sur le
  chemin PR-review-driven → rework INFINI si l'eng ne satisfait jamais le juge. Bornage
  forge-natif (cf. moduledoc), au-delà → escalade arch, fin du churn.
  """
  @spec dispatch_rework(integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_rework(pr_number, head, %Ctx{} = ctx) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        budget = Keyword.get(ctx.opts, :max_pr_rework_rounds, 2)

        case ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts) do
          {:ok, rounds} when rounds <= budget ->
            RoleDispatch.dispatch(:rework, pr_number, head, producer_role, ctx)

          {:ok, rounds} ->
            ArchEscalation.escalate_rework(
              arch_seams(ctx),
              pr_number,
              head,
              %{rounds: rounds, budget: budget}
            )

          {:error, reason} ->
            # Budget non vérifiable → on n'entre pas dans une boucle aveugle : on remonte à l'arch.
            ArchEscalation.escalate_rework(
              arch_seams(ctx),
              pr_number,
              head,
              {:budget_unreadable, reason}
            )
        end

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  @doc """
  Merge KO sur conflit (PR approuvée, `main` avancé sous une PR parallèle touchant le
  même fichier). Borné par l'IncidentRegistry (cross-session, work/ops) :

    * 1ʳᵉ occurrence → `:recorded` → dispatch le PRODUCTEUR en `:resolve_conflict`
      (rebase + résous ; le push rebasé invalide les vieilles reviews via head_sha →
      les juges re-valident le fusionné, gatekeeper scelle au tick suivant) ;
    * récurrence → `{:escalated, _}` (résolution déjà tentée, conflit persiste) →
      ESCALADE ARCH. PAS de boucle.
  """
  @spec dispatch_conflict_resolution(integer(), String.t(), term(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_conflict_resolution(pr_number, head, reason, %Ctx{} = ctx) do
    # Le n° de PR est encodé DIGIT-FREE (base-26 a..z) DANS le subject. `IncidentRegistry.signature`
    # passe le subject par `normalize` (`~r/\d+/ → "N"`, PARTAGÉ pod/wake — on ne le touche PAS) : un `pr-8`
    # décimal deviendrait `pr-N` ≡ `pr-12` → après le 1er conflit d'un repo, TOUTE PR suivante en conflit serait
    # vue « récurrente » → escaladée arch au lieu d'être résolue (la résolution parallèle neutralisée dès le
    # 2ᵉ issue parallèle). En encodant le numéro en LETTRES (`pr-i` pour 8, `pr-m` pour 12), `normalize` ne
    # le collapse plus → la clé incident est DISTINCTE par PR. (Le repo, lui, peut porter des digits collapsés
    # par normalize : sans incidence — une session de conflits est dans UN repo, l'axe de distinction est la PR.)
    subject = "#{ctx.repo}#pr-#{encode_pr_letters(pr_number)}"

    # Reason STABLE pour le compteur : la dedup inclut la reason → un message http qui varie casserait le seuil.
    # Le détail réel (`reason`) va dans le commentaire d'escalade, pas dans la clé. Seam test : router vers un
    # IncidentRegistry nommé (async-safe) via `:incident_registry_server` ; absent (prod) → registry par défaut.
    reg_opts =
      case Keyword.get(ctx.opts, :incident_registry_server) do
        nil -> []
        server -> [server: server]
      end

    case Fleet.Pilot.IncidentRegistry.record_or_escalate(
           "merge-conflict",
           subject,
           "PR inmergeable (conflit de base)",
           reg_opts
         ) do
      :recorded ->
        resolve_first_conflict(head, pr_number, ctx)

      {:record_failed, e} ->
        # Registre indisponible : l'incident n'est PAS mémorisé (une récurrence ne sera pas détectée),
        # mais c'est bien une 1re occurrence → on tente quand même la résolution. On le CRIE.
        Logger.error(
          "StepDispatcher: merge-conflict #{subject} : incident NON gravé (registre indisponible) — " <>
            "1re résolution tentée SANS mémoire (récurrence non détectable) : #{inspect(e)}"
        )

        resolve_first_conflict(head, pr_number, ctx)

      {:escalated, _} ->
        ArchEscalation.escalate_conflict(arch_seams(ctx), pr_number, head, reason)

      {:escalation_failed, e} ->
        # Récurrence DÉTECTÉE (le conflit persiste) → on escalade à l'arch comme prévu. Mais le issue
        # sysadmin (error_system) n'a PAS pu être ouvert (forge down ?) — on le CRIE, on ne rassure pas.
        Logger.error(
          "StepDispatcher: merge-conflict #{subject} RÉCURRENT mais issue sysadmin ÉCHOUÉ — AUCUN " <>
            "issue error_system créé (forge down ?) ; escalade arch tentée tout de même : #{inspect(e)}"
        )

        ArchEscalation.escalate_conflict(arch_seams(ctx), pr_number, head, reason)
    end
  end

  # 1re occurrence d'un conflit : on tente la résolution (re-spawn du producteur en mode rebase/résous).
  # Partagé entre `:recorded` (incident gravé) et `{:record_failed, _}` (registre indisponible — on tente
  # quand même, c'est bien un 1er passage du point de vue dispatch).
  defp resolve_first_conflict(head, pr_number, ctx) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        RoleDispatch.dispatch(:resolve_conflict, pr_number, head, producer_role, ctx)

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  # Contrat de frontière de l'écriture d'escalade : Remediation décide, ArchEscalation écrit. On ne
  # lui passe QUE les 3 seams forge (`@enforce_keys` → un accès hors-3-seams ne compile pas), jamais le ctx entier.
  defp arch_seams(%Ctx{} = ctx),
    do: %ArchEscalation.Seams{forge: ctx.forge, repo: ctx.repo, forge_opts: ctx.forge_opts}

  # Encode un n° de PR en LETTRES (base-26 bijective a..z) → DIGIT-FREE, invisible au `normalize` de
  # l'IncidentRegistry (qui collapse ~r/\d+/ → "N") : deux PR distinctes gardent des clés incident
  # DISTINCTES (isole les conflits par PR). n ≤ 0 / non-entier (anomalie forge) → "x" (ne crash pas la clé).
  # Vit ici : seul `dispatch_conflict_resolution` le consomme (clé d'incident, pas l'écriture d'escalade).
  defp encode_pr_letters(n) when is_integer(n) and n > 0, do: encode_pr_letters(n, [])
  defp encode_pr_letters(_), do: "x"
  defp encode_pr_letters(0, acc), do: List.to_string(acc)

  defp encode_pr_letters(n, acc),
    do: encode_pr_letters(div(n - 1, 26), [?a + rem(n - 1, 26) | acc])
end

defmodule Fleet.Pilot.StepDispatcher.ArchEscalation do
  @moduledoc """
  Cluster IMPUR « escalade arch » (écriture forge) extrait de `Fleet.Pilot.StepDispatcher`.

  Quand le cœur décisionnel de `StepDispatcher` a tranché qu'une PR ne peut plus avancer seule —
  rework non convergent (budget de rounds épuisé, MA-06) ou conflit de merge non auto-résolu
  (récurrence détectée par l'IncidentRegistry) — il DÉLÈGUE ici l'écriture de l'escalade vers le
  seul canal humain (l'architecte) :

    1. un commentaire gatekeeper DÉDUPLIQUÉ (signé via `as_role`, `dedup_signature`) sur l'ISSUE ;
    2. le verrou `lcars-awaits-arch` posé sur l'ISSUE → le poller la SKIP (`decide/1`,
       `dispatch_review`), plus de re-dispatch → fin du churn.

  Ce module ne DÉCIDE de RIEN : le budget de rework (`count_change_request_rounds`/forge),
  l'IncidentRegistry (récurrence conflit) et le choix résolution-vs-escalade restent le
  SINGLE-AUTHORITY du cœur (`dispatch_rework`/`dispatch_conflict_resolution`). Ce module ne fait
  QU'ÉCRIRE — un seul point d'écriture forge partagé par les deux escalades (`escalate_to_arch`,
  privé), pas de fork de signature/label.

  ## Frontière : struct de seams explicite (pas le `ctx` entier)

  Le cluster ne lit QUE 3 seams du dispatch (`forge`, `repo`, `forge_opts`). On NE passe PAS le
  `ctx`/`opts` entier — ce serait une fuite de frontière. Le caller construit un `%Seams{}`
  (contrat étroit, TYPÉ) : `@enforce_keys` force les 3 champs à l'appel, et un accès
  `seams.<autre_champ>` ne compile pas (KeyError statique) — une map nue laisserait passer
  `Map.get(seams, :spawner)` en silence.

  ## Naming

  L'API publique est `escalate_rework/4` + `escalate_conflict/4` (pas `escalate_rework_to_arch` :
  le suffixe `_to_arch` est désormais porté par le nom du module — `ArchEscalation.escalate_rework`
  se lit sans redondance). `seams` est le 1ᵉʳ argument (le caller construit le contrat, PUIS
  décrit l'escalade). `encode_pr_letters/1` (pur) vit avec ce cluster : c'est le vocabulaire de
  formatage des numéros de PR de l'escalade/incident (voir sa doc), consommé par le cœur pour
  clé-er l'IncidentRegistry digit-free.
  """

  # Vocabulaire protocole = source unique Fleet.Pilot.Labels (constante compile-time, comme dans
  # StepDispatcher qui garde SON @awaits_arch_label pour `decide/1` — même source, pas un fork).
  @awaits_arch_label Fleet.Pilot.Labels.awaits_arch()

  defmodule Seams do
    @moduledoc """
    Contrat de frontière du cluster d'escalade arch : les 3 seams d'écriture forge lus du dispatch
    (`forge`/`repo`/`forge_opts`). Construit par le caller AVANT `escalate_rework/4` ou
    `escalate_conflict/4` — le cluster ne reçoit jamais le `ctx`/`opts` entier.
    """
    @enforce_keys [:forge, :repo, :forge_opts]
    defstruct [:forge, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Client forge injecté (seam `:forge_client`, défaut prod `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # `owner/name` du repo (l'escalade écrit sur l'ISSUE de ce repo).
            repo: String.t(),
            # Opts forge (base_url/token…) ; `as_role` gatekeeper + dedup y sont ajoutés.
            forge_opts: keyword()
          }
  end

  @doc """
  Rework PR épuisé (rounds > budget, ou budget illisible) → l'arch tranche. Symétrique de
  `escalate_conflict/4` : commentaire gatekeeper dédupliqué + verrou `lcars-awaits-arch` sur
  l'ISSUE (le poller la SKIP, plus de re-dispatch). `detail` (map `%{rounds, budget}` ou
  `{:budget_unreadable, reason}`) va DANS le commentaire, pas dans la clé de dédup.

  Retour `{:skipped, {:rework_exhausted_escalated, pr_number}}` (forme gérée par le poller). Head
  non-fleet (anomalie : le caller a déjà parsé le producteur en amont) → `{:skipped,
  :not_fleet_branch}` (défensif).
  """
  @spec escalate_rework(Seams.t(), integer(), String.t(), term()) :: {:skipped, term()}
  def escalate_rework(%Seams{} = seams, pr_number, head, detail) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[rework-exhausted-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Rework non convergent sur la PR ##{pr_number} (issue ##{issue_n}) : le budget " <>
          "de rounds de review est épuisé (`#{inspect(detail)}`). Le producteur ne satisfait pas les juges. " <>
          "Reprends : re-cadre le brief, tranche le désaccord, ou ferme la PR. L'issue reste hors-dispatch " <>
          "tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      escalate_to_arch(seams, issue_n, signature, body)
      {:skipped, {:rework_exhausted_escalated, pr_number}}
    end
  end

  @doc """
  Conflit de merge non auto-résolu (1 tentative de rebase déjà faite → récurrence) → l'arch
  tranche. Commentaire gatekeeper dédupliqué + verrou `lcars-awaits-arch` sur l'ISSUE → le poller
  la SKIP (hors-dispatch, plus de retry). Honnête : on ne masque pas, on remonte au seul canal
  humain. `reason` (détail forge du merge KO) va DANS le commentaire.

  Retour `{:skipped, {:merge_conflict_escalated, pr_number}}` = forme GÉRÉE par le poller
  (`step_process_pulls`) → compté skipped, pas de crash. Un `{:escalated, _}` ne serait dans AUCUNE
  clause du `case do_poll` → CaseClauseError à chaque tick : un retour de dispatch DOIT être
  `{:ok|:skipped|:error}`, jamais une 4ᵉ forme. Head non-fleet → `{:skipped, :not_fleet_branch}`.
  """
  @spec escalate_conflict(Seams.t(), integer(), String.t(), term()) :: {:skipped, term()}
  def escalate_conflict(%Seams{} = seams, pr_number, head, reason) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[merge-conflict-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Conflit de merge non auto-résolu sur la PR ##{pr_number} (issue ##{issue_n}) " <>
          "après une tentative de rebase+résolution (`#{inspect(reason)}`). Reprends : fais rebaser/résoudre la " <>
          "PR sur `main`, ou re-cadre. L'issue reste hors-dispatch tant que `lcars-awaits-arch` est posé.\n\n" <>
          signature

      escalate_to_arch(seams, issue_n, signature, body)
      {:skipped, {:merge_conflict_escalated, pr_number}}
    end
  end

  # CŒUR d'escalade arch (factorisé — conflit ET rework épuisé) : commentaire gatekeeper DÉDUPLIQUÉ
  # (signé via `as_role`) + verrou `lcars-awaits-arch` sur l'ISSUE → le poller la SKIP
  # (hors-dispatch). Best-effort : on remonte au canal humain (l'arch), on ne masque pas. Un seul
  # point d'écriture forge pour toutes les escalades arch PR (pas de fork de signature/label).
  defp escalate_to_arch(%Seams{} = seams, issue_n, signature, body) do
    gk_opts =
      seams.forge_opts
      |> Fleet.Pilot.ForgeClient.as_role(Fleet.Pilot.GatekeeperSeal.gatekeeper_role())
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    _ = seams.forge.post_comment(seams.repo, issue_n, body, gk_opts)
    _ = seams.forge.add_label(seams.repo, issue_n, @awaits_arch_label, seams.forge_opts)
    :ok
  end

  # Extrait le n° d'ISSUE parente de la feature-branch (`lcars/issue-<n>-<role>`) via le parseur
  # UNIQUE `Fleet.Pilot.ForgeProtocol.parse_feature_branch/1` (pas un re-parse maison). Adaptateur
  # local `{:ok, issue_n} | {:skipped, :not_fleet_branch}` — le producteur n'intéresse pas
  # l'escalade (elle écrit sur l'issue), d'où un retour plus étroit que le `parse_feature_branch_or_skip`
  # de StepDispatcher (qui rend le tuple `{n, role}` complet pour promote_pr/dispatch_pr_role).
  defp issue_of_branch_or_skip(head) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {issue_n, _producer}} -> {:ok, issue_n}
      :error -> {:skipped, :not_fleet_branch}
    end
  end
end

defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Métier « délégation forge » de l'architecte + gate d'autorisation — extrait de
  `Fleet.MCP.PodTools` (qui garde la table de routage `handle_tool_call/3` et le
  format de contenu MCP). Nommé d'après le vocabulaire du code (« canal DÉLÉGATION »,
  `delegation_org`, `delegation_target`) : les trois tools forment le canal par lequel
  l'architecte délègue du travail à la fleet et le suit.

    * `create_issue/4` — canal DÉLÉGATION : pose une issue forge prête pour le poller.
    * `create_project/3` — canal ONBOARDING : démarre un projet neuf (repo + dual-dir).
    * `issue_status/3` — canal SUIVI : lit l'état d'un issue délégué (issue + PR).

  ## Gate architecte (commune aux trois)

  Ces tools sont des actes d'ARCHITECTE : créer un repo forge, écrire/pousser dans
  `/home/projects`, déléguer du travail, suivre une délégation. La barrière est
  serveur-side : `require_architect/1` résout le rôle depuis l'identité du CANAL
  (`state.pod_id`, porté par l'accepteur de socket — pas de champ du wire) PUIS exige
  que ce rôle gravé au spawn soit `architect`. Un pod worker (engineer, reviewer), un
  rôle nil/inconnu ou un pod absent du registre → REFUS. Fail-closed de bout en bout :
  aucun cas ne retombe sur un accès autorisé. (Le filtre de visibilité côté pont reste
  une commodité UX — ne pas montrer un tool inutilisable — mais l'autorisation vit ICI.)

  Les trois fonctions prennent le `state` MCP en dernier argument et n'y lisent QUE
  `pod_id` (la gate) — jamais d'identité dans les arguments wire.

  ## Seams (app-env `:fleet_mcp`)

    * `:forge_client` (défaut `Fleet.Pilot.ForgeClient`) — client forge, dispatch
      runtime (pas de dep compile-time fleet_pilot). CONTRAT = behaviour
      `Fleet.MCP.PodTools.Delegation.ForgeClient` (callbacks typés + resolver
      `resolved/0`, source unique du défaut).
    * `:project_onboard` (défaut `Fleet.Pilot.ProjectOnboard`) — séquence
      d'onboarding. CONTRAT = behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
    * `:pod_resolver` (défaut dispatch runtime `Fleet.Spawner.pod_info/1`) — résolution
      du rôle du pod.
    * `:delegation_org` (défaut `"fleet"`) — org forge des projets onboardés.
  """

  require Logger

  # Les deux behaviours-contrats des seams montants (fleet_mcp → fleet_pilot, dispatch runtime).
  # ⚠ Ce `ForgeClient` local est le CONTRAT (behaviour + resolver), PAS `Fleet.Pilot.ForgeClient`
  # (l'impl réelle, jamais référencée en appel direct ici — dep compile interdite).
  alias Fleet.MCP.PodTools.Delegation.{ForgeClient, ProjectOnboard}

  @doc """
  Pose une issue forge prête pour le poller — gate architecte incluse.

  Modèle forge-state-machine : auteur = compte de rôle de l'appelant (traça),
  **assignee = humain owner** (point fixe : routing + ownership) — et S'ARRÊTE. Le
  POLLER prend le relais (issue assignée non verrouillée → spawn le rôle producteur).
  Le ROUTAGE (graver la workflow_map) n'est PAS ici : c'est la responsabilité du
  SYSTÈME (le poller onboarde toute issue assignée routeless, cf.
  `StepDispatcher.ensure_workflow_map_or_onboard` côté fleet_pilot).

  Refus (fail-closed, rien n'est créé) : rôle non-architecte / pod inconnu (gate),
  `:role_token_unavailable` (token du compte de rôle absent = trou de provisioning —
  poster sous le compte système masquerait la traça et contournerait le
  least-privilege), `{:human_unresolved, _}` / `{:issue_creation_failed, _}` (forge).
  """
  @spec create_issue(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_issue(repo, title, brief, state)
      when is_binary(repo) and is_binary(title) and is_binary(brief) do
    forge = ForgeClient.resolved()

    # Déléguer un issue est un acte d'ARCHITECTE : gate AVANT toute mécanique. L'arch poste
    # ensuite l'issue EN SON NOM : token du compte de rôle de l'appelant.
    with {:ok, role} <- require_architect(state),
         token when is_binary(token) <- Fleet.Credentials.RoleToken.token(role) do
      do_create_issue(forge, repo, title, brief, token: token)
    else
      {:error, reason} ->
        # Rôle non-architecte, ou pod inconnu du registre → on ne crée RIEN.
        {:error, reason}

      _ ->
        # Pod prouvé mais token de rôle introuvable sur disque = trou de provisioning (le compte de rôle
        # n'a pas son token). On REFUSE plutôt que de poster sous le compte système (fail-closed) :
        # poster en système masquerait la traça (qui a délégué ?) et contournerait le least-privilege.
        Logger.warning(
          "Delegation: create_issue REFUSÉ : token du rôle appelant introuvable (provisioning incomplet) — " <>
            "pas de repli compte système"
        )

        {:error, :role_token_unavailable}
    end
  end

  @doc """
  Démarre un projet neuf (repo forge + dual-worktree `main`/`work/ops` + scaffold +
  push) — gate architecte appliquée AVANT toute création de repo ou écriture disque.

  Le SYSTÈME exécute la mécanique via le seam `:project_onboard` (défaut
  `Fleet.Pilot.ProjectOnboard`, dispatch runtime). Le repo créé est RENDU dans le
  résultat (`repo`/`delegation_target`) : l'arch le récupère et le passe explicitement
  à `create_issue`/`issue_status`. Aucune mémoire globale de « projet courant » — le
  repo voyage par argument.
  """
  @spec create_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_project(name, args, state) when is_binary(name) and is_map(args) do
    # Fail-closed : pas d'architecte = pas de projet.
    case require_architect(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_create_project(name, args)
    end
  end

  @doc """
  Lit l'état d'un issue délégué (issue + PR liée) — gate architecte (suivre une
  délégation reste réservé à l'architecte, cohérent avec `create_issue`/`create_project`).

  « Livré » = issue fermée par le merge (`Closes #N`) : signal de séquencement
  multi-issue (l'arch n'enchaîne le issue N+1 que sur `delivered: true`). Lecture seule
  (ForgeClient). Le repo est PASSÉ explicitement, JAMAIS lu d'une mémoire globale : un
  arch qui suit plusieurs projets en parallèle nomme CELUI qu'il interroge.
  """
  @spec issue_status(String.t(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def issue_status(repo, number, state) when is_binary(repo) and is_integer(number) do
    case require_architect(state) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _role} ->
        forge = ForgeClient.resolved()

        issue_state =
          case forge.get_issue(repo, number, []) do
            {:ok, issue} -> Map.get(issue, "state", "unknown")
            _ -> "unknown"
          end

        result = %{
          "repo" => repo,
          "issue" => number,
          "issue_state" => issue_state,
          # « livré » = la PR a fermé l'issue (merge FF `Closes #N`). Signal de séquencement multi-issue :
          # l'arch n'enchaîne le issue N+1 que sur `delivered: true`.
          #
          # ⚠ LIMITE CONNUE (F-RUN-3, vu live 2026-07-04) : `closed` SEUL confond « fermé par un merge »
          # (vraie livraison) et « fermé sans livraison » (marqueur d'onboarding `[lcars-onboarded]`,
          # fermeture manuelle) → faux `delivered:true`. Le fix CORRECT exige de prouver un MERGE (nouvelle
          # requête forge : PR mergée pour l'issue — `issue_pr_status` ne voit que les PR OUVERTES, nil au
          # merge). Différé au lot auditabilité. Le DÉCLENCHEUR est neutralisé par F-RUN-1 : create_issue
          # rend désormais le vrai numéro → l'arch ne DEVINE plus et n'interroge plus le marqueur par erreur.
          "delivered" => issue_state == "closed",
          "pr" => issue_pr_status(forge, repo, number)
        }

        {:ok, result}
    end
  end

  # ============================================================
  # Mécanique forge (exécutée UNIQUEMENT après la gate)
  # ============================================================

  # Séquence d'onboarding proprement dite. Le SYSTÈME exécute la mécanique (repo forge +
  # dual-worktree main/work-ops + scaffold + push) via le seam :project_onboard (contrat =
  # behaviour Delegation.ProjectOnboard ; défaut Fleet.Pilot.ProjectOnboard, dispatch runtime —
  # pas de dep compile-time fleet_pilot).
  defp do_create_project(name, args) do
    onboard = ProjectOnboard.resolved()
    org = Application.get_env(:fleet_mcp, :delegation_org, "fleet")
    pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

    opts = [org: org, description: Map.get(args, "description", pitch), pitch: pitch]

    case apply(onboard, :onboard, [name, opts]) do
      {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir}} ->
        {:ok,
         %{
           "status" => "onboarded",
           "repo" => repo,
           "project_dir" => pdir,
           "work_dir" => wdir,
           "delegation_target" => repo
         }}

      {:error, reason} ->
        {:error, {:onboard_failed, inspect(reason)}}
    end
  end

  # Pose l'issue (auteur = compte de rôle via `author_opts`, assignee = humain owner) et l'étiquette de visu.
  defp do_create_issue(forge, repo, title, brief, author_opts) do
    # assignee = l'HUMAIN owner (point fixe : routing + ownership, jamais le rôle). Login forge
    # = login OS de l'humain qui lance la fleet (doctrine : tout dérive de l'OS, pas de catalogue ;
    # Gitea matche l'assignee insensible à la casse → `starfleet` résout `Starfleet`). Pas de label :
    # le rôle producteur est un invariant côté poller, pas un sticker par-issue.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        case apply(forge, :create_issue, [repo, title, brief, issue_opts]) do
          {:ok, number} ->
            # DÉCOUPLAGE : create_issue CRÉE seulement (auteur=arch, assignee=humain). Le ROUTAGE
            # (graver la workflow_map) n'est PLUS ici : c'est la responsabilité du SYSTÈME — le POLLER grave
            # la workflow_map par défaut (brief-gate) sur toute issue assignée routeless (cf. fleet_pilot).
            # Un seul acteur crée+assigne ; le système route. (Uniforme : un issue humain routeless est
            # onboardé pareil.) type:feature = ÉTIQUETTE de visu (humain), best-effort — JAMAIS du routing.
            _ = apply(forge, :add_label, [repo, number, "type:feature", []])

            {:ok,
             %{
               "status" => "issue_created",
               "issue" => "#{repo}##{number}",
               "repo" => repo,
               "assignee" => human
             }}

          {:error, reason} ->
            {:error, {:issue_creation_failed, inspect(reason)}}
        end

      {:error, reason} ->
        {:error, {:human_unresolved, inspect(reason)}}
    end
  end

  # La PR EN COURS du issue #n (parmi les open). Livré (mergé) → la PR n'est plus open → `nil`
  # (l'info « livré » vient alors de l'issue close). Sinon : numéro + merged + verdicts de review.
  defp issue_pr_status(forge, repo, number) do
    # La PR du issue #n = celle dont le head est la feature-branch `lcars/issue-<n>-<role>`. Le parse
    # de ce format est délégué à l'AUTORITÉ UNIQUE `Fleet.Pilot.ForgeProtocol.parse_feature_branch/1`
    # (co-localisée avec son builder `feature_branch/2`) au lieu de reconstruire le préfixe en dur : un
    # changement de format se fait dans le seul ForgeProtocol. On l'atteint via le `forge` INJECTÉ (résolu
    # runtime, défaut `Fleet.Pilot.ForgeClient`, qui ré-exporte `parse_feature_branch` vers ForgeProtocol) —
    # donc aucune dep compile-time de fleet_mcp vers fleet_pilot (c'est pourquoi on garde l'appel via le seam
    # plutôt qu'un appel direct à ForgeProtocol, qui lui créerait cette dépendance).
    case forge.list_open_pulls(repo, []) do
      {:ok, pulls} ->
        Enum.find_value(pulls, fn pr ->
          head = get_in(pr, ["head", "ref"]) || ""

          case forge.parse_feature_branch(head) do
            {:ok, {^number, _role}} ->
              verdicts =
                case forge.pr_review_verdicts(repo, pr["number"],
                       head_sha: get_in(pr, ["head", "sha"])
                     ) do
                  {:ok, v} -> v
                  _ -> %{}
                end

              %{"number" => pr["number"], "merged" => pr["merged"], "verdicts" => verdicts}

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  # ============================================================
  # Gate architecte + résolution du rôle
  # ============================================================

  # Gate commune des trois tools : résout le rôle depuis l'identité du canal (`state.pod_id`)
  # PUIS exige `architect`. State sans pod_id = anomalie de l'accepteur → :pod_id_required
  # (fail-closed, jamais d'accès anonyme).
  defp require_architect(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_role(pod_id) do
      {:ok, "architect"} -> {:ok, "architect"}
      {:ok, _other_role} -> {:error, :forbidden_not_architect}
      {:error, _reason} = err -> err
    end
  end

  defp require_architect(_state), do: {:error, :pod_id_required}

  # Le RÔLE (architect / engineer / …) est gravé au SPAWN et lu depuis le registre du Spawner
  # (`Fleet.Spawner.pod_info`), jamais d'un champ du wire (qu'un pod pourrait forger). Seam test
  # `:pod_resolver` (app-env) : prend le pod_id et rend `{:ok, %{role: role}}` | `{:error, _}`.
  # Défaut = dispatch RUNTIME vers `Fleet.Spawner.pod_info/1` (pas de dep compile-time
  # fleet_spawner). Pod inconnu / Spawner indisponible → `:pod_unknown` (fail-closed).
  defp resolve_role(pod_id) when is_binary(pod_id) do
    resolver = Application.get_env(:fleet_mcp, :pod_resolver, &default_pod_resolver/1)

    case resolver.(pod_id) do
      {:ok, %{role: role}} -> {:ok, role}
      _ -> {:error, :pod_unknown}
    end
  end

  defp default_pod_resolver(pod_id) when is_binary(pod_id) do
    apply(Fleet.Spawner, :pod_info, [pod_id])
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end
end

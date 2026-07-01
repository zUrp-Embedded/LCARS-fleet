defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Couche TOOL MCP pod-facing (drive métier) — les RPC que le pod (client MCP
  claude) appelle pour communiquer avec le fleet, sans scraping ni injection clavier :
    - `get_task`      : canal IN  — le pod PULL son mandat depuis `Fleet.TaskQueue`.
      `{"done": true}` quand aucun mandat (le pod s'arrête). Sinon
      `{"done": false, "task": {"task_id", "ticket_id", "role", "brief", ...}}`.
    - `submit_result` : canal OUT — le pod PUSH son livrable (`payload`).

  Médiation serveur-side : le pod ne touche jamais la TaskQueue directement (la queue,
  son schéma, son stockage restent invisibles au pod) ; tout passe par ces tools. Le
  serveur est **passeur de `correlation_id`** : `task_id` exposé côté `get_task`,
  validé côté `submit_result` (le broker rejette un `task_id` ≠ mandat actif).

  Le broker `Fleet.TaskQueue` broadcast lui-même `%Fleet.Event{task_completed}` sur
  `fleet.events` (consommé par `fleet_spawner`/`fleet_coord`) — ce module n'émet
  plus d'event string-topic (`pod.result_submitted` supprimé).
  """

  use ExMCP.Server

  require Logger

  alias Fleet.TaskQueue

  deftool "get_task" do
    meta do
      name("Get Task")

      description(
        "Récupère ta prochaine tâche auprès du fleet LCARS. Retourne " <>
          "{\"done\":true} quand il n'y a plus de tâche (tu t'arrêtes alors), " <>
          "sinon {\"done\":false,\"task\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    meta do
      name("Submit Result")

      description(
        "Retourne le résultat structuré d'une tâche au fleet LCARS, dans `payload`. `task_id` REQUIS = " <>
          "le `task_id` rendu par `get_task` (la tâche que tu clôs) : le fleet corrèle ton livrable à CETTE " <>
          "tâche précise, jamais à « la dernière en date »."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "payload" => %{"type" => "object"},
        "task_id" => %{"type" => "string"}
      },
      "required" => ["payload", "task_id"]
    })
  end

  deftool "create_ticket" do
    meta do
      name("Create Ticket")

      description(
        "Délègue une brique d'implémentation à la fleet LCARS : crée un ticket (issue forge) prêt " <>
          "pour la livraison forge-native (engineer → PR → review → merge). Utilise-le pour DÉLÉGUER " <>
          "plutôt que de coder toi-même (la fleet livre mieux et préserve ton contexte). " <>
          "`brief` = le mandat clair pour l'engineer. `project` = le repo `owner/name` OÙ LIVRER, **REQUIS** : " <>
          "le repo retourné par `create_project`, ou le projet désigné par l'humain. La fleet ne route PLUS par " <>
          "défaut — sans `project`, le ticket est REFUSÉ (jamais de misroute silencieux vers un autre projet). " <>
          "Retourne {\"status\":\"ticket_created\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "project" => %{"type" => "string"}
      },
      "required" => ["title", "brief", "project"]
    })
  end

  deftool "create_project" do
    meta do
      name("Create Project")

      description(
        "Démarre un NOUVEAU projet : crée le repo sur la forge + les 2 dossiers dual-dir " <>
          "(`/home/projects/<name>` sur `main`, `/home/projects.work/<name>` sur `work/ops`) + " <>
          "le scaffold de base, et le pousse. Utilise-le quand l'humain veut LANCER un projet neuf. " <>
          "`name` = slug kebab-case. Retourne {\"status\":\"onboarded\",\"repo\":...} ; enchaîne ensuite " <>
          "`create_ticket` en lui passant `project: <le repo retourné>` pour livrer DANS ce projet."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "pitch" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      },
      "required" => ["name"]
    })
  end

  deftool "get_ticket_status" do
    meta do
      name("Get Ticket Status")

      description(
        "Consulte l'état d'un ticket délégué (issue + PR liée) : issue ouverte/fermée, PR mergée " <>
          "ou non, verdicts de review. Utilise-le pour SUIVRE un ticket avant d'enchaîner — ex. valider " <>
          "la livraison (issue fermée par le merge) du ticket N AVANT de poster le ticket N+1. " <>
          "`number` = le numéro d'issue. `project` = le repo `owner/name` DU ticket, **REQUIS** : le repo " <>
          "retourné par `create_project` (ou celui passé à `create_ticket`). La fleet ne route PLUS par " <>
          "défaut — sans `project`, la lecture est REFUSÉE (jamais d'état lu sur le mauvais projet). " <>
          "Retourne {\"delivered\":bool,\"issue_state\":...,\"pr\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "project" => %{"type" => "string"}
      },
      "required" => ["number", "project"]
    })
  end

  @impl true
  def handle_tool_call("get_task", _arguments, %{pod_id: pod_id} = state)
      when is_binary(pod_id) and pod_id != "" do
    # Identité = le canal : `pod_id` vient de l'accepteur de socket (un pod = une socket), jamais du wire.
    # On ne lit donc PAS d'identité dans les arguments — il n'y a rien à prouver, la socket discrimine.
    result =
      case TaskQueue.get_for_pod(pod_id) do
        {:ok, task} -> %{"done" => false, "task" => envelope(task)}
        {:error, :no_task} -> %{"done" => true}
      end

    {:ok, %{content: [json(result)]}, state}
  end

  def handle_tool_call("get_task", _arguments, state) do
    # `pod_id` absent du state = anomalie de l'accepteur (il DOIT toujours le porter). Erreur typée, pas une
    # fin de mandat masquée en done:true (sinon le pod s'arrêterait en croyant avoir fini). Fail-closed.
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, %{pod_id: pod_id} = state)
      when is_map(payload) and is_binary(pod_id) and pod_id != "" do
    # Identité = le canal (`state.pod_id`, porté par l'accepteur). Reste le `task_id` OBLIGATOIRE : il
    # corrèle le livrable à UN mandat précis (le broker rejette un task_id ≠ mandat actif du pod). C'est un
    # verrou orthogonal au transport — le pod doit nommer la tâche qu'il clôt, sans quoi le broker tomberait
    # sur « la dernière active » du pod. Le corrélateur est cherché au top-level (format canonique) PUIS
    # dans le payload (un agent juge le range parfois dans son payload de verdict). Absent des DEUX → refus.
    case effective_task_id(args, payload) do
      nil ->
        {:error, :task_id_required, state}

      task_id ->
        # Le broker valide pod_id ↔ task_id et broadcast %Fleet.Event{task_completed}.
        case TaskQueue.submit_result(pod_id, Map.put(payload, "task_id", task_id)) do
          {:ok, _task} ->
            {:ok, %{content: [text("Resultat recu par le fleet. Tache close.")]}, state}

          {:error, :no_active_task} ->
            # pas de mandat actif = le livrable n'a NULLE PART où aller (jamais assigné, ou clos/
            # réassigné depuis) → DROP. Le signaler isError (comme :task_id_mismatch / :pod_id_required)
            # plutôt que masquer en {:ok "ok"} : sinon le pod croit son livrable accepté (échec masqué
            # en succès). (≠ :double_submit_ignored, qui reste :ok — idempotent, le 1er submit EST enregistré.)
            {:error, :no_active_task, state}

          {:error, :double_submit_ignored} ->
            {:ok, %{content: [text("Resultat deja recu (ignore).")]}, state}

          {:error, :task_id_mismatch} ->
            {:error, :task_id_mismatch, state}

          # le broadcast lifecycle `task_completed` a échoué : le hop ne finira PAS (le HopConsumer
          # n'a rien reçu). NE PAS rendre `{:ok, "Tache close."}` (faux succès) — le pod doit
          # voir un échec (isError) → il peut re-soumettre (le broadcast sera ré-émis), au lieu de croire
          # son livrable accepté alors que le verrou forge reste posé à vie.
          {:error, {:broadcast_failed, _reason}} ->
            {:error, :broadcast_failed, state}
        end
    end
  end

  def handle_tool_call("submit_result", %{"payload" => payload}, state) when is_map(payload) do
    # Payload valide mais `pod_id` absent du state = anomalie de l'accepteur → refus typé, jamais de
    # fallback anonyme (un livrable sans pod identifié n'a nulle part où aller).
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # create_ticket — canal DÉLÉGATION : l'architecte délègue une brique d'implémentation à la fleet.
  # Modèle forge-state-machine : pose une issue PRÊTE pour le poller — auteur=arch (traça),
  # **assignee=humain owner** (point fixe : routing + ownership) — et S'ARRÊTE. Plus de
  # `start_pipeline` (rail RAM retiré). Le POLLER prend le relais : issue assignée non verrouillée →
  # spawn le rôle PRODUCTEUR (`:producer_role`, invariant — pas de marqueur par-ticket : un label
  # `lcars-stage:` ré-encoderait une constante). Dispatch runtime via modules-en-variable (pas de dep compile-time pilot).
  def handle_tool_call(
        "create_ticket",
        %{"title" => title, "brief" => brief, "project" => repo},
        state
      )
      when is_binary(title) and is_binary(brief) and is_binary(repo) and repo != "" do
    forge = Application.get_env(:fleet_mcp, :forge_client, Fleet.Pilot.ForgeClient)

    # Déléguer un ticket est un acte d'ARCHITECTE : `require_architect` résout le rôle depuis l'identité du
    # canal (`state.pod_id`, porté par l'accepteur de socket) PUIS exige que ce rôle gravé au spawn soit
    # `architect`. Un pod worker (engineer, reviewer) ou inconnu est REFUSÉ ICI, serveur-side. Le rôle vient
    # du spawn (résolu par pod_id), JAMAIS d'un champ du wire. L'arch poste ensuite l'issue EN SON NOM :
    # token du compte de rôle de l'appelant.
    with {:ok, role} <- require_architect(state),
         token when is_binary(token) <- Fleet.Credentials.RoleToken.token(role) do
      do_create_ticket(forge, repo, title, brief, [token: token], state)
    else
      {:error, reason} ->
        # Rôle non-architecte, ou pod inconnu du registre → on ne crée RIEN.
        {:error, reason, state}

      _ ->
        # Pod prouvé mais token de rôle introuvable sur disque = trou de provisioning (le compte de rôle
        # n'a pas son token). On REFUSE plutôt que de poster sous le compte système (fail-closed) :
        # poster en système masquerait la traça (qui a délégué ?) et contournerait le least-privilege.
        Logger.warning(
          "create_ticket REFUSÉ : token du rôle appelant introuvable (provisioning incomplet) — " <>
            "pas de repli compte système"
        )

        {:error, :role_token_unavailable, state}
    end
  end

  # create_ticket SANS `project` valide → REFUS STRUCTUREL. La bonne volonté ne s'impose pas : pas de routage
  # par défaut (un `project` omis routait en silence vers le dernier projet travaillé → misroute). `project`
  # est REQUIS ; sans lui, AUCUN ticket n'est créé.
  def handle_tool_call("create_ticket", %{"title" => title, "brief" => brief}, state)
      when is_binary(title) and is_binary(brief) do
    {:error,
     {:project_required,
      "create_ticket REFUSÉ — `project` est REQUIS (le repo `owner/name` où livrer). Aucun routage par " <>
        "défaut. Passe `project` = le repo retourné par create_project, ou le projet désigné par l'humain."},
     state}
  end

  def handle_tool_call("create_ticket", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # create_project — canal ONBOARDING : l'architecte démarre un projet neuf. La gate architecte est
  # appliquée AVANT toute mécanique (cf. require_architect ci-dessous) ; do_create_project porte la séquence.
  def handle_tool_call("create_project", %{"name" => name} = args, state) when is_binary(name) do
    # Onboarder un projet CRÉE un repo forge ET écrit/pousse dans `/home/projects` : un acte d'ARCHITECTE.
    # `require_architect` résout le rôle depuis l'identité du canal (`state.pod_id`) PUIS exige le rôle
    # `architect` gravé au spawn. Un pod worker (engineer) ou inconnu est REFUSÉ ici, serveur-side, AVANT
    # toute création de repo ou écriture disque. Fail-closed : pas d'architecte = pas de projet.
    case require_architect(state) do
      {:error, reason} ->
        {:error, reason, state}

      {:ok, _role} ->
        do_create_project(name, args, state)
    end
  end

  def handle_tool_call("create_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # get_ticket_status — canal SUIVI (architecte). Lit l'état d'un ticket délégué pour séquencer le
  # multi-ticket. « Livré » = issue fermée par le merge (`Closes #N`). Lecture seule (ForgeClient).
  # Le repo est PASSÉ explicitement (`project` = owner/name du ticket), JAMAIS lu d'une mémoire globale :
  # un arch qui suit plusieurs projets en parallèle nomme CELUI qu'il interroge. Sinon le « dernier projet
  # onboardé » servirait l'état du mauvais repo (issue_state/delivered faux → multi-ticket mis-séquencé).
  # Suivre l'état d'un ticket délégué reste réservé à l'architecte (cohérent avec create_ticket /
  # create_project) : `require_architect` résout le rôle depuis l'identité du canal et exige `architect`.
  def handle_tool_call(
        "get_ticket_status",
        %{"number" => number, "project" => repo},
        state
      )
      when is_integer(number) and is_binary(repo) and repo != "" do
    case require_architect(state) do
      {:error, reason} ->
        {:error, reason, state}

      {:ok, _role} ->
        forge = Application.get_env(:fleet_mcp, :forge_client, Fleet.Pilot.ForgeClient)

        issue_state =
          case forge.get_issue(repo, number, []) do
            {:ok, issue} -> Map.get(issue, "state", "unknown")
            _ -> "unknown"
          end

        result = %{
          "repo" => repo,
          "issue" => number,
          "issue_state" => issue_state,
          # « livré » = la PR a fermé l'issue (merge FF `Closes #N`). Signal de séquencement multi-ticket :
          # l'arch n'enchaîne le ticket N+1 que sur `delivered: true`.
          "delivered" => issue_state == "closed",
          "pr" => ticket_pr_status(forge, repo, number)
        }

        {:ok, %{content: [json(result)]}, state}
    end
  end

  # get_ticket_status SANS `project` valide → REFUS STRUCTUREL (miroir de create_ticket). Pas de routage
  # par défaut : un `project` omis lirait l'état sur le dernier projet onboardé → état faux, le multi-ticket
  # est mis-séquencé. `project` est REQUIS ; sans lui (ou vide), AUCUNE lecture.
  def handle_tool_call("get_ticket_status", %{"number" => number}, state)
      when is_integer(number) do
    {:error,
     {:project_required,
      "get_ticket_status REFUSÉ — `project` est REQUIS (le repo `owner/name` du ticket). Aucun routage " <>
        "par défaut. Passe `project` = le repo retourné par create_project, ou celui passé à create_ticket."},
     state}
  end

  def handle_tool_call("get_ticket_status", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # Séquence d'onboarding proprement dite, exécutée UNIQUEMENT après la gate architecte. Le SYSTÈME exécute
  # la mécanique (repo forge + dual-worktree main/work-ops + scaffold + push) via Fleet.Pilot.ProjectOnboard,
  # dispatch runtime (pas de dep compile-time fleet_pilot). Le repo créé est RENDU dans le `result`
  # (`repo`/`delegation_target`) : l'arch le récupère et le passe explicitement à `create_ticket` /
  # `get_ticket_status`. Aucune mémoire globale de « projet courant » — le repo voyage par argument.
  defp do_create_project(name, args, state) do
    # Seam `:project_onboard` (app-env, comme `:forge_client`/`:pod_resolver`) — défaut = la vraie séquence
    # `Fleet.Pilot.ProjectOnboard` (dispatch runtime, pas de dep compile-time fleet_pilot), overridable en test.
    onboard = Application.get_env(:fleet_mcp, :project_onboard, Fleet.Pilot.ProjectOnboard)
    org = Application.get_env(:fleet_mcp, :delegation_org, "fleet")
    pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

    opts = [org: org, description: Map.get(args, "description", pitch), pitch: pitch]

    case apply(onboard, :onboard, [name, opts]) do
      {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir}} ->
        result = %{
          "status" => "onboarded",
          "repo" => repo,
          "project_dir" => pdir,
          "work_dir" => wdir,
          "delegation_target" => repo
        }

        {:ok, %{content: [json(result)]}, state}

      {:error, reason} ->
        {:error, {:onboard_failed, inspect(reason)}, state}
    end
  end

  # Pose l'issue (auteur = compte de rôle via `author_opts`, assignee = humain owner) et l'étiquette de visu.
  # Extrait de create_ticket pour garder le handler centré sur la GATE (require_architect + token).
  defp do_create_ticket(forge, repo, title, brief, author_opts, state) do
    # assignee = l'HUMAIN owner (point fixe : routing + ownership, jamais le rôle). Login forge
    # = login OS de l'humain qui lance la fleet (doctrine : tout dérive de l'OS, pas de catalogue ;
    # Gitea matche l'assignee insensible à la casse → `starfleet` résout `Starfleet`). Pas de label :
    # le rôle producteur est un invariant côté poller, pas un sticker par-ticket.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        case apply(forge, :create_issue, [repo, title, brief, issue_opts]) do
          {:ok, number} ->
            # DÉCOUPLAGE : create_ticket CRÉE seulement (auteur=arch, assignee=humain). Le ROUTAGE
            # (graver la carte) n'est PLUS ici : c'est la responsabilité du SYSTÈME — le POLLER grave la carte
            # par défaut (mandate-gate) sur toute issue assignée routeless (cf. fleet_pilot). Un seul acteur
            # crée+assigne ; le système route. (Uniforme : un ticket humain routeless est onboardé pareil.)
            # type:feature = ÉTIQUETTE de visu (humain), best-effort — JAMAIS du routing.
            _ = apply(forge, :add_label, [repo, number, "type:feature", []])

            result = %{
              "status" => "ticket_created",
              "ticket" => "#{repo}##{number}",
              "repo" => repo,
              "assignee" => human
            }

            {:ok, %{content: [json(result)]}, state}

          {:error, reason} ->
            {:error, {:ticket_creation_failed, inspect(reason)}, state}
        end

      {:error, reason} ->
        {:error, {:human_unresolved, inspect(reason)}, state}
    end
  end

  # Pas de `delegation_carte` ni de `grave_initial_route` ici : le routage (graver la carte) vit
  # côté système (fleet_pilot : le poller onboarde toute issue assignée routeless sur la carte par défaut,
  # cf. StageDispatcher.ensure_carte_or_onboard). create_ticket ne fait QUE créer+assigner.

  # La PR EN COURS du ticket #n (parmi les open). Livré (mergé) → la PR n'est plus open → `nil`
  # (l'info « livré » vient alors de l'issue close). Sinon : numéro + merged + verdicts de review.
  defp ticket_pr_status(forge, repo, number) do
    # La PR du ticket #n = celle dont le head est la feature-branch `lcars/issue-<n>-<role>`. Le parse
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
  # Autorisation architecte — gate commune des tools privilégiés
  # ============================================================
  #
  # `create_project`, `create_ticket` et `get_ticket_status` sont des actes d'ARCHITECTE : créer un repo
  # forge, écrire/pousser dans `/home/projects`, déléguer du travail, suivre une délégation. La barrière
  # est serveur-side : `require_architect` résout le rôle depuis l'identité du CANAL (`state.pod_id`, porté
  # par l'accepteur de socket — pas de champ du wire) PUIS exige que ce rôle gravé au spawn soit `architect`.
  # Un pod worker (engineer, reviewer), un rôle nil/inconnu ou un pod absent du registre → REFUS. Fail-closed
  # de bout en bout : aucun cas ne retombe sur un accès autorisé. (Le filtre de visibilité côté pont reste
  # une commodité UX — ne pas montrer un tool inutilisable — mais l'autorisation vit ICI.)
  defp require_architect(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_role(pod_id) do
      {:ok, "architect"} -> {:ok, "architect"}
      {:ok, _other_role} -> {:error, :forbidden_not_architect}
      {:error, _reason} = err -> err
    end
  end

  defp require_architect(_state), do: {:error, :pod_id_required}

  # ============================================================
  # Rôle du pod — résolu depuis le pod_id du CANAL, jamais cru sur le wire
  # ============================================================
  #
  # L'identité (quel pod) est le canal lui-même : `state.pod_id` est porté par l'accepteur de socket (un pod
  # = une socket montée dans son seul sandbox), donc il n'y a plus rien à prouver — pas de capability, pas de
  # pod_id lu sur le fil. Reste à résoudre le RÔLE (architect / engineer / …) pour gater les tools privilégiés :
  # il est gravé au SPAWN et lu depuis le registre du Spawner (`Fleet.Spawner.pod_info`), jamais d'un champ
  # du wire (qu'un pod pourrait forger). Seam test `:pod_resolver` (app-env) : prend le pod_id et rend
  # `{:ok, %{role: role}}` | `{:error, _}`. Défaut = dispatch RUNTIME vers `Fleet.Spawner.pod_info/1` (pas de
  # dep compile-time fleet_spawner). Pod inconnu / Spawner indisponible → `:pod_unknown` (fail-closed).
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

  # Le `task_id` (corrélateur) cherché au top-level du wire PUIS dans le payload : un agent juge range
  # parfois le corrélateur DANS son payload de verdict plutôt qu'au paramètre top-level. Renvoie le task_id
  # non vide trouvé (top-level prioritaire), ou nil si absent des deux. Le broker corrèle ensuite sur
  # `result["task_id"]` et rejette (`:task_id_mismatch`) s'il ne correspond pas à SON mandat actif → un pod
  # ne peut pas clôturer la tâche d'un autre (verrou orthogonal au transport). L'emplacement (top-level vs
  # payload) n'entre PAS dans la sécurité : le task_id reste explicite et validé ; seul le fallback
  # « dernière active » (implicite) était le trou.
  defp effective_task_id(args, payload) do
    present_task_id(Map.get(args, "task_id") || Map.get(args, :task_id)) ||
      present_task_id(Map.get(payload, "task_id") || Map.get(payload, :task_id))
  end

  defp present_task_id(tid) when is_binary(tid) and tid != "", do: tid
  defp present_task_id(_), do: nil

  # JSON envelope du mandat exposé au pod — task_id = correlation_id.
  defp envelope(%Fleet.TaskQueue.Task{} = t) do
    %{
      "task_id" => t.id,
      "ticket_id" => t.ticket_id,
      "role" => t.role,
      "brief" => t.brief,
      "deadline" => iso(t.deadline),
      "retry_count" => t.retry_count
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end

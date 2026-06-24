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
        "Consulte l'état d'un ticket délégué (issue + PR liée) du projet de délégation courant : " <>
          "issue ouverte/fermée, PR mergée ou non, verdicts de review. Utilise-le pour SUIVRE un " <>
          "ticket avant d'enchaîner — ex. valider la livraison (issue fermée par le merge) du ticket N " <>
          "AVANT de poster le ticket N+1. `number` = le numéro d'issue. " <>
          "Retourne {\"delivered\":bool,\"issue_state\":...,\"pr\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{"number" => %{"type" => "integer"}},
      "required" => ["number"]
    })
  end

  @impl true
  def handle_tool_call("get_task", arguments, state) do
    # Identité PROUVÉE avant tout : le pod_id est devinable, donc on n'y touche QU'APRÈS avoir vérifié
    # que le wire présente la capability enregistrée pour ce pod (anti-usurpation). Capability absente /
    # fausse / pod inconnu → REFUS net, jamais un fallback anonyme (le pod ne lirait pas le mandat d'un autre).
    case verify_pod(arguments) do
      {:error, reason} ->
        {:error, reason, state}

      {:ok, pid, _role} ->
        result =
          case TaskQueue.get_for_pod(pid) do
            {:ok, task} -> %{"done" => false, "task" => envelope(task)}
            {:error, :no_task} -> %{"done" => true}
          end

        {:ok, %{content: [json(result)]}, state}
    end
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, state)
      when is_map(payload) do
    # `task_id` OBLIGATOIRE (plus de « tâche active la plus récente » sur un pod_id non prouvé) ET
    # identité prouvée par capability. Les deux ferment l'impersonation : un pod ne peut clôturer la tâche
    # d'un autre ni en présentant son pod_id (capability), ni en omettant le task_id (corrélation explicite).
    case verify_pod(args) do
      {:error, reason} ->
        {:error, reason, state}

      {:ok, _pid, _role}
      when not is_map_key(args, "task_id") and not is_map_key(args, :task_id) ->
        # Le pod DOIT nommer la tâche qu'il clôt. Sans task_id, le broker tomberait sur « la dernière
        # active de ce pod_id » — exactement le levier d'impersonation à supprimer. On exige le corrélateur
        # explicite, et le broker (ci-dessous) vérifie qu'il appartient bien au pod prouvé.
        {:error, :task_id_required, state}

      {:ok, pid, _role} ->
        # Le broker valide pod_id ↔ task_id (présent par construction ici) et broadcast %Fleet.Event{task_completed}.
        case TaskQueue.submit_result(pid, payload_with_task_id(args, payload)) do
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
        %{"title" => title, "brief" => brief, "project" => repo} = args,
        state
      )
      when is_binary(title) and is_binary(brief) and is_binary(repo) and repo != "" do
    forge = Application.get_env(:fleet_mcp, :forge_client, Fleet.Pilot.ForgeClient)

    # Déléguer un ticket est un acte d'ARCHITECTE : `require_architect` prouve l'identité (capability
    # par-pod, comme tout tool corrélé pod) PUIS exige que le rôle gravé au spawn soit `architect`. Un pod
    # worker (engineer, reviewer) ou inconnu est REFUSÉ ICI, serveur-side — la seule barrière n'est plus la
    # visibilité côté pont (un pod qui reconstruit le JSON-RPC contournait le filtre client). Le rôle vient
    # du spawn vérifié, JAMAIS du `_lcars_role` du wire (non authentifié → un pod pourrait prétendre
    # architect). L'arch poste ensuite l'issue EN SON NOM : token du compte de rôle de l'appelant.
    with {:ok, _pid, role} <- require_architect(args),
         token when is_binary(token) <- Fleet.Credentials.RoleToken.token(role) do
      do_create_ticket(forge, repo, title, brief, [token: token], state)
    else
      {:error, reason} ->
        # Identité non prouvée (capability manquante/fausse, pod inconnu) ou rôle non-architecte → on ne
        # crée RIEN.
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
    # `require_architect` prouve l'identité (capability par-pod) PUIS exige le rôle `architect` gravé au
    # spawn. Un pod worker (engineer) ou inconnu qui joindrait le MCP central — même en reconstruisant le
    # JSON-RPC, sans passer par le filtre de visibilité du pont — est REFUSÉ ici, serveur-side, AVANT toute
    # création de repo ou écriture disque. Fail-closed : pas d'architecte prouvé = pas de projet.
    case require_architect(args) do
      {:error, reason} ->
        {:error, reason, state}

      {:ok, _pid, _role} ->
        do_create_project(name, args, state)
    end
  end

  def handle_tool_call("create_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # get_ticket_status — canal SUIVI (architecte). Lit l'état d'un ticket délégué pour séquencer le
  # multi-ticket. « Livré » = issue fermée par le merge (`Closes #N`). Lecture seule (ForgeClient).
  # Suivre l'état d'un ticket délégué reste réservé à l'architecte (cohérent avec create_ticket /
  # create_project) : `require_architect` exige l'identité prouvée ET le rôle architect avant toute lecture.
  def handle_tool_call("get_ticket_status", %{"number" => number} = args, state)
      when is_integer(number) do
    case require_architect(args) do
      {:error, reason} ->
        {:error, reason, state}

      {:ok, _pid, _role} ->
        repo = Application.get_env(:fleet_mcp, :delegation_repo, "fleet/fleet-test")
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

  def handle_tool_call("get_ticket_status", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # Séquence d'onboarding proprement dite, exécutée UNIQUEMENT après la gate architecte. Le SYSTÈME exécute
  # la mécanique (repo forge + dual-worktree main/work-ops + scaffold + push) via Fleet.Pilot.ProjectOnboard,
  # dispatch runtime (pas de dep compile-time fleet_pilot). Le projet créé est posé comme `:delegation_repo`
  # = contexte/fallback (lu par get_ticket_status). L'arch référence le projet en passant `project:` explicite.
  defp do_create_project(name, args, state) do
    # Seam `:project_onboard` (app-env, comme `:forge_client`/`:pod_resolver`) — défaut = la vraie séquence
    # `Fleet.Pilot.ProjectOnboard` (dispatch runtime, pas de dep compile-time fleet_pilot), overridable en test.
    onboard = Application.get_env(:fleet_mcp, :project_onboard, Fleet.Pilot.ProjectOnboard)
    org = Application.get_env(:fleet_mcp, :delegation_org, "fleet")
    pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

    opts = [org: org, description: Map.get(args, "description", pitch), pitch: pitch]

    case apply(onboard, :onboard, [name, opts]) do
      {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir}} ->
        Application.put_env(:fleet_mcp, :delegation_repo, repo)

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
  # Extrait de create_ticket pour garder le handler centré sur la GATE d'identité (verify_pod + token).
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
    # Feature-branch du ticket = `lcars/issue-<n>-<role>` ; le `-` final distingue #1 de #12. Match
    # inline (pas de call cross-app vers fleet_pilot : fleet_mcp dispatch le forge en runtime).
    prefix = "lcars/issue-#{number}-"

    case forge.list_open_pulls(repo, []) do
      {:ok, pulls} ->
        Enum.find_value(pulls, fn pr ->
          head = get_in(pr, ["head", "ref"]) || ""

          if String.starts_with?(head, prefix) do
            verdicts =
              case forge.pr_review_verdicts(repo, pr["number"],
                     head_sha: get_in(pr, ["head", "sha"])
                   ) do
                {:ok, v} -> v
                _ -> %{}
              end

            %{"number" => pr["number"], "merged" => pr["merged"], "verdicts" => verdicts}
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
  # forge, écrire/pousser dans `/home/projects`, déléguer du travail, suivre une délégation. Avant ce garde,
  # la seule barrière était la VISIBILITÉ côté pont (`fleet_mcp_stdio_bridge.py` ne liste ces tools que si
  # `LCARS_ROLE==architect`) — ce n'est PAS une autorisation : un pod worker qui a Bash + joint le central
  # en loopback peut reconstruire le JSON-RPC et appeler ces tools directement, hors filtre client.
  #
  # `require_architect` ferme ce trou serveur-side : il enveloppe `verify_pod` (identité prouvée par la
  # capability par-pod) PUIS exige que le rôle gravé au spawn soit `architect`. Le rôle vient du pod
  # VÉRIFIÉ, jamais du `_lcars_role` du wire (non authentifié → un pod pourrait prétendre architect).
  # Tout rôle autre (engineer, reviewer, rôle nil/inconnu) → `{:error, :forbidden_not_architect}`. Une
  # identité non prouvée propage l'erreur de `verify_pod` telle quelle (capability absente/fausse, pod
  # inconnu). Fail-closed de bout en bout : aucun cas ne retombe sur un accès autorisé.
  defp require_architect(args) do
    case verify_pod(args) do
      {:ok, pid, "architect"} -> {:ok, pid, "architect"}
      {:ok, _pid, _other_role} -> {:error, :forbidden_not_architect}
      {:error, _reason} = err -> err
    end
  end

  # ============================================================
  # Identité du pod — prouvée par capability, JAMAIS crue sur le wire
  # ============================================================
  #
  # Le pont stdio injecte `_lcars_pod_id` (qui pod) ET `_lcars_pod_capability` (le secret par-pod
  # généré au spawn). Le serveur ne croit PAS le pod_id seul — il est déterministe et devinable : un pod
  # (qui a Bash + joint le central en loopback) pourrait POST le pod_id d'un autre pour lire son mandat ou
  # clôturer sa tâche. La capability ferme ce trou : seul le pod LÉGITIME la connaît (elle ne vit que dans
  # SON env), et le central la VÉRIFIE contre celle enregistrée au spawn (`Fleet.Spawner.pod_info`) avant
  # de servir tout tool corrélé pod. Le rôle se résout sur ce MÊME pod prouvé (même appel = pas de drift).
  #
  # Retours :
  #   - `{:ok, pod_id, role}` — capability présentée == capability enregistrée pour ce pod_id ;
  #   - `{:error, :pod_id_required}`      — pas de pod_id sur le wire (anomalie de config du pont) ;
  #   - `{:error, :pod_capability_required}` — pas de capability sur le wire (pont sans secret = refus) ;
  #   - `{:error, :pod_unknown}`          — pod_id inconnu du registre serveur (jamais spawné, ou mort) ;
  #   - `{:error, :pod_capability_mismatch}` — capability fausse (impersonation : pod_id d'un autre).
  #
  # Fail-closed de bout en bout : aucun de ces cas ne retombe sur un accès anonyme ou un token système.
  defp verify_pod(args) do
    args = args || %{}

    with {:ok, pid} <- extract_pod_id(args),
         {:ok, cap} <- extract_capability(args),
         {:ok, %{role: role, capability: registered}} <- resolve_pod(pid),
         true <- secure_compare(cap, registered) do
      {:ok, pid, role}
    else
      {:error, _} = err -> err
      # `resolve_pod` a rendu un pod sans capability enregistrée, ou la comparaison a échoué.
      :pod_unknown -> {:error, :pod_unknown}
      false -> {:error, :pod_capability_mismatch}
    end
  end

  defp extract_pod_id(args) do
    case Map.get(args, "_lcars_pod_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :pod_id_required}
    end
  end

  defp extract_capability(args) do
    case Map.get(args, "_lcars_pod_capability") do
      cap when is_binary(cap) and cap != "" -> {:ok, cap}
      _ -> {:error, :pod_capability_required}
    end
  end

  # Résout `pod_id → %{role, capability}` depuis le registre du Spawner (gravé au spawn). Seam test
  # `:pod_resolver` (app-env) qui prend le pod_id et rend `{:ok, %{role, capability}}` | `{:error, _}` ;
  # défaut = dispatch RUNTIME vers `Fleet.Spawner.pod_info/1` (pas de dep compile-time fleet_spawner, comme
  # `Fleet.Pilot.ProjectOnboard`). Pod inconnu / Spawner indisponible → `:pod_unknown` (fail-closed).
  defp resolve_pod(pod_id) when is_binary(pod_id) do
    resolver = Application.get_env(:fleet_mcp, :pod_resolver, &default_pod_resolver/1)

    case resolver.(pod_id) do
      {:ok, %{capability: cap} = info} when is_binary(cap) and cap != "" ->
        {:ok, %{role: Map.get(info, :role), capability: cap}}

      _ ->
        :pod_unknown
    end
  end

  defp default_pod_resolver(pod_id) when is_binary(pod_id) do
    apply(Fleet.Spawner, :pod_info, [pod_id])
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end

  # Comparaison à temps constant (la capability est un secret) : on ne veut pas qu'un timing observable
  # révèle la longueur du préfixe commun (qui permettrait de deviner la capability octet par octet). Tailles
  # différentes → false immédiat (la taille n'est pas secrète). Tailles égales → XOR octet-à-octet puis
  # OR cumulé : le temps ne dépend QUE de la longueur, jamais du contenu. Implémentation autonome
  # (`:crypto.exor`, toujours dispo en OTP 25) — pas de dép sur `Plug.Crypto` que fleet_mcp ne déclare pas.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and constant_time_equal?(a, b)
  end

  defp secure_compare(_, _), do: false

  defp constant_time_equal?(a, b) do
    :crypto.exor(a, b)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &Bitwise.bor/2) == 0
  end

  # Fusionne le `task_id` (argument top-level REQUIS du wire) dans le map résultat envoyé au broker,
  # qui corrèle sur `result["task_id"]`. Le pod a obtenu ce task_id de `get_task` ; le broker rejette
  # (`:task_id_mismatch`) s'il ne correspond pas à SON mandat actif → un pod ne peut pas clôturer la
  # tâche d'un autre même en ayant passé la gate capability (double verrou : capability + corrélateur).
  defp payload_with_task_id(args, payload) do
    case Map.get(args, "task_id") || Map.get(args, :task_id) do
      tid when is_binary(tid) and tid != "" -> Map.put(payload, "task_id", tid)
      _ -> payload
    end
  end

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

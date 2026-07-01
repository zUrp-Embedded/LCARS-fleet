defmodule Fleet.Spawner.Pod.Scaffold do
  @moduledoc """
  PRÉPARATION du substrat disque d'un pod (le « scaffold ») — île extraite de `Fleet.Spawner.Pod`.

  Tout ce qui POSE le contenu du pod_dir AVANT le launch : assets (`settings.json`, draft SP,
  protocole-user, `watch.sh`), brief (`tickets/<id>.md`), enqueue du brief dans la `TaskQueue`,
  bootstrap du workspace projet (clone) et restauration du seed de recall. Le `Pod` lui passe le
  `state` (ou le `cap_profile`) en argument ; le module ne rappelle AUCUN private de `Pod` (pas de
  cycle).

  Ce module N'ORCHESTRE PAS : les PHASES `do_clean`/`do_project` restent au cœur du `Pod` (leur gros
  `with` est l'orchestrateur). Le scaffold n'expose que les ÉTAPES — chacune rend `:ok`/`{:ok, _}` ou
  un `{:error, reason}` taggé que le `with` de `do_project` propage vers `transition_failed` (cleanup
  clean : phase=failed + state.json écrit).

  ## Contrat (appelé par `Pod`)

  - `gc_stale_session_jsonl(state)` — appelé par `do_clean` (GC de l'UUID de session avant un re-spawn
    `--session-id`).
  - `pod_settings_json/0`, `read_agent_draft(cap_profile)`, `read_protocole_user/0`,
    `maybe_path(path)`, `maybe_filter_skills(cap_profile, root)`, `issue_id_to_filename(issue_id)`,
    `default_brief(state)`, `maybe_enqueue_brief(state)`, `provision_monitor_watch(state)`,
    `maybe_bootstrap_project_workspace(state)`, `maybe_recall_restore(state)` — étapes appelées dans la
    `with` de `do_project`.

  Dépend de `Pod.Fs` (écritures FS non-bang), `Pod.LaunchSpec` (cwd/projet effectif), `Pod.TaskProbe`
  (gate d'enqueue), `Fleet.SPBuilder` (filtre des skills) ; et en pleine qualif `Fleet.CapProfile`
  (source unique du `name`), `Fleet.ProjectBootstrap.Phase.Clone` (clone workspace + doc),
  `Fleet.Spawner.SeedStore` (restore recall), `Fleet.TaskQueue` (enqueue), `Fleet.Slug` (validation du
  rôle interpolé), `Application` (config + assets `priv/`). Aucune dépendance vers `Fleet.Spawner.Pod`.
  """

  require Logger

  alias Fleet.Spawner.Pod.Fs
  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.TaskProbe

  # Supprime tout `<session_id>.jsonl` résiduel sous le pod_dir (tous cwd-slugs) → libère l'UUID pour
  # `--session-id`. Best-effort : un échec ne casse pas le spawn.
  def gc_stale_session_jsonl(state) do
    [state.pod_dir, ".claude", "projects", "*", "#{state.session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(fn f ->
      _ = File.rm(f)

      Logger.info(
        "Pod.gc #{state.pod_id}: jsonl stale #{Path.basename(f)} retiré (GC UUID → session frais)"
      )
    end)
  end

  # settings.json minimal pour le claude REPL du pod.
  #
  # `skipDangerousModePermissionPrompt: true` — pré-accepte le warning
  # interactif que claude affiche au premier boot sous
  # `--dangerously-skip-permissions`. Sans cette clé, le pod tmux session
  # se fige sur "By proceeding, you accept..." (option 1/2 + Enter).
  # Pattern repris du consultant LCARS v1 (`/home/consultant/.claude/
  # settings.json`).
  #
  # `hasCompletedOnboarding: true` — skip aussi l'onboarding step. Le
  # `.claude.json` legacy n'a pas vocation à être touché ici (config
  # globale du user host).
  def pod_settings_json do
    Jason.encode!(
      %{
        "hasCompletedOnboarding" => true,
        "hasAcknowledgedCostThreshold" => true,
        "skipDangerousModePermissionPrompt" => true
      },
      pretty: true
    )
  end

  # SP draft minimal — déclare le rôle agent worker + workflow yop →
  # get_work_item → submit_result + convention de retour (ok|failed). Le SP
  # final par rôle est un chantier séparé.
  # Draft SP role-aware : le draft d'un rôle est `agent-<role>-base.md` s'il
  # EXISTE, sinon le draft worker générique. Convention catalogue (le draft suit le `metadata.name`),
  # plus de rôle gravé en `case` : l'architecte tombe sur son draft délégateur (qualité+économie +
  # create_issue), tout rôle sans draft dédié sur le draft worker (get_work_item/submit_result). `role`
  # est interpolé dans un path (`agent-<role>-base.md`) → validé via le smart-constructor slug
  # (source unique du charset path-safe ; un `role` malformé retombe juste sur le draft par défaut).
  def read_agent_draft(%Fleet.CapProfile{} = cap) do
    role = Fleet.CapProfile.name(cap)
    default = "priv/sp_drafts/agent-worker-base.md"

    file =
      if Fleet.Slug.valid?(role) do
        candidate = "priv/sp_drafts/agent-#{role}-base.md"

        if File.exists?(Application.app_dir(:fleet_sp_builder, candidate)),
          do: candidate,
          else: default
      else
        default
      end

    path = Application.app_dir(:fleet_sp_builder, file)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:agent_draft_missing, path, reason}}
    end
  end

  # protocole-user.md (mots-clés personnalisés `yop`/`SeeU`).
  #
  # Default = `priv/sp_drafts/protocole-user-worker.md` shippé avec
  # fleet_sp_builder : version WORKER (yop = trigger workflow issue-driven,
  # SeeU = no-op). Override par config `:fleet_spawner, :protocole_user_path`
  # si besoin (instance utilisateur custom).
  #
  # PIÈGE évité : pointer sur le protocole-user d'une instance humaine
  # (ex. `/home/starfleet/sp-sources/user/protocole-user.md`) qui définit
  # `yop` comme "reprise de session lire handoff" ou neutralisé (instance
  # v1 éclatée) → le claude REPL du pod ne déclenche PAS le workflow worker.
  # (Piège réellement rencontré sur une instance dont le protocole-user redéfinissait `yop`.)
  def read_protocole_user do
    case Application.get_env(:fleet_spawner, :protocole_user_path) do
      nil ->
        path = Application.app_dir(:fleet_sp_builder, "priv/sp_drafts/protocole-user-worker.md")

        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:protocole_user_worker_missing, path, reason}}
        end

      path when is_binary(path) ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:protocole_user_missing, path, reason}}
        end
    end
  end

  def maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  def maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  def maybe_filter_skills(cap_profile, root) do
    Fleet.SPBuilder.filter_skills(cap_profile, root)
  end

  # Brief du pod = sa TÂCHE (livrée par l'orchestrateur, modèle PUSH).
  # Le travail vient de `opts[:brief]` (le rail forge-driven construit le brief via
  # `Pilot.BriefBuilder.build_brief` ; ou pod direct via `Fleet.Spawner.spawn_pod` opts).
  #
  # Ton naturel (pas multi-section formalisée "## Tâche / ## Livrable") : claude REPL en
  # mode interactif peut interpréter un format trop structuré comme tentative de prompt
  # injection et refuser. Le contexte fleet (convention submit_result) est posé en
  # préambule conversationnel, pas comme directive impérative ("EXACTEMENT ce payload",
  # "appelle ce tool", etc.).
  # Convertit issue_id (peut contenir `/`, `#`, etc. — ex.
  # "fleet/lcars#600" depuis Gitea) en filename safe (sans `/` qui
  # créerait des sous-dirs). Convention : remplace `/` par `_` et
  # garde `#` (lisible humain).
  def issue_id_to_filename(issue_id) when is_binary(issue_id) do
    String.replace(issue_id, "/", "_")
  end

  def default_brief(state) do
    brief = Keyword.get(state.opts || [], :brief)
    # Interpoler le RÔLE résolu, ne pas hardcoder "engineer". Un gatekeeper (juge) sans
    # brief explicite ne doit PAS être amorcé "worker engineer" (un mauvais priming de persona).
    # Cadre neutre "pod LCARS (rôle X)" — le brief (GateBrief pour le juge) porte la persona réelle.
    role = Fleet.CapProfile.name(state.cap_profile)

    body =
      if is_binary(brief) and brief != "" do
        brief
      else
        "(Pas de brief fourni — issue #{state.issue_id}.)"
      end

    """
    Salut. Tu es un pod LCARS (rôle #{role}, pod #{state.pod_id}) ; cette session
    a été lancée par le fleet pour traiter une demande référencée issue #{state.issue_id}.

    Le fleet attend que tu utilises le tool MCP `submit_result` quand ton travail est
    terminé — c'est la convention LCARS, le canal de retour structuré équivalent d'un
    Slack DM signed-off. Pas besoin d'écrire de fichier toi-même.

    Voici la demande :

    #{body}
    """
  end

  # Enqueue le brief dans la TaskQueue (le canal CANONIQUE `get_work_item`), idempotent :
  #   - pas de brief (pod permanent/interactif booté à froid) → rien à puller → bootstrap (skip) ;
  #   - brief DÉJÀ en file (`pod_status != {:ok, nil}` : dispatch stage, StageDispatcher a enqueué AVANT
  #     le spawn) → pas de double-enqueue (skip) ;
  #   - sinon (`admin.spawn` / `lcars spawn --brief` : aucun dispatcher) → on enqueue ici, sinon
  #     `get_work_item` rend `{done:true}` et le pod reste idle (cf. StageDispatcher.enqueue_brief).
  # Mirror des `attrs` de StageDispatcher (`issue_id`/`role`/`brief`/`metadata`).
  def maybe_enqueue_brief(state) do
    brief = Keyword.get(state.opts || [], :brief)

    cond do
      not (is_binary(brief) and brief != "") ->
        :ok

      not TaskProbe.no_pending_brief?(state.pod_id) ->
        :ok

      true ->
        attrs = %{
          issue_id: state.issue_id,
          role: Fleet.CapProfile.name(state.cap_profile),
          brief: brief,
          metadata: %{"source" => "admin.spawn"}
        }

        case Fleet.TaskQueue.enqueue(state.pod_id, attrs) do
          {:ok, _task} -> :ok
          {:error, reason} -> {:error, {:brief_enqueue_failed, reason}}
        end
    end
  end

  # Câblage de Fleet.ProjectBootstrap.Phase.Clone pour les pods porteurs d'un projet
  # (`repo_path`) : le projet EFFECTIF vient du BRIEF (effective_project : opts[:project]
  # injecté par le dispatch issue->repo) ou du cap_profile statique (pods permanents). Présent :
  # clone le repo dans `<pod_dir>/workspace/` + checkout feature branch ; le cwd du REPL pointe sur
  # ce workspace (maybe_put_pod_cwd -> LCARS_POD_CWD) → l'agent code DANS sa branche (pas dans le
  # pod_dir nu, et le clone est idempotent au respawn).
  #
  # Découplage architectural : c'est `pod.ex` qui câble `ProjectBootstrap` pour les pods
  # avec projet (workspace per-pod). (Le provisioning de workspace per-stage du moteur RAM
  # `Pipeline.WorkspaceProvisioner` est supprimé ; le rail forge-driven épingle la base au clone.)
  # 2 sites callers d'un même mécanisme, paramétré par cap-profile. Le projet EFFECTIF
  # (brief > statique) est résolu par `LaunchSpec.effective_project/2` (source unique).
  def maybe_bootstrap_project_workspace(state) do
    project = LaunchSpec.effective_project(state.opts, state.cap_profile)

    case project["repo_path"] do
      nil ->
        :ok

      _repo_path ->
        # cap_profile porteur du projet EFFECTIF (brief > statique) pour les Clone.* (qui lisent spec.project).
        eff_cap = %{state.cap_profile | spec: Map.put(state.cap_profile.spec, "project", project)}

        with {:ok, workspace, branch} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(
                 state.pod_dir,
                 eff_cap,
                 []
               ),
             # Doc-mount (mundo invocado) : la branche `work/ops` (plans/backlog/conventions) à côté
             # du code. nil si le projet n'a pas de branche doc ; fail-loud si déclarée mais absente.
             {:ok, doc} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_work_doc(
                 state.pod_dir,
                 eff_cap
               ) do
          # CLAUDE.md composé (pod-identité + conventions repo) à la racine du CWD (workspace) :
          # l'agent pop dans un projet déjà documenté. Le do_project l'écrit au pod_dir (parent) ;
          # avec cwd=workspace il doit être DANS le cwd (sinon l'agent code sans sa codebase-doc en cwd).
          _ = File.cp(Path.join(state.pod_dir, "CLAUDE.md"), Path.join(workspace, "CLAUDE.md"))

          # Identité git du rôle : pas de `git config` mutable dans le workspace (falsifiable — le pod
          # pourrait l'écraser). L'identité est injectée en env IMMUABLE-par-défaut au lancement
          # (bwrap_launch.sh : GIT_AUTHOR_*/GIT_COMMITTER_* = LCARS-<role> + GIT_CONFIG_GLOBAL
          # /dev/null). La garantie vit côté monde : la gate DeliverableGate rejette au push tout
          # commit hors identité autorisée.

          Logger.info(
            "pod #{state.pod_id} workspace=#{workspace} (branch=#{branch || "default"})" <>
              if(doc, do: " doc=#{doc}", else: " (pas de branche doc)")
          )

          :ok
        else
          {:error, reason} -> {:error, {:project_workspace_clone_failed, reason}}
        end
    end
  end

  # Provisionne le monitor in-pod (`watch.sh`) dans le pod_dir (= HOME bwrap). L'agent
  # l'arme via l'outil natif `Monitor` (cf. SP `agent-worker-base.md`) → réveil-par-flag
  # (`turn.flag` touché par la fleet), zéro send-keys de CONTENU (send-keys =
  # kick `yop` + slash-commands uniquement). L'asset vit en `priv/` (résolu app_dir, comme le SP
  # draft). chmod best-effort : l'agent lance `bash ~/watch.sh`, le bit exec n'est pas requis.
  def provision_monitor_watch(state) do
    src = Application.app_dir(:fleet_spawner, "priv/watch.sh")
    dst = Path.join(state.pod_dir, "watch.sh")

    case File.read(src) do
      {:ok, content} ->
        with :ok <- Fs.safe_write(dst, content) do
          _ = File.chmod(dst, 0o755)
          :ok
        end

      {:error, reason} ->
        {:error, {:watch_asset_unreadable, reason}}
    end
  end

  # Recall délibéré. Si `opts[:recall_seed_jsonl]` est fourni (par `Fleet.Spawner.recall`),
  # restaure le seed à `projects/<slugify(cwd)>/<session_id>.jsonl` AVANT le launch ; claude
  # `--resume <session_id>` (resume:true via opts) le retrouve. Gaté : absent → no-op (spawn normal
  # intact). Le seed est validé (read_map) côté `Spawner.recall` ; absent ICI = fail-loud (transition_failed).
  def maybe_recall_restore(state) do
    case Keyword.get(state.opts, :recall_seed_jsonl) do
      nil ->
        :ok

      jsonl when is_binary(jsonl) ->
        if File.exists?(jsonl) do
          {:ok, _} =
            Fleet.Spawner.SeedStore.restore(
              jsonl,
              state.pod_dir,
              LaunchSpec.pod_cwd(state.opts, state.cap_profile, state.pod_dir),
              state.session_id
            )

          :ok
        else
          {:error, {:recall_seed_missing, jsonl}}
        end
    end
  end
end

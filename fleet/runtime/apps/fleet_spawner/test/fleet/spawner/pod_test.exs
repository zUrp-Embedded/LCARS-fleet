defmodule Fleet.Spawner.PodTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.LaunchBackend.StubBackend

  # G24-9 (F-CONT-RISK) — disallowedTools minimum exigé par Fleet.CapProfile.validate/1
  # (câblée au spawn, Z2 ; cf. cap_profile.ex @disallowed_minimum_strict/_prefix). Tout
  # profil spawné DOIT les porter, sinon la gate le rejette (:cap_profile_invalid).
  @min_disallowed ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution tool_search_web)

  # repo_id de test pour les rôles PROJECT-BOUND (engineer = défaut `valid_profile/0`, et tout dérivé).
  # Leur session_id hexspeak EXIGE un repo résolu : sans lui, le mint REFUSE (raise) au lieu de fabriquer
  # un UUID random — l'absence de repo signale une forge qui n'a pas résolu l'id (forge down). En prod le
  # repo vient du dispatcher ; ces tests spawnent le pod en direct, donc on pose ce repo neutre dans `opts`
  # pour exercer le lifecycle. Valeur arbitraire (≠ des id hexspeak codés en dur ailleurs dans ce fichier).
  @test_repo_id 7

  @moduletag :tmp_dir

  # MA-04 — bus stub : `broadcast/2` LÈVE (simule UnregisteredError / PubSub down). Le Pod
  # `required_broadcast` doit rescue → `{:error, {:broadcast_failed, _}}` → `do_extract` NE release/kill PAS
  # le pod sur une complétion orpheline.
  defmodule RaiseBus do
    def broadcast(_topic, _ev),
      do: raise(Fleet.Event.UnregisteredError, "forced pod.completed fail")
  end

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
    # adr-f : plus de coffre. Les creds viennent du claudeDir bindé par bwrap
    # (CLAUDE_DIR, défaut config) ; pas de setup coffre en test.

    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# Engineer SP base")
    Application.put_env(:fleet_sp_builder, :sp_role_root, sp_root)

    # mundo invocado #1 : auth = mode bind unique (token_arg retiré 2026-06-14). Le gate credentials
    # (scope/plan) lit toujours le creds natif → fixture creds par défaut pour les tests qui ne testent
    # pas la porte credentials ; les tests credentials/fail-loud overrident :claude_dir per-test.
    setup_claude = Path.join(tmp_dir, ".claude")
    File.mkdir_p!(setup_claude)

    File.write!(
      Path.join(setup_claude, ".credentials.json"),
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-setup-tok",
          "expiresAt" => 99_999_999_999_999,
          "refreshToken" => "rt",
          "scopes" => ["user:inference", "user:sessions:claude_code"],
          "subscriptionType" => "max"
        }
      })
    )

    Application.put_env(:fleet_spawner, :claude_dir, setup_claude)

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      Application.delete_env(:fleet_sp_builder, :sp_role_root)
      Application.delete_env(:fleet_spawner, :claude_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "kick_keyword/2 (#5.2 — mot-clé du kick selon l'ACK)" do
    test "pas encore pollé → 'yop' (bootstrap-arm, JAMAIS gaté)" do
      assert Fleet.Spawner.Pod.Kick.kick_keyword(false, true) == "yop"
      assert Fleet.Spawner.Pod.Kick.kick_keyword(false, false) == "yop"
    end

    test "déjà pollé + knob on → 'wake' (fallback)" do
      assert Fleet.Spawner.Pod.Kick.kick_keyword(true, true) == "wake"
    end

    test "déjà pollé + knob off → nil (flag-only, pas de send-keys)" do
      assert Fleet.Spawner.Pod.Kick.kick_keyword(true, false) == nil
    end
  end

  describe "acked?/3 (#5.2 F3 — le contrôle de la boucle = l'ACK, pas un proxy)" do
    test "wake : pull du brief = ACK (peu importe polled)" do
      assert Fleet.Spawner.Pod.Kick.acked?(true, false, false)
      assert Fleet.Spawner.Pod.Kick.acked?(true, false, true)
    end

    test "bootstrap : poll = ACK (pas de brief à puller, last_poll suffit)" do
      assert Fleet.Spawner.Pod.Kick.acked?(false, true, true)
    end

    test "bootstrap pas encore pollé → PAS d'ACK (on continue à kicker 'yop')" do
      refute Fleet.Spawner.Pod.Kick.acked?(false, true, false)
    end

    test "worker pas encore pull → PAS d'ACK même si pollé (polled ne compte QUE pour bootstrap)" do
      refute Fleet.Spawner.Pod.Kick.acked?(false, false, true)
    end
  end

  defp valid_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      # role_index/protected/fleet_level : le catalogue rôle vit dans le metadata (source du QUOI),
      # lu par deterministic_session_id. engineer = slot 3, worker (1badcafe), project-bound (repo exigé).
      metadata: %{
        "name" => "engineer",
        "containment" => "bwrap",
        "role_index" => 3,
        "protected" => false,
        "fleet_level" => false
      },
      spec: %{
        "lifetime_scope" => "one-shot",
        "systemPrompt" => "engineer-role.md",
        "scope" => %{"disallowedTools" => @min_disallowed, "git_ops_denied" => []},
        "knowledge" => %{"skills" => []},
        "invocation" => %{"lifetime_scope" => "one-shot", "max_alive_sec" => 60},
        "injects" => %{},
        "modop_set" => []
      }
    }
  end

  defp spawn_via_supervisor(args) do
    StubBackend.set_parent(self())
    Fleet.Spawner.Pod.start_link(args)
  end

  defp build_args(pod_id, issue_id) do
    # engineer = project-bound → repo_id obligatoire pour minter son session_id déterministe.
    %{
      cap_profile: valid_profile(),
      issue_id: issue_id,
      pod_id: pod_id,
      opts: [repo_id: @test_repo_id]
    }
  end

  # Repo source pour les tests projet : `main` (src.txt) + branche orpheline `work/ops` (BACKLOG.md).
  defp source_repo_with_doc(dir) do
    File.mkdir_p!(dir)
    g = fn args -> System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    {_, 0} = g.(["config", "user.email", "t@lcars.local"])
    {_, 0} = g.(["config", "user.name", "test"])
    File.write!(Path.join(dir, "src.txt"), "code")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-q", "-m", "code"])
    {_, 0} = g.(["checkout", "-q", "--orphan", "work/ops"])
    {_, _} = g.(["rm", "-rfq", "."])
    File.write!(Path.join(dir, "BACKLOG.md"), "doc")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-q", "-m", "doc"])
    {_, 0} = g.(["checkout", "-q", "main"])
    dir
  end

  # Modèle interactif : le backend ouvre le Port et retourne immédiatement (pas de frame NDJSON).
  defp interactive_reply(opts \\ []) do
    {:ok,
     %{
       port: Keyword.get(opts, :port),
       session_id: Keyword.get(opts, :session_id, "stub-sess")
     }}
  end

  # R-CORE.comm ADR-G — completion event-driven : simule le broker fleet_task_queue broadcastant
  # %Fleet.Event{work_item_completed} sur fleet.events (= ce qui arrive quand l'agent appelle
  # submit_result via fleet_mcp). Le pod doit être en :monitoring (subscribed) avant l'appel.
  defp submit_result_event(pod_id, payload) do
    Phoenix.PubSub.broadcast(
      Fleet.PubSub,
      "fleet.events",
      Fleet.Event.new(:task_queue, :work_item_completed,
        pod_id: pod_id,
        correlation_id: "test-corr-#{pod_id}",
        payload: %{result: payload}
      )
    )
  end

  defp state_fs_path(pod_id, scope_dir \\ "pods") do
    root = Application.get_env(:fleet_spawner, :state_fs_root)
    Path.join([root, scope_dir, pod_id, "state.json"])
  end

  defp os_alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  setup do
    case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "happy path interactif (event résultat → stop)" do
    test "pod.result_submitted reçu → extract → release → arrêt :normal" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply(session_id: "s-happy"))

      pod_id = "pod-happy-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      # adr-f : plus d'OAuth env injecté ; le pod reçoit CLAUDE_DIR (claudeDir
      # humain) que bwrap_launch.sh bind en ~/.claude.
      assert env["CLAUDE_DIR"] =~ ".claude"

      # Barrière : pod en :monitoring ⇒ do_monitor a tourné ⇒ subscribed au Bus.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # Le central (fleet_mcp) broadcaste le résultat du pod → extract → release → {:stop, :normal}.
      submit_result_event(pod_id, %{"answer" => "OK"})

      assert_receive {:EXIT, ^pid, :normal}, 3_000

      # state.json écrit en RELEASE avec phase :succeeded.
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["phase"] == "succeeded"
    end

    # MA-04 — LE finding : `pod.completed` est LIFECYCLE load-bearing (le StepRunConsumer en dépend pour finir
    # le step_run). Si sa diffusion ÉCHOUE, le pod NE doit PAS release/kill sur une complétion orpheline (sinon
    # le pod « réussit » mais le step_run ne finit jamais → verrou forge à vie). Bus stub qui lève → le pod RESTE
    # vivant en :monitoring (résultat retenu, deadline ré-armée), PAS d'EXIT :normal.
    test "MA-04 : broadcast pod.completed qui échoue → pod PAS release/kill (reste vivant), fail-loud" do
      Process.flag(:trap_exit, true)
      Application.put_env(:fleet_spawner, :event_bus, RaiseBus)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :event_bus) end)

      StubBackend.set_reply(interactive_reply(session_id: "s-ma04"))
      pod_id = "pod-ma04-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, _env}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # Le central broadcaste le résultat → extract → pod.completed (qui ÉCHOUE via RaiseBus).
      submit_result_event(pod_id, %{"answer" => "OK"})

      # LE finding : PAS d'EXIT :normal (le one-shot ne release PAS sur une complétion non diffusée).
      refute_receive {:EXIT, ^pid, :normal}, 800

      # Le pod RESTE vivant en :monitoring (fail-loud : le re-wake re-fire l'extract).
      assert Process.alive?(pid)
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE : le pod ADOPTE le issue_id de la TACHE -> le livrable suit la BONNE brique (pas celle du spawn)" do
      # Regression hello-buddy : le pipe gardait son issue_id de SPAWN (issue-4) pour TOUS ses livrables ->
      # la 2e brique (issue-3) partait sur la branche/PR de issue-4 (ecrasement). Ici le pod spawn sur
      # "issue-4" mais la tache complétée porte "issue-3" -> le pod.completed (consomme par le StepRunConsumer
      # qui pousse HEAD:lcars/issue-N) doit porter "issue-3", la brique reellement traitee.
      Process.flag(:trap_exit, true)
      Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
      StubBackend.set_reply(interactive_reply(session_id: "s-adopt"))
      pod_id = "pod-adopt-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-4"))
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # work_item_completed pour la brique issue-3 (re-brief), PAS le spawn issue-4 (issue_id dans le payload,
      # comme le vrai event TaskQueue qui porte completed.issue_id).
      Phoenix.PubSub.broadcast(
        Fleet.PubSub,
        "fleet.events",
        Fleet.Event.new(:task_queue, :work_item_completed,
          pod_id: pod_id,
          correlation_id: "c-adopt",
          payload: %{result: %{"answer" => "OK"}, issue_id: "issue-3"}
        )
      )

      # Le pod.completed (= le livrable broadcaste au StepRunConsumer) porte le issue ADOPTE issue-3.
      assert_receive %Fleet.Event{
                       type: :"pod.completed",
                       payload: %{"issue_id" => "issue-3"}
                     },
                     3_000
    end

    test "POD_DIR + artefacts créés (pod en MONITORING tant que pas de livrable)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-dir-#{System.unique_integer([:positive])}"
      # PAS de livrable → le pod reste en :monitoring (poll), GenServer vivant.
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, _env}, 2_000

      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert File.dir?(info.pod_dir)
      assert File.exists?(Path.join(info.pod_dir, ".cap-profile.json"))

      # P1/C9 — `.claude/` pod-owned : cible du bind creds-only (bwrap bind UNIQUEMENT
      # .credentials.json dedans, plus le dir humain entier). Doit exister, créé par do_project.
      assert File.dir?(Path.join(info.pod_dir, ".claude")),
             "pod_dir/.claude doit exister (cible pod-owned du bind .credentials.json)"

      # Aucun settings.json humain ne doit fuiter (userSettings = .claude/settings.json absent
      # → 0 hook chargé ; getAllHooks ignore --setting-sources, cf JOURNAL-P1-hooks).
      refute File.exists?(Path.join(info.pod_dir, ".claude/settings.json")),
             ".claude/settings.json ne doit PAS exister (sinon des hooks chargeraient)"

      # Provisioning du reste HORS .claude/ : .lcars/ + racine pod pour CLAUDE.md.
      assert File.exists?(Path.join(info.pod_dir, ".lcars/system-prompt.md"))
      assert File.exists?(Path.join(info.pod_dir, "CLAUDE.md"))
      assert File.exists?(Path.join(info.pod_dir, ".lcars/protocole-user.md"))
      # Issue-driven (pivot doctrine) : le brief vit dans tickets/<issue_id>.md
      # (pas context/brief.md). Claude le lit comme contenu projet.
      assert File.exists?(Path.join(info.pod_dir, "tickets/issue-1.md"))

      # Monitor in-pod (réveil-par-flag, ADR-G) : watch.sh provisionné au pod_dir,
      # exécutable. L'agent l'arme via l'outil Monitor (cf. SP).
      watch = Path.join(info.pod_dir, "watch.sh")
      assert File.exists?(watch)
      assert File.read!(watch) =~ "ton tour"
      %File.Stat{mode: mode} = File.stat!(watch)
      assert Bitwise.band(mode, 0o100) != 0, "watch.sh doit être exécutable (owner)"

      # SP enrichi par agent-worker-base draft : doit contenir le workflow
      # yop → get_work_item → submit_result + le protocole Monitor (réveil-par-flag).
      sp = File.read!(Path.join(info.pod_dir, ".lcars/system-prompt.md"))
      assert sp =~ "agent worker LCARS"
      assert sp =~ "submit_result"
      assert sp =~ "yop"
      assert sp =~ "Monitor"
      assert sp =~ "watch.sh"

      Process.exit(pid, :kill)
    end

    test "PUSH — le travail (opts[:brief]) est livré dans tickets/<issue_id>.md" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-brief-#{System.unique_integer([:positive])}"
      brief = "Compile le module X et retourne le nombre de warnings."

      args = %{
        cap_profile: valid_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [brief: brief, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      info = GenServer.call(pid, :info)
      # Issue-driven : le brief est dans tickets/<issue_id>.md, pas en prompt
      # canal-user (safety guardrail REPL).
      issue = File.read!(Path.join(info.pod_dir, "tickets/issue-1.md"))
      # F128 : cadre neutre + rôle interpolé (plus de priming "worker engineer").
      assert issue =~ "pod LCARS (rôle engineer"
      assert issue =~ brief
      assert issue =~ "submit_result"

      Process.exit(pid, :kill)
    end

    test "PUSH — admin.spawn (opts[:brief], aucun dispatcher) enqueue le brief dans la TaskQueue (canal get_work_item) [F-arch-MCP]" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-mq-#{System.unique_integer([:positive])}"
      brief = "Crée le projet poc-run-5 puis délègue digit_sum."
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      args = %{
        cap_profile: valid_profile(),
        issue_id: "issue-mq",
        pod_id: pod_id,
        opts: [brief: brief, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      # Sans cet enqueue, `get_work_item` rendait `{done:true}` → le pod (qui poll get_work_item) restait idle
      # (forensic arch 3f12edd9). Le brief est désormais dans le canal canonique.
      assert [%{brief: ^brief}] =
               Enum.filter(Fleet.TaskQueue.list_pending(), &(&1.pod_id == pod_id))

      Process.exit(pid, :kill)
    end

    test "PUSH — pas de double-enqueue si un brief est DÉJÀ en file (dispatch stage : enqueué avant le spawn) [F-arch-MCP]" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-mq2-#{System.unique_integer([:positive])}"
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      # Simule le dispatch stage : le brief role-aware est enqueué AVANT le spawn (StageDispatcher).
      {:ok, _} =
        Fleet.TaskQueue.enqueue(pod_id, %{brief: "brief-du-dispatcher", role: "engineer"})

      args = %{
        cap_profile: valid_profile(),
        issue_id: "issue-mq2",
        pod_id: pod_id,
        opts: [brief: "autre-brief", repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      # Idempotent : un SEUL brief en file, celui du dispatcher (pas "autre-brief") — le spawn n'a pas
      # ré-enqueué (garde `no_pending_brief?`).
      assert [%{brief: "brief-du-dispatcher"}] =
               Enum.filter(Fleet.TaskQueue.list_pending(), &(&1.pod_id == pod_id))

      Process.exit(pid, :kill)
    end

    test "git_ops_denied (cap-profile) fusionné dans disallowedTools du .cap-profile.json écrit au pod" do
      # Face 1 décision archi git (2026-05-24) : la sémantique catalogue
      # git_ops_denied doit aboutir en patterns claude CLI disallowedTools dans
      # le .cap-profile.json écouté par claude_launch.sh — ligne morte → ligne
      # enforced par le mécanisme générique cap_profile→claude CLI.
      StubBackend.set_reply(interactive_reply())

      profile = valid_profile()

      profile =
        put_in(profile.spec["scope"], %{
          "disallowedTools" => @min_disallowed,
          "git_ops_denied" => ["push --force", "reset --hard"]
        })

      pod_id = "pod-gitops-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: profile,
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      info = GenServer.call(pid, :info)
      written = File.read!(Path.join(info.pod_dir, ".cap-profile.json")) |> Jason.decode!()
      disallowed = get_in(written, ["spec", "scope", "disallowedTools"])

      assert "web_search" in disallowed
      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git reset --hard:*)" in disallowed

      Process.exit(pid, :kill)
    end

    test "state.json écrit après launch (point de recovery, session_id PRÉ-ALLOUÉ)" do
      # session_id pré-alloué au spawn (DN §A) : passé via opts (le caller l'alloue, comme pod_id).
      # Le backend ne le capture PLUS (modèle -p mort) — l'état fait foi, persisté tel quel.
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-state-#{System.unique_integer([:positive])}"
      args = build_args(pod_id, "issue-1") |> Map.put(:opts, session_id: "sess-xyz")
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000
      # Barrière de sync : :launch_called est émis PENDANT launch_backend.launch, avant que
      # do_launch ne fasse write_state_fs. GenServer.call est traité après la chaîne handle_continue.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # state.json écrit en LAUNCH (avant MONITOR) → présent même sans livrable.
      # BL-021 chantier 4 : schéma C-3 complet (v, session_id, cap_profile_name,
      # started_at, phase, conditions, issue_id). `pod_id` n'est PLUS persisté
      # (la clé de recovery = path /var/lib/lcars/<scope>/<pod_id>/state.json).
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["v"] == 1
      assert content["issue_id"] == "issue-1"
      assert content["session_id"] == "sess-xyz"
      assert is_binary(content["cap_profile_name"])
      assert is_binary(content["started_at"])
      assert is_list(content["conditions"])
      assert content["phase"] in ["launching", "monitoring"]

      Process.exit(pid, :kill)
    end
  end

  describe "BL-055 — session_id déterministe au spawn (Fleet.Spawner.SessionId)" do
    setup do
      StubBackend.set_reply(interactive_reply())
      :ok
    end

    defp gatekeeper_args(pod_id, opts \\ []) do
      # gatekeeper = slot 2, worker (1badcafe), fleet-level (repo 0000) — catalogue dans le metadata.
      gk = %{
        valid_profile()
        | metadata: %{
            "name" => "gatekeeper",
            "containment" => "bwrap",
            "role_index" => 2,
            "protected" => false,
            "fleet_level" => true
          }
      }

      %{cap_profile: gk, issue_id: "issue-1", pod_id: pod_id, opts: opts}
    end

    test "rôle fleet-level (gatekeeper) → session_id hexspeak déterministe 1badcafe-...02" do
      pod_id = "pod-gk-det-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(gatekeeper_args(pod_id))
      assert_receive {:launch_called, _args, _env}, 2_000

      # barrière sync (state.json écrit en LAUNCH, après :launch_called) — cf. test state.json
      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["session_id"] == "1badcafe-feed-4dad-babe-0000dec0de02"
    end

    test "opts[:session_id] explicite PRIME (ex. arch boot-from-base sur 0badcafe)" do
      pod_id = "pod-explicit-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(
          gatekeeper_args(pod_id, session_id: "0badcafe-feed-4dad-babe-0000dec0de01")
        )

      assert_receive {:launch_called, _args, _env}, 2_000
      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["session_id"] == "0badcafe-feed-4dad-babe-0000dec0de01"
    end

    test "project-bound (engineer) SANS repo_id → spawn REFUSÉ (identité inconstructible, forge non résolue)" do
      # engineer = project-bound : son session_id hexspeak EXIGE un repo résolu. SANS repo (la forge n'a
      # pas rendu l'id — forge down / amont cassé), le mint REFUSE plutôt que de fabriquer un UUID random :
      # un random masquerait la forge absente et poserait une identité NON reconstructible. Le pod ne
      # démarre donc PAS — init/1 raise → start_link rend {:error, {%ArgumentError{}, _stacktrace}}, aucun
      # launch. (Le stop propre côté dispatch est en amont ; ici on fail-loud au mint, dernier recours.)
      Process.flag(:trap_exit, true)
      pod_id = "pod-eng-norepo-#{System.unique_integer([:positive])}"

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               spawn_via_supervisor(%{
                 cap_profile: valid_profile(),
                 issue_id: "issue-1",
                 pod_id: pod_id,
                 opts: []
               })

      assert msg =~ "project-bound"
      assert msg =~ "sans repo_id"
      refute_received {:launch_called, _args, _env}
    end

    test "project-bound (engineer) AVEC repo_id → hexspeak déterministe (repo DÉCIMAL encodé)" do
      pod_id = "pod-eng-repo-#{System.unique_integer([:positive])}"
      args = build_args(pod_id, "issue-1") |> Map.put(:opts, repo_id: 161)
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000
      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["session_id"] == "1badcafe-feed-4dad-babe-0161dec0de03"
    end

    test "GC d'UUID : un <uuid>.jsonl stale (pod_dir survivant d'un crash) est retiré avant --session-id",
         %{tmp_dir: tmp_dir} do
      pod_id = "pod-gc-#{System.unique_integer([:positive])}"
      uuid = "1badcafe-feed-4dad-babe-0000dec0de02"

      # simule un pod_dir survivant (teardown raté) : le jsonl de l'UUID déterministe traîne déjà.
      stale =
        Path.join([
          tmp_dir,
          "pods",
          "pod_#{pod_id}",
          ".claude",
          "projects",
          "-home-x",
          "#{uuid}.jsonl"
        ])

      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "{}\n")
      assert File.exists?(stale)

      {:ok, pid} = spawn_via_supervisor(gatekeeper_args(pod_id))
      assert_receive {:launch_called, _args, _env}, 2_000
      GenServer.call(pid, :info)

      refute File.exists?(stale), "le jsonl stale aurait dû être GC'd avant le --session-id"
    end
  end

  describe "#kill-yolo — LCARS_PERMISSION_MODE (--permission-mode vs --dangerously-skip)" do
    setup do
      StubBackend.set_reply(interactive_reply())
      :ok
    end

    test "défaut = 'default' (claude_launch → --permission-mode default, listes enforced)" do
      pod_id = "pod-perm-#{System.unique_integer([:positive])}"
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_PERMISSION_MODE"] == "default"
    end

    test "cap-profile spec.invocation.permission_mode override le défaut" do
      pod_id = "pod-perm-ovr-#{System.unique_integer([:positive])}"
      cp = valid_profile()
      inv = Map.put(cp.spec["invocation"] || %{}, "permission_mode", "bypassPermissions")
      cp = %{cp | spec: Map.put(cp.spec, "invocation", inv)}

      args = %{
        cap_profile: cp,
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, _pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_PERMISSION_MODE"] == "bypassPermissions"
    end
  end

  describe "LAUNCH-Q — branche containment (host_launch vs bwrap) sur le chemin de lancement" do
    # Le gap : avant le fix, `do_launch` bwrappait TOUT (containment jamais lu). Ici on prouve que le
    # launcher N0 passé au backend (`args.launcher_path`) ET le HOME suivent `metadata.containment`.
    defp host_profile, do: put_in(valid_profile().metadata["containment"], "none")

    test "containment: none → launcher host_launch.sh + HOME = home réel de l'humain (auth native)",
         %{
           tmp_dir: tmp_dir
         } do
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-host-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: host_profile(),
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:launch_called, args, env}, 2_000
      assert String.ends_with?(args.launcher_path, "host_launch.sh")

      # HOME = parent du claudeDir humain (= override config :claude_dir = <tmp_dir>/.claude) → tmp_dir.
      # claude lit ainsi le ~/.claude humain natif (refresh OAuth, pas de falaise 8h — arch forever).
      assert env["HOME"] == tmp_dir
      Process.exit(pid, :kill)
    end

    test "containment: bwrap (défaut) → launcher bwrap_launch.sh + HOME = pod_dir (inchangé)" do
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-bwrap-#{System.unique_integer([:positive])}"

      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t1"))

      assert_receive {:launch_called, args, env}, 2_000
      assert String.ends_with?(args.launcher_path, "bwrap_launch.sh")
      assert env["HOME"] == args.pod_dir
      Process.exit(pid, :kill)
    end

    test "clé containment ABSENTE → rejeté à la porte G24-1 (allocate), JAMAIS lancé sur host" do
      # Invariant de sécurité LAUNCH-Q : un cap-profile mal formé (sans `containment`) ne peut PAS
      # atteindre host_launch — la porte G24-1 (`check_containment`, enum {bwrap,none}) le rejette à
      # l'allocate, AVANT do_launch. (Le défaut "bwrap" de `cap_profile_containment/1` est un filet
      # defense-in-depth, inatteignable dans le chemin gardé : la porte tranche d'abord.)
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())
      profile = update_in(valid_profile().metadata, &Map.delete(&1, "containment"))
      pod_id = "pod-nocont-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:allocate_failed, {:cap_profile_invalid, violations}}}},
                     2_000

      assert :g24_1 in violations
      refute_received {:launch_called, _, _}
    end
  end

  describe "deadline résultat — Z1 (timeout de RÉPONSE, pas budget de vie)" do
    # `spec.timeouts.response_sec` (champ optionnel) → forçage déterministe court
    # (le default par scope est 300s, trop long pour un test unit). 1s mini car
    # Process.send_after exige un integer ; assert_receive/sleep tolèrent le délai.
    defp short_timeout(profile), do: put_in(profile.spec["timeouts"], %{"response_sec" => 1})

    test "timeout AVEC task active → :failed (result_timeout)" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-timeout-active-#{System.unique_integer([:positive])}"
      # Une task ACTIVE (pending) pour ce pod → au FIRE du deadline,
      # pod_has_active_task? = true → vrai timeout de réponse → transition_failed.
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "fais X", role: "engineer"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000
    end

    test "timeout SANS task active (idle) → pod survit (Z1 : pas d'idle-kill)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-timeout-idle-#{System.unique_integer([:positive])}"
      # AUCUNE task → au FIRE, pod_has_active_task? = false → le pod attendait juste
      # sa prochaine task → PAS de kill. C'est le bug d'origine que le band-aid 60ks
      # masquait ; ici prouvé corrigé à la racine (vérif au fire, pas à l'armement).
      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      # Au-delà du response_sec (1s) : le deadline a firé, mais idle → pas de kill.
      Process.sleep(1_300)
      assert Process.alive?(pid), "pod idle tué par :result_deadline (régression Z1)"
      assert GenServer.call(pid, :info).phase == :monitoring

      Process.exit(pid, :kill)
    end

    test "pod forever — deadline JAMAIS armé (survit même avec task active + timeout court)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-forever-noarm-#{System.unique_integer([:positive])}"
      # forever = permanent : arm_result_deadline n'arme PAS (pas de timeout de réponse ;
      # gouverné par kill_pod externe). Même AVEC une task active + response_sec=1s, pas
      # de kill — preuve directe du point auditeur (un permanent ne meurt pas sur timeout).
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "veille", role: "gatekeeper"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      profile = valid_profile()

      profile =
        put_in(profile.spec["invocation"], %{"lifetime_scope" => "forever", "max_alive_sec" => 60})

      args = %{
        cap_profile: short_timeout(profile),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      Process.sleep(1_300)
      assert Process.alive?(pid), "pod forever tué par :result_deadline (ne doit JAMAIS armer)"

      Process.exit(pid, :kill)
    end

    test "liveness BOUGE → deadline ré-armé → pod survit malgré task active + timeout court (F-RESULT-DEADLINE-LOOP)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-liveness-alive-#{System.unique_integer([:positive])}"

      # Task active : sans le watchdog liveness, le deadline (1s) firerait → result_timeout (cf. test
      # « timeout AVEC task active »). Ici la sonde renvoie une valeur TOUJOURS croissante (monotonic) → à
      # chaque tick (100ms) le pod « a bougé » → arm_result_deadline ré-arme → le deadline ne tombe jamais.
      {:ok, _t} =
        Fleet.TaskQueue.enqueue(pod_id, %{brief: "vrai livrable long", role: "engineer"})

      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      probe = fn _state -> {System.monotonic_time(:microsecond), nil} end

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [liveness_tick_ms: 100, liveness_probe_fun: probe, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      # Bien au-delà du response_sec (1s) : un engineer qui BOUGE ne doit JAMAIS timeout.
      Process.sleep(1_500)

      assert Process.alive?(pid),
             "engineer qui BOUGE tué par le deadline (F-RESULT-DEADLINE-LOOP non corrigé)"

      assert GenServer.call(pid, :info).phase == :monitoring

      Process.exit(pid, :kill)
    end

    test "liveness PLAT (silence) AVEC task active → deadline fire → result_timeout (vrai stuck)" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-liveness-stuck-#{System.unique_integer([:positive])}"

      # Sonde CONSTANTE → aucun mouvement → le watchdog ne ré-arme jamais → le deadline (1s) tombe sur
      # silence total = vrai stuck → transition_failed. (1er tick sans baseline = 1 ré-arme « bénéfice du
      # doute » → fire ~1 tick plus tard, couvert par assert_receive 5s.)
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "fais X", role: "engineer"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      probe = fn _state -> {42, 42} end

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [liveness_tick_ms: 100, liveness_probe_fun: probe, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000
    end
  end

  describe "Z2 — porte cap-profile G24 au spawn (CAP-D1 / F-CONT-RISK)" do
    test "profil G24-invalide (server-tools non deny) → :failed, JAMAIS lancé" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      # disallowedTools VIDE → viole g24_9 (F-CONT-RISK : web_search/web_fetch/code_execution/…
      # non deny). La gate validate/1 (do_allocate) doit refuser AVANT tout launch.
      profile =
        put_in(valid_profile().spec["scope"], %{"disallowedTools" => [], "git_ops_denied" => []})

      pod_id = "pod-g24-invalid-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:allocate_failed, {:cap_profile_invalid, violations}}}},
                     2_000

      assert :g24_9_strict in violations, "la gate doit lever g24_9 (F-CONT-RISK)"
      # Le refus est au boundary ALLOCATE → le pod n'est JAMAIS lancé (gate effective).
      refute_received {:launch_called, _, _}
    end
  end

  describe "Z2 — porte credentials au spawn (CRED-D1 : scope + plan)" do
    defp write_creds(dir, oauth) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
      Application.put_env(:fleet_spawner, :claude_dir, dir)
    end

    test "scopes insuffisants (manque user:sessions:claude_code) → :failed, jamais lancé",
         %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      write_creds(Path.join(tmp_dir, "creds-noscope"), %{
        "accessToken" => "sk-ant-x",
        "expiresAt" => 99_999_999_999_999,
        "refreshToken" => "rt",
        "scopes" => ["user:inference"],
        "subscriptionType" => "max"
      })

      pod_id = "pod-noscope-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t1"))

      assert_receive {:EXIT, ^pid,
                      {:shutdown,
                       {:credentials_invalid,
                        {:insufficient_scopes, ["user:sessions:claude_code"]}}}},
                     2_000

      refute_received {:launch_called, _, _}
    end

    test "plan non-payant (subscriptionType free) → :failed", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      write_creds(Path.join(tmp_dir, "creds-free"), %{
        "accessToken" => "sk-ant-x",
        "expiresAt" => 99_999_999_999_999,
        "refreshToken" => "rt",
        "scopes" => ["user:inference", "user:sessions:claude_code"],
        "subscriptionType" => "free"
      })

      pod_id = "pod-free-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t1"))

      assert_receive {:EXIT, ^pid, {:shutdown, {:credentials_invalid, {:invalid_plan, "free"}}}},
                     2_000

      refute_received {:launch_called, _, _}
    end
  end

  describe "launch backend errors" do
    test "backend :error → phase :failed avec raison" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply({:error, :bwrap_failed})

      pod_id = "pod-launch-fail-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:EXIT, ^pid, {:shutdown, {:launch_failed, :bwrap_failed}}}, 2_000
    end
  end

  describe "exit du process avant résultat" do
    test "exit_status sans résultat → pod.failed + arrêt {:shutdown, exited_before_result}" do
      Process.flag(:trap_exit, true)
      # Fake port vivant (sleep) ; on simule l'exit du process avant tout submit_result.
      fake_port = Port.open({:spawn, "/bin/sleep 60"}, [:binary, :exit_status])
      StubBackend.set_reply(interactive_reply(port: fake_port))

      pod_id = "pod-exit-noliv-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-exit"))
      assert_receive {:launch_called, _, _}, 2_000

      # Le pod est en :monitoring (aucun résultat reçu). On envoie l'exit du port.
      send(pid, {fake_port, {:exit_status, 137}})

      assert_receive {:EXIT, ^pid, {:shutdown, {:exited_before_result, 137}}}, 2_000
    end
  end

  describe "lifecycle pipe (engineer long-lived)" do
    # Chantier engineer long-lived (cf. doctrine pipeline-implementation.md
    # Phase III). Pour lifetime_scope != one-shot, do_extract NE FAIT PAS
    # release : le pod broadcast pod.completed, reset submitted_result,
    # retourne à :monitoring, re-arm result_deadline. Release uniquement
    # sur kill_pod (gatekeeper promote/abandon) ou deadline.
    defp pipe_profile do
      profile = valid_profile()

      put_in(profile.spec["invocation"], %{
        "lifetime_scope" => "pipe",
        "max_alive_sec" => 60
      })
    end

    # Pipe à livrable git async : seul ce mode a un push (lu par le workspace, confirmé par
    # deliverable.published) à protéger du re-brief → :publishing au submit. pipe_profile() seul
    # défaute deliverable_mode à "payload" (gatekeeper/architect-like : verdict/interactif, pas de push).
    defp git_native_pipe_profile do
      profile = pipe_profile()
      put_in(profile.spec["deliverable_mode"], "git_native")
    end

    test "cycle 1 submit_result → pod.completed broadcastée, pod reste en :monitoring" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe"))

      pod_id = "pod-pipe-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1, "answer" => "ok"})

      # pod.completed reçue côté Bus.
      assert_receive %Fleet.Event{
                       source: :spawner,
                       type: :"pod.completed",
                       payload: payload
                     },
                     2_000

      assert payload["pod_id"] == pod_id
      assert payload["result"]["cycle"] == 1

      # Pod TOUJOURS vivant + retour :monitoring + submitted_result reset.
      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert Process.alive?(pid)

      Process.exit(pid, :kill)
    end

    test "cycle 2 submit_result après cycle 1 → second pod.completed, pod toujours vivant" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe2"))

      pod_id = "pod-pipe-2cy-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})

      assert_receive %Fleet.Event{
                       source: :spawner,
                       type: :"pod.completed",
                       payload: %{"result" => %{"cycle" => 1}}
                     },
                     2_000

      Process.sleep(50)
      assert GenServer.call(pid, :info).phase == :monitoring

      submit_result_event(pod_id, %{"cycle" => 2})

      assert_receive %Fleet.Event{
                       source: :spawner,
                       type: :"pod.completed",
                       payload: %{"result" => %{"cycle" => 2}}
                     },
                     2_000

      assert Process.alive?(pid)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert info.last_result == %{"cycle" => 2}

      Process.exit(pid, :kill)
    end

    test "kill_pod (gatekeeper promote/abandon) → pod release proprement" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe-kill"))

      pod_id = "pod-pipe-kill-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})
      Process.sleep(50)
      assert GenServer.call(pid, :info).phase == :monitoring

      # Pas via Fleet.Spawner.kill_pod (DynamicSupervisor pas démarré dans
      # ce test ; les tests existants utilisent Process.exit direct). Test
      # de surface : le pod accepte un kill brutal sans race state.json.
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}, 2_000
    end

    # SLOT-FREEZE garde — :publishing n'est armée QUE pour un livrable git async (maybe_enter_publishing).
    test "submit d'un pipe git_native → condition :publishing armée (push à protéger)" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pub-git"))

      pod_id = "pod-pub-git-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: git_native_pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})

      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}, 2_000

      # publish_deadline est à 120s (jamais fire ici) et deliverable.published n'est pas émis
      # (StepRunCompleter off en test) → :publishing reste présente après le retour à :monitoring.
      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert :publishing in info.conditions

      Process.exit(pid, :kill)
    end

    # Le nouveau comportement : un pipe payload (pas de push async) n'arme PLUS :publishing — sinon il
    # armerait un deadline 120s jamais levé par deliverable.published (émis seulement pour git_native).
    test "submit d'un pipe payload → PAS de condition :publishing (rien à protéger)" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pub-payload"))

      pod_id = "pod-pub-payload-#{System.unique_integer([:positive])}"

      # pipe_profile() = deliverable_mode défaut "payload".
      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})

      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}, 2_000

      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      refute :publishing in info.conditions

      Process.exit(pid, :kill)
    end
  end

  describe "recovery depuis state FS" do
    test "in-flight → :recreate (session NEUVE, pas --resume)" do
      pod_id = "pod-recover-os-#{System.unique_integer([:positive])}"
      Process.flag(:trap_exit, true)

      state_path = state_fs_path(pod_id)
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "issue_id" => "issue-old",
          "session_id" => "session-old",
          "phase" => "launching"
        })
      )

      StubBackend.set_reply(interactive_reply(session_id: "ignored"))

      # Toute phase EN VOL sur un (re)spawn → :recreate (le backend est mort sous
      # `:temporary`, jamais de --resume sur une session morte). Le pod relance avec une
      # session NEUVE (ici le mint déterministe de l'engineer, repo de test résolu), PAS
      # --resume session-old : ce qu'on prouve = recreate ≠ resume, pas la forme de l'id.
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, args, env}, 2_000
      refute args.session_id == "session-old"
      assert env["LCARS_POD_RESUME"] == "0"
    end
  end

  describe "terminate_pod_port/1 (teardown chaîne bwrap)" do
    test "SIGTERM le process du port — le holder n'est PAS tué par Port.close seul" do
      # Reproduit le holder : un process qui IGNORE l'EOF stdin (sleep) → Port.close l'orpheline ;
      # terminate_pod_port le SIGTERM par os_pid. (Le vrai bwrap+holder est prouvé en e2e ; ici on
      # verrouille la mécanique exacte du fix en unitaire.)
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert os_alive?(os_pid)

      assert :ok = Fleet.Spawner.Pod.Backend.terminate_pod_port(port)
      Process.sleep(400)
      refute os_alive?(os_pid)
    end

    # F-C4b-3 : race TOCTOU — le port se ferme tout seul (claude finit après submit_result)
    # entre le check et le Port.close → ArgumentError → le GenServer du pod crashait sur une
    # complétion RÉUSSIE (observé C4b do_release). safe_port_close absorbe l'ArgumentError ;
    # sans le rescue, ce test crashe (RED).
    test "safe_port_close sur un port DÉJÀ fermé → :ok (pas de crash, race do_release)" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      true = Port.close(port)
      # port maintenant fermé : un Port.close brut lèverait ArgumentError.
      assert :ok = Fleet.Spawner.Pod.Backend.safe_port_close(port)
    end

    test "terminate_pod_port sur un port déjà fermé → :ok (idempotent teardown)" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      true = Port.close(port)
      assert :ok = Fleet.Spawner.Pod.Backend.terminate_pod_port(port)
    end
  end

  describe "terminate/2 — teardown GARANTI du backend sur tout {:stop} (filet OTP)" do
    # AVANT le fix : `transition_failed` ({:stop, {:shutdown, _}}) ne tardownait PAS le backend → le
    # process claude/holder restait ORPHELIN vivant (OAuth+RAM) jusqu'au reaper périodique (~60s, si ON).
    # terminate/2 le garantit : OTP l'appelle sur TOUT {:stop}. On observe via un fake-port VIVANT (sleep)
    # dont l'os_pid DOIT être SIGTERM au teardown (le port stub est posé par interactive_reply(port:)).
    test "transition_failed (result_timeout) → terminate/2 tardownent le backend (os_pid SIGTERM)" do
      Process.flag(:trap_exit, true)

      fake_port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      {:os_pid, os_pid} = Port.info(fake_port, :os_pid)
      assert os_alive?(os_pid)

      StubBackend.set_reply(interactive_reply(port: fake_port))

      pod_id = "pod-term-tf-#{System.unique_integer([:positive])}"

      # Task active → au FIRE du deadline (response_sec=1s), pod_has_active_task? = true → transition_failed.
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "fais X", role: "engineer"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      # transition_failed → {:stop, {:shutdown, {:result_timeout, _}}} → terminate/2 → teardown_backend.
      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000

      Process.sleep(400)

      refute os_alive?(os_pid),
             "backend orphelin : terminate/2 n'a pas torn down le port sur transition_failed"
    end

    # Le chemin succès (`do_release`) tardownent DÉJÀ explicitement, AVANT le {:stop} ; terminate/2 re-appelle
    # teardown_backend (le filet). Le double appel doit être IDEMPOTENT : pas de crash (sinon l'EXIT ne serait
    # pas :normal), backend bien mort. (Le double `terminate_pod_port` sur port fermé est prouvé unitairement
    # juste au-dessus ; ici on verrouille le double appel sur le chemin de vie COMPLET.)
    test "double teardown (do_release explicite + terminate/2 filet) idempotent — EXIT :normal, backend mort" do
      Process.flag(:trap_exit, true)

      fake_port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      {:os_pid, os_pid} = Port.info(fake_port, :os_pid)
      assert os_alive?(os_pid)

      StubBackend.set_reply(interactive_reply(port: fake_port, session_id: "s-idem"))

      pod_id = "pod-term-idem-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-idem"))
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # one-shot : submit_result → extract → release (teardown #1) → {:stop, :normal} → terminate (teardown #2).
      submit_result_event(pod_id, %{"answer" => "OK"})

      assert_receive {:EXIT, ^pid, :normal}, 3_000

      Process.sleep(400)

      refute os_alive?(os_pid),
             "backend pas torn down sur le chemin succès (do_release + terminate/2)"
    end
  end

  describe "auth — mode bind unique (token_arg retiré 2026-06-14)" do
    test "tout spawn pose LCARS_AUTH_MODE=bind, jamais de token en clair (LCARS_ANTHROPIC_AUTH_TOKEN)" do
      # Plus de switch : bind est le seul mode (bwrap monte le .credentials.json RW → refresh OAuth natif,
      # pas de falaise 8h, pas de fuite en argv). Aucune config :auth_mode à poser.
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-auth-bind-#{System.unique_integer([:positive])}"

      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_AUTH_MODE"] == "bind"
      refute Map.has_key?(env, "LCARS_ANTHROPIC_AUTH_TOKEN")

      # LCARS_POD_DIR n'est PAS posée par le spawner (dead code : bwrap_launch `--clearenv` la strippe,
      # host_launch l'`export`e = $POD_DIR, F-E1). La racine pod passe par LCARS_POD_HOME (bwrap, forwardé
      # par bwrap_launch) + le fallback `$HOME`. cf. pod.ex (Map.put 5001703f réverté).
      refute Map.has_key?(env, "LCARS_POD_DIR")
      assert env["LCARS_POD_HOME"] == "/home/.pod"
    end
  end

  describe "credential per-humain — anti cross-human (résidu de partage accepté)" do
    test "le CLAUDE_DIR du spawn = le claudeDir per-humain résolu, jamais un dir global hardcodé partagé",
         %{tmp_dir: tmp_dir} do
      # Le `.credentials.json` partagé-writable entre pods du même humain est VOULU (seule mécanique
      # multi-agent vendor sous abonnement ; cf. le gros bloc « ON N'Y TOUCHE PAS » autour de `claude_dir`
      # dans pod.ex). Le résidu « un pod lit/écrase le creds de son humain » est ACCEPTÉ (écraser = self-DoS ;
      # lire = son propre token, pod = AS l'humain). Le SEUL invariant à garder = PER-HUMAIN : le spawn porte
      # le claudeDir résolu pour l'humain propriétaire (en prod = `~/.claude` de l'user runtime ; en test = la
      # config `:claude_dir` que le setup pose à `<tmp>/.claude`), JAMAIS un dir GLOBAL hardcodé partagé entre
      # humains (= l'exfil cross-humain, le seul vrai vecteur). Si quelqu'un câble un claudeDir partagé
      # (`/var/lib/.../.claude`…), CLAUDE_DIR ≠ `<tmp>/.claude` → CE test casse.
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-cred-perhuman-#{System.unique_integer([:positive])}"
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      assert env["CLAUDE_DIR"] == Path.join(tmp_dir, ".claude")
    end
  end

  describe "R14 — mcp_server_spec obligatoire pour backend réel" do
    test "backend réel + mcp_server_spec nil → spawn refusé (fail-loud, pas de pod cassé)" do
      # Backend réel (non-Stub) sans spec MCP : le pod réel parle MCP → refus net
      # à do_project (maybe_provision_mcp_config) AVANT tout launch. On NE lance
      # pas réellement bwrap (l'échec est au provisioning).
      Application.put_env(
        :fleet_spawner,
        :launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend
      )

      Application.delete_env(:fleet_spawner, :mcp_server_spec)

      on_exit(fn ->
        Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
        Application.delete_env(:fleet_spawner, :mcp_server_spec)
      end)

      Process.flag(:trap_exit, true)
      pod_id = "pod-mcp-missing-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:project_failed, {:mcp_server_spec_required, _backend}}}},
                     2_000

      # Le refus est à do_project (provisioning) AVANT do_launch → jamais de launch.
      refute_received {:launch_called, _args, _env}
    end

    test "monde-propre : .mcp-fleet.json porte le path IN-NAMESPACE (/home/.pod), pas le pod_dir hôte" do
      # Régression live 2026-06-22 : la génération posait le path HÔTE (state.pod_dir) du pont dans le
      # .mcp-fleet.json. bwrap remappant le pod_dir → /home/.pod, ce path n'existe PAS in-sandbox → le pont
      # MCP n'a jamais démarré → 0 tool mcp__fleet__* → TOUS les pods aveugles (data-plane mort, prouvé
      # arch+gatekeeper+consultants). Le config doit porter le path sandbox (`sandbox_home`), la COPIE du
      # pont visant elle le pod_dir hôte. valid_profile = containment bwrap → sandbox_home = /home/.pod.
      # Plus de clé "env" statique dans la spec : la socket per-pod (LCARS_FLEET_MCP_SOCKET) est injectée
      # PER-POD par pod.ex (build_fleet_mcp_entry) depuis le provisionneur de socket (stub en test).
      Application.put_env(:fleet_spawner, :mcp_server_spec, %{
        "command" => "bash",
        "args" => ["-c", "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"]
      })

      on_exit(fn -> Application.delete_env(:fleet_spawner, :mcp_server_spec) end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-mcp-ns-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, _env}, 2_000

      %{pod_dir: pod_dir} = GenServer.call(pid, :info)
      config = Path.join(pod_dir, ".mcp-fleet.json") |> File.read!() |> Jason.decode!()
      [_, cmd] = get_in(config, ["mcpServers", "fleet", "args"])

      assert cmd =~ "/home/.pod/.lcars/fleet_mcp_bridge.py"
      assert cmd =~ "/home/.pod/.lcars/fleet_mcp_bridge.log"
      # JAMAIS le pod_dir hôte (invisible in-sandbox → c'était LE bug).
      refute cmd =~ pod_dir

      # R9 — l'env du serveur MCP porte la socket per-pod (chemin host rendu par le provisionneur stub,
      # contient le pod_id) en `LCARS_FLEET_MCP_SOCKET` + `LCARS_POD_ID` ; plus de `LCARS_POD_CAPABILITY`
      # (identité = le canal/la socket, pas un secret sur le fil) ni de `LCARS_FLEET_MCP_URL` (HTTP retiré).
      env = get_in(config, ["mcpServers", "fleet", "env"])
      assert env["LCARS_FLEET_MCP_SOCKET"] =~ pod_id
      assert env["LCARS_POD_ID"] == pod_id
      refute Map.has_key?(env, "LCARS_POD_CAPABILITY")
      refute Map.has_key?(env, "LCARS_FLEET_MCP_URL")
    end
  end

  describe "mundo invocado — intégration e2e (#1 creds-inject + cwd + doc-mount dans un spawn)" do
    test "pod-projet : auth bind + cwd=workspace + code & doc clonés",
         %{tmp_dir: tmp_dir} do
      # creds fixture per-human (Fleet.Credentials.Gate.validate lit ce claudeDir)
      fake_claude = Path.join(tmp_dir, "fake-claude")
      File.mkdir_p!(fake_claude)

      File.write!(
        Path.join(fake_claude, ".credentials.json"),
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-mundo-XYZ",
            "expiresAt" => 99_999_999_999_999,
            "refreshToken" => "rt",
            "scopes" => ["user:inference", "user:sessions:claude_code"],
            "subscriptionType" => "max"
          }
        })
      )

      # claude_dir override → Fleet.Credentials.Gate.validate lit ce claudeDir (validation scope/plan). Mode = bind.
      Application.put_env(:fleet_spawner, :claude_dir, fake_claude)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :claude_dir) end)

      # repo source avec branche code (main) + branche doc (work/ops)
      src = source_repo_with_doc(Path.join(tmp_dir, "proj-src"))

      base = valid_profile()

      profile = %{
        base
        | spec:
            base.spec
            |> Map.put("project", %{
              "repo_path" => src,
              "base_branch" => "main",
              "work_branch" => "work/ops"
            })
            |> Map.put("injects", %{"gitconfig" => true})
      }

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-mundo-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t-1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:launch_called, _args, env}, 3_000

      # #1 — mode bind (token_arg retiré) : LCARS_AUTH_MODE=bind, aucun token en clair dans l'env
      assert env["LCARS_AUTH_MODE"] == "bind"
      refute Map.has_key?(env, "LCARS_ANTHROPIC_AUTH_TOKEN")

      # cwd → la branche CODE (workspace)
      pod_dir = env["HOME"]

      # #monde-propre Stage B : cwd INTRA-POD relocalisé (le pod_dir réel masqué derrière /home/.pod).
      # Legacy projet-sans-rc_name → le workspace relocalisé. (Un worker rc_name verrait /home/<project>.)
      assert env["LCARS_POD_CWD"] == "/home/.pod/workspace"

      # doc-mount : branche code + branche doc clonées côte à côte dans le pod
      assert File.exists?(Path.join([pod_dir, "workspace", "src.txt"]))
      assert File.exists?(Path.join([pod_dir, "work", "BACKLOG.md"]))

      # P2 : CLAUDE.md composé présent À LA RACINE DU CWD (workspace), pas seulement au pod_dir
      assert File.exists?(Path.join([pod_dir, "workspace", "CLAUDE.md"]))

      # O5 (Brick 5) : l'identité git du rôle n'est PLUS posée par `git config` mutable dans le
      # workspace (F-01 falsifiable) — elle est injectée en env au lancement (bwrap_launch.sh :
      # GIT_AUTHOR_*/GIT_COMMITTER_* + GIT_CONFIG_GLOBAL=/dev/null), non observable depuis ce backend
      # stub. L'enforcement F-01 (gate au push) est couvert par deliverable_gate_test.exs +
      # executor_post_extract_test.exs (cas git_native usurpation). Donc plus d'assertion sur la
      # config git locale ici.
    end

    test "projet injecté par le BRIEF (opts[:project]) — pas besoin du cap_profile statique",
         %{tmp_dir: tmp_dir} do
      src = source_repo_with_doc(Path.join(tmp_dir, "brief-src"))

      # cap_profile SANS project (project absent) ; le brief l'injecte via opts.
      profile = valid_profile()

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-brief-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: profile,
        issue_id: "t-1",
        pod_id: pod_id,
        opts: [
          project: %{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"},
          repo_id: @test_repo_id
        ]
      }

      {:ok, _pid} = spawn_via_supervisor(args)

      assert_receive {:launch_called, _args, env}, 3_000
      pod_dir = env["HOME"]

      # le projet du brief est cloné (code + doc) + cwd posé, sans aucun project au catalogue
      # #monde-propre Stage B : cwd INTRA-POD relocalisé (le pod_dir réel masqué derrière /home/.pod).
      # Legacy projet-sans-rc_name → le workspace relocalisé. (Un worker rc_name verrait /home/<project>.)
      assert env["LCARS_POD_CWD"] == "/home/.pod/workspace"
      assert File.exists?(Path.join([pod_dir, "workspace", "src.txt"]))
      assert File.exists?(Path.join([pod_dir, "work", "BACKLOG.md"]))
    end
  end

  # BL-055 — sous l'id pod DÉTERMINISTE, un re-dispatch retombe sur le même pod_id : une tombstone
  # terminale (state.json :succeeded/:released/:killed) d'un cycle précédent ferait court-circuiter
  # `recover_or_init` en `:release` (stop muet, aucun launch) → boucle orphelin côté poller. `spawn_pod`
  # appelle `clear_terminal_snapshot/3` AVANT spawn pour repartir FRESH. Régression validée live 2026-06-18.
  describe "clear_terminal_snapshot/3 (anti-tombstone)" do
    test "efface la tombstone TERMINALE (:succeeded) + le pod_dir → re-spawn fresh", %{
      tmp_dir: tmp
    } do
      pod_id = "issue-99-engineer"
      snap = write_snapshot!(tmp, pod_id, "succeeded")
      pod_dir = seed_pod_dir!(tmp, pod_id)

      assert :ok = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, valid_profile())

      refute File.exists?(snap)
      refute File.exists?(pod_dir)
    end

    test "efface aussi :released et :killed (toutes phases terminales)", %{tmp_dir: tmp} do
      for phase <- ["released", "killed"] do
        pod_id = "issue-#{phase}-engineer"
        snap = write_snapshot!(tmp, pod_id, phase)
        pod_dir = seed_pod_dir!(tmp, pod_id)

        assert :ok = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, valid_profile())
        refute File.exists?(snap)
        refute File.exists?(pod_dir)
      end
    end

    test "PRÉSERVE un snapshot EN VOL (:monitoring) — la recovery reste intacte", %{tmp_dir: tmp} do
      pod_id = "issue-77-engineer"
      snap = write_snapshot!(tmp, pod_id, "monitoring")
      pod_dir = seed_pod_dir!(tmp, pod_id)

      assert :ok = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, valid_profile())

      assert File.exists?(snap)
      assert File.exists?(pod_dir)
    end

    test "no-op idempotent si aucun snapshot", %{tmp_dir: _tmp} do
      assert :ok =
               Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(
                 "issue-404-engineer",
                 valid_profile()
               )
    end
  end

  # scope_for("one-shot") == "pods" → <state_fs_root>/pods/<pod_id>/state.json (config posée par setup).
  defp write_snapshot!(tmp, pod_id, phase) do
    path = Path.join([tmp, "state", "pods", pod_id, "state.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"phase" => phase, "session_id" => "sid-#{pod_id}", "v" => 1})
    )

    path
  end

  defp seed_pod_dir!(tmp, pod_id) do
    dir = Path.join([tmp, "pods", "pod_#{pod_id}"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "workspace_marker"), "stale")
    dir
  end
end

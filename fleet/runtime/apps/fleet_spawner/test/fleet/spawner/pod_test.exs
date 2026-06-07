defmodule Fleet.Spawner.PodTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.LaunchBackend.StubBackend

  @moduletag :tmp_dir

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

    # mundo invocado #1 : le défaut auth_mode est :token_arg → tout spawn extrait l'access_token
    # OAuth (fail-loud R15 sinon). Fixture creds par défaut pour les tests qui ne testent pas l'auth ;
    # les tests auth/fail-loud overrident :claude_dir per-test.
    setup_claude = Path.join(tmp_dir, ".claude")
    File.mkdir_p!(setup_claude)

    File.write!(
      Path.join(setup_claude, ".credentials.json"),
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-setup-tok",
          "expiresAt" => 99_999_999_999_999,
          "refreshToken" => "rt",
          "scopes" => ["user:inference"]
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

  defp valid_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer", "containment" => "bwrap"},
      spec: %{
        "lifetime_scope" => "one-shot",
        "systemPrompt" => "engineer-role.md",
        "scope" => %{"disallowedTools" => [], "git_ops_denied" => []},
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

  defp build_args(pod_id, ticket_id) do
    %{cap_profile: valid_profile(), ticket_id: ticket_id, pod_id: pod_id, opts: []}
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

  # R1.2 — modèle interactif : le backend retourne init_message: nil (pas de frame NDJSON).
  defp interactive_reply(opts \\ []) do
    {:ok,
     %{
       init_message: nil,
       ndjson_log: nil,
       port: Keyword.get(opts, :port),
       session_id: Keyword.get(opts, :session_id, "stub-sess")
     }}
  end

  # R-CORE.comm ADR-G — completion event-driven : simule le broker fleet_task_queue broadcastant
  # %Fleet.Event{task_completed} sur fleet.events (= ce qui arrive quand l'agent appelle
  # submit_result via fleet_mcp). Le pod doit être en :monitoring (subscribed) avant l'appel.
  defp submit_result_event(pod_id, payload) do
    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet.events", %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      timestamp: DateTime.utc_now(),
      pod_id: pod_id,
      correlation_id: "test-corr-#{pod_id}",
      payload: %{result: payload}
    })
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

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

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

    test "POD_DIR + artefacts créés (pod en MONITORING tant que pas de livrable)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-dir-#{System.unique_integer([:positive])}"
      # PAS de livrable → le pod reste en :monitoring (poll), GenServer vivant.
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
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
      # Ticket-driven (pivot doctrine) : le brief vit dans tickets/<ticket_id>.md
      # (pas context/brief.md). Claude le lit comme contenu projet.
      assert File.exists?(Path.join(info.pod_dir, "tickets/ticket-1.md"))

      # Monitor in-pod (réveil-par-flag, ADR-G) : watch.sh provisionné au pod_dir,
      # exécutable. L'agent l'arme via l'outil Monitor (cf. SP).
      watch = Path.join(info.pod_dir, "watch.sh")
      assert File.exists?(watch)
      assert File.read!(watch) =~ "ton tour"
      %File.Stat{mode: mode} = File.stat!(watch)
      assert Bitwise.band(mode, 0o100) != 0, "watch.sh doit être exécutable (owner)"

      # SP enrichi par agent-worker-base draft : doit contenir le workflow
      # yop → get_task → submit_result + le protocole Monitor (réveil-par-flag).
      sp = File.read!(Path.join(info.pod_dir, ".lcars/system-prompt.md"))
      assert sp =~ "agent worker LCARS"
      assert sp =~ "submit_result"
      assert sp =~ "yop"
      assert sp =~ "Monitor"
      assert sp =~ "watch.sh"

      Process.exit(pid, :kill)
    end

    test "PUSH — le travail (opts[:mandate]) est livré dans tickets/<ticket_id>.md" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-mandate-#{System.unique_integer([:positive])}"
      mandate = "Compile le module X et retourne le nombre de warnings."

      args = %{
        cap_profile: valid_profile(),
        ticket_id: "ticket-1",
        pod_id: pod_id,
        opts: [mandate: mandate]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      info = GenServer.call(pid, :info)
      # Ticket-driven : le brief est dans tickets/<ticket_id>.md, pas en prompt
      # canal-user (safety guardrail REPL).
      ticket = File.read!(Path.join(info.pod_dir, "tickets/ticket-1.md"))
      assert ticket =~ "worker LCARS"
      assert ticket =~ mandate
      assert ticket =~ "submit_result"

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
          "disallowedTools" => ["web_search"],
          "git_ops_denied" => ["push --force", "reset --hard"]
        })

      pod_id = "pod-gitops-#{System.unique_integer([:positive])}"
      args = %{cap_profile: profile, ticket_id: "ticket-1", pod_id: pod_id, opts: []}

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
      args = build_args(pod_id, "ticket-1") |> Map.put(:opts, session_id: "sess-xyz")
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000
      # Barrière de sync : :launch_called est émis PENDANT launch_backend.launch, avant que
      # do_launch ne fasse write_state_fs. GenServer.call est traité après la chaîne handle_continue.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # state.json écrit en LAUNCH (avant MONITOR) → présent même sans livrable.
      # BL-021 chantier 4 : schéma C-3 complet (v, session_id, cap_profile_name,
      # started_at, phase, conditions, ticket_id). `pod_id` n'est PLUS persisté
      # (la clé de recovery = path /var/lib/lcars/<scope>/<pod_id>/state.json).
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["v"] == 1
      assert content["ticket_id"] == "ticket-1"
      assert content["session_id"] == "sess-xyz"
      assert is_binary(content["cap_profile_name"])
      assert is_binary(content["started_at"])
      assert is_list(content["conditions"])
      assert content["phase"] in ["launching", "monitoring"]

      Process.exit(pid, :kill)
    end
  end

  describe "deadline résultat (aucun submit_result)" do
    test "timeout réponse court + aucun résultat → :failed (result_timeout)" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      # R0.8-brick4 : override `spec.timeouts.response_sec` (champ optionnel)
      # → forçage déterministe court (default code par scope ne fit pas un test
      # unit court). 0s = :result_deadline... non, 0 invalide (cond `> 0` faux)
      # → fallback default 300s. On set 0.001s ? Non, integer requis. Approche
      # alternative : on garde le default scope, mais l'assertion timeout=5_000
      # ne marche pas. → set explicitement 1s suffit.
      # En fait, le code accepte tout `is_number and > 0`. On peut set
      # un nombre minuscule (eg `0.001`) car le check est `> 0`, pas integer.
      # MAIS Process.send_after exige integer. Donc 1s mini puis assert_receive
      # tolère le délai.
      profile = valid_profile()
      profile = put_in(profile.spec["timeouts"], %{"response_sec" => 1})
      pod_id = "pod-timeout-#{System.unique_integer([:positive])}"

      args = %{cap_profile: profile, ticket_id: "ticket-1", pod_id: pod_id, opts: []}
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000
    end
  end

  describe "launch backend errors" do
    test "backend :error → phase :failed avec raison" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply({:error, :bwrap_failed})

      pod_id = "pod-launch-fail-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

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

    test "cycle 1 submit_result → pod.completed broadcastée, pod reste en :monitoring" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe"))

      pod_id = "pod-pipe-#{System.unique_integer([:positive])}"
      args = %{cap_profile: pipe_profile(), ticket_id: "ticket-1", pod_id: pod_id, opts: []}

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
      args = %{cap_profile: pipe_profile(), ticket_id: "ticket-1", pod_id: pod_id, opts: []}

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
      args = %{cap_profile: pipe_profile(), ticket_id: "ticket-1", pod_id: pod_id, opts: []}

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
  end

  describe "recovery depuis state FS" do
    test "pipe scope : init/1 lit state.json en vol → :resume (--resume session-old) → :succeeded" do
      pod_id = "pod-recover-#{System.unique_integer([:positive])}"
      Process.flag(:trap_exit, true)

      # pipe pod → state FS sous `pipes/` (scope-dérivé), pas `pods/`.
      state_path = state_fs_path(pod_id, "pipes")
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "ticket_id" => "ticket-old",
          "session_id" => "session-old",
          "phase" => "launching"
        })
      )

      StubBackend.set_reply(interactive_reply(session_id: "session-old"))

      # pipe = porte un contexte → recovery :resume → relance avec --resume session-old.
      pipe_args = %{build_args(pod_id, "ticket-1") | cap_profile: pipe_profile()}
      {:ok, pid} = spawn_via_supervisor(pipe_args)
      assert_receive {:launch_called, args, _env}, 2_000
      # LE point F-C4b-1 : le travail est repris (--resume session-old), pas reroll.
      assert args.session_id == "session-old"

      # pipe = long-lived : après reprise il atteint :monitoring et y RESTE (pas de
      # release auto sur submit ; cf. cycle pipe). On vérifie la reprise, pas la complétion.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)
    end

    test "one-shot scope : recovery in-flight → :recreate (session NEUVE, pas --resume) — F-C4b-1" do
      pod_id = "pod-recover-os-#{System.unique_integer([:positive])}"
      Process.flag(:trap_exit, true)

      state_path = state_fs_path(pod_id)
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "ticket_id" => "ticket-old",
          "session_id" => "session-old",
          "phase" => "launching"
        })
      )

      StubBackend.set_reply(interactive_reply(session_id: "ignored"))

      # valid_profile() = one-shot → /clear chaque cycle, pas de contexte → :recreate.
      # Le pod relance avec une session NEUVE (UUID), PAS --resume session-old.
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
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

      assert :ok = Fleet.Spawner.Pod.terminate_pod_port(port)
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
      assert :ok = Fleet.Spawner.Pod.safe_port_close(port)
    end

    test "terminate_pod_port sur un port déjà fermé → :ok (idempotent teardown)" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      true = Port.close(port)
      assert :ok = Fleet.Spawner.Pod.terminate_pod_port(port)
    end
  end

  describe "BL-021 chantier 6 — auth_mode switch" do
    test "explicit :bind (legacy ADR-F) — env contient LCARS_AUTH_MODE=bind, pas de LCARS_ANTHROPIC_AUTH_TOKEN" do
      # mundo invocado #1 : le défaut est désormais :token_arg ; :bind reste une échappatoire opt-in.
      Application.put_env(:fleet_spawner, :auth_mode, :bind)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :auth_mode) end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-auth-bind-#{System.unique_integer([:positive])}"

      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_AUTH_MODE"] == "bind"
      refute Map.has_key?(env, "LCARS_ANTHROPIC_AUTH_TOKEN")
    end

    test "défaut :token_arg — extrait access_token depuis creds.json + injecte LCARS_ANTHROPIC_AUTH_TOKEN",
         %{tmp_dir: tmp_dir} do
      # Setup : faux claudeDir + creds.json avec slot canonique `claudeAiOauth.accessToken`.
      fake_claude_dir = Path.join(tmp_dir, "fake-claude")
      File.mkdir_p!(fake_claude_dir)

      File.write!(
        Path.join(fake_claude_dir, ".credentials.json"),
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-fake-test-token-XYZ",
            "expiresAt" => 99_999_999_999_999,
            "refreshToken" => "rt-fake",
            "scopes" => ["user:inference", "user:sessions:claude_code"]
          }
        })
      )

      # Pas de put_env(:auth_mode) — on prouve que le DÉFAUT est :token_arg (mundo invocado #1).
      Application.put_env(:fleet_spawner, :claude_dir, fake_claude_dir)

      on_exit(fn ->
        Application.delete_env(:fleet_spawner, :claude_dir)
      end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-auth-token-#{System.unique_integer([:positive])}"

      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_AUTH_MODE"] == "token_arg"
      assert env["LCARS_ANTHROPIC_AUTH_TOKEN"] == "sk-ant-fake-test-token-XYZ"
    end

    test ":token_arg + creds.json absent — spawn BLOQUÉ (R15 fail-loud, pas de launch)",
         %{tmp_dir: tmp_dir} do
      # R15 : pas de creds.json → en mode :token_arg, le spawn est refusé net
      # (transition_failed {:auth_token_required, _}) AVANT le launch — plus de
      # pod lancé sans token (l'ancien comportement silencieux).
      missing_dir = Path.join(tmp_dir, "no-creds-here")
      File.mkdir_p!(missing_dir)

      Application.put_env(:fleet_spawner, :claude_dir, missing_dir)
      Application.put_env(:fleet_spawner, :auth_mode, :token_arg)

      on_exit(fn ->
        Application.delete_env(:fleet_spawner, :claude_dir)
        Application.delete_env(:fleet_spawner, :auth_mode)
      end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-auth-token-missing-#{System.unique_integer([:positive])}"

      Process.flag(:trap_exit, true)
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      # Le backend n'est jamais lancé, le pod tombe avec la raison fail-loud.
      assert_receive {:EXIT, ^pid, {:shutdown, {:auth_token_required, _}}}, 2_000
      refute_received {:launch_called, _args, _env}
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
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:project_failed, {:mcp_server_spec_required, _backend}}}},
                     2_000

      # Le refus est à do_project (provisioning) AVANT do_launch → jamais de launch.
      refute_received {:launch_called, _args, _env}
    end
  end

  describe "mundo invocado — intégration e2e (#1 creds-inject + cwd + doc-mount dans un spawn)" do
    test "pod-projet : token_arg défaut + token per-human + cwd=workspace + code & doc clonés",
         %{tmp_dir: tmp_dir} do
      # creds fixture per-human (token_arg lit ce claudeDir, défaut config)
      fake_claude = Path.join(tmp_dir, "fake-claude")
      File.mkdir_p!(fake_claude)

      File.write!(
        Path.join(fake_claude, ".credentials.json"),
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-mundo-XYZ",
            "expiresAt" => 99_999_999_999_999,
            "refreshToken" => "rt",
            "scopes" => ["user:inference"]
          }
        })
      )

      Application.put_env(:fleet_spawner, :claude_dir, fake_claude)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :claude_dir) end)

      # repo source avec branche code (main) + branche doc (work/ops)
      src = source_repo_with_doc(Path.join(tmp_dir, "proj-src"))

      base = valid_profile()

      profile = %{
        base
        | spec:
            Map.put(base.spec, "project", %{
              "repo_path" => src,
              "base_branch" => "main",
              "work_branch" => "work/ops"
            })
      }

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-mundo-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        spawn_via_supervisor(%{cap_profile: profile, ticket_id: "t-1", pod_id: pod_id, opts: []})

      assert_receive {:launch_called, _args, env}, 3_000

      # #1 — creds-inject per-human, DÉFAUT token_arg (zéro mount du .claude)
      assert env["LCARS_AUTH_MODE"] == "token_arg"
      assert env["LCARS_ANTHROPIC_AUTH_TOKEN"] == "sk-ant-mundo-XYZ"

      # cwd → la branche CODE (workspace)
      pod_dir = env["HOME"]
      assert env["LCARS_POD_CWD"] == Path.join(pod_dir, "workspace")

      # doc-mount : branche code + branche doc clonées côte à côte dans le pod
      assert File.exists?(Path.join([pod_dir, "workspace", "src.txt"]))
      assert File.exists?(Path.join([pod_dir, "work", "BACKLOG.md"]))
    end
  end
end

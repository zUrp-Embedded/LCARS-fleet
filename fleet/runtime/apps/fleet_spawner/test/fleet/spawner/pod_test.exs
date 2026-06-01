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

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      Application.delete_env(:fleet_sp_builder, :sp_role_root)
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

  defp state_fs_path(pod_id) do
    root = Application.get_env(:fleet_spawner, :state_fs_root)
    Path.join([root, "pods", pod_id, "state.json"])
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
      assert File.exists?(Path.join(info.pod_dir, ".claude/system-prompt.md"))
      assert File.exists?(Path.join(info.pod_dir, ".claude/CLAUDE.md"))
      assert File.exists?(Path.join(info.pod_dir, ".claude/protocole-user.md"))
      # Ticket-driven (pivot doctrine) : le brief vit dans tickets/<ticket_id>.md
      # (pas context/brief.md). Claude le lit comme contenu projet.
      assert File.exists?(Path.join(info.pod_dir, "tickets/ticket-1.md"))

      # SP enrichi par agent-worker-base draft : doit contenir le workflow
      # yop → get_task → submit_result.
      sp = File.read!(Path.join(info.pod_dir, ".claude/system-prompt.md"))
      assert sp =~ "agent worker LCARS"
      assert sp =~ "submit_result"
      assert sp =~ "yop"

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

    test "state.json écrit après launch (point de recovery, session_id capturé)" do
      StubBackend.set_reply(interactive_reply(session_id: "sess-xyz"))

      pod_id = "pod-state-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
      assert_receive {:launch_called, _args, _env}, 2_000
      # Barrière de sync : :launch_called est émis PENDANT launch_backend.launch, avant que
      # do_launch ne fasse write_state_fs. GenServer.call est traité après la chaîne handle_continue.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # state.json écrit en LAUNCH (avant MONITOR) → présent même sans livrable.
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["pod_id"] == pod_id
      assert content["ticket_id"] == "ticket-1"
      assert content["v"] == 1
      assert content["session_id"] == "sess-xyz"

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
      assert_receive {_atom, %{"event_type" => "pod.completed", "payload" => payload}}, 2_000
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

      assert_receive {_atom,
                      %{
                        "event_type" => "pod.completed",
                        "payload" => %{"result" => %{"cycle" => 1}}
                      }},
                     2_000

      Process.sleep(50)
      assert GenServer.call(pid, :info).phase == :monitoring

      submit_result_event(pod_id, %{"cycle" => 2})

      assert_receive {_atom,
                      %{
                        "event_type" => "pod.completed",
                        "payload" => %{"result" => %{"cycle" => 2}}
                      }},
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
    test "init/1 lit state.json + reprend en :launching ; résultat soumis → :succeeded" do
      pod_id = "pod-recover-#{System.unique_integer([:positive])}"
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

      StubBackend.set_reply(interactive_reply(session_id: "session-old"))

      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
      assert_receive {:launch_called, args, _env}, 2_000
      assert args.session_id == "session-old"

      # Après reprise launch → :monitoring (subscribed). Le central broadcaste le résultat → succeeded.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)
      submit_result_event(pod_id, %{"answer" => "RECOVERED"})

      assert_receive {:EXIT, ^pid, :normal}, 3_000
      content = File.read!(state_path) |> Jason.decode!()
      assert content["phase"] == "succeeded"
    end
  end
end

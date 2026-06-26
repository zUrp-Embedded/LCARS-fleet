defmodule Fleet.SpawnerTest do
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend.StubBackend

  # G24-9 (F-CONT-RISK) — disallowedTools minimum exigé par validate/1 câblée au spawn
  # (Z2 ; cf. cap_profile.ex @disallowed_minimum_strict/_prefix).
  @min_disallowed ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution tool_search_web)

  # repo_id de test pour les rôles PROJECT-BOUND (engineer = `valid_profile/0` et `forever_profile/0`).
  # Leur session_id hexspeak EXIGE un repo résolu : sans lui le mint REFUSE (raise) plutôt que de fabriquer
  # un UUID random — l'absence de repo signale une forge non résolue (forge down). En prod le dispatcher
  # pose ce repo ; ces tests spawnent en direct, donc on le passe en `opts`. Omis volontairement dans les
  # cas qui DOIVENT échouer avant le mint (refus mandat, pod_id non path-safe).
  @test_repo_id 7

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
    # adr-f : plus de coffre (creds via claudeDir bind bwrap).

    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# SP")
    Application.put_env(:fleet_sp_builder, :sp_role_root, sp_root)

    # auth = mode bind unique (token_arg retiré 2026-06-14) ; le gate credentials lit quand même le creds
    # natif (scope/plan). Fixture creds par défaut (ces tests ne testent pas la porte credentials) —
    # cf. pod_test.exs. Sans ça : {:credentials_invalid, _} → pod meurt au boot.
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

    StubBackend.set_reply(
      {:ok,
       %{
         init_message: StubBackend.valid_init_message(),
         ndjson_log: "/tmp/stub.ndjson"
       }}
    )

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      # B5 #576 : NE PAS delete :launch_backend — laisse la baseline
      # hermétique config/test.exs (StubBackend) en place, sinon le
      # code-default LauncherPortBackend RÉEL est atteint sous race async.
      Application.delete_env(:fleet_sp_builder, :sp_role_root)
      Application.delete_env(:fleet_spawner, :claude_dir)
    end)

    :ok
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
        "systemPrompt" => "engineer-role.md",
        "scope" => %{"disallowedTools" => @min_disallowed, "git_ops_denied" => []},
        "knowledge" => %{"skills" => []},
        "invocation" => %{"lifetime_scope" => "one-shot", "max_alive_sec" => 60},
        "injects" => %{},
        "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 60},
        "modop_set" => []
      }
    }
  end

  defp forever_profile do
    put_in(valid_profile().spec["invocation"], %{"lifetime_scope" => "forever"})
  end

  defp wait_until(fun, tries \\ 80) do
    cond do
      fun.() ->
        true

      tries <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  describe "R18 — refus spawn one-shot sans mandat" do
    test "one-shot + pas de mandat → {:error, :mandate_required}" do
      assert {:error, :mandate_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "ticket-no-mandate")
    end

    test "one-shot + mandat VIDE (ex. StageSpawner ctx vide) → {:error, :mandate_required}" do
      assert {:error, :mandate_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "ticket-empty-mandate", mandate: "")
    end

    test "F076 — pod_id non path-safe (.. ou / ou vide) → {:error, :invalid_pod_id}, aucun spawn" do
      # pod_id file dans pod_dir/sock_path/state recovery (Path.join + interpolation) → un pod_id non
      # path-safe traverserait hors de ~/pods. Refus CLAIR AVANT tout spawn. Les ids légitimes
      # UUID / `permanent-<name>-ts` / `issue-<n>-<role>-ts` (charset [A-Za-z0-9._-]) passent — couverts
      # par les tests qui spawnent avec des ids UUID (hyphénés = même charset).
      for bad <- ["../etc/passwd", "a/b", "..", "pod_..", "x y", ""] do
        assert match?(
                 {:error, :invalid_pod_id},
                 Fleet.Spawner.spawn_pod(valid_profile(), "ticket-1",
                   pod_id: bad,
                   mandate: "do x"
                 )
               ),
               "pod_id #{inspect(bad)} aurait dû être rejeté (path-traversal)"
      end
    end

    test "one-shot + mandat → {:ok, _}" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(valid_profile(), "ticket-mandate",
                 mandate: "répare le bug X",
                 pod_id: "pod-r18-mandate-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end

    test "one-shot + allow_no_mandate (admin/diagnostic) → {:ok, _}" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(valid_profile(), "ticket-admin",
                 allow_no_mandate: true,
                 pod_id: "pod-r18-admin-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end

    test "long-lived (forever) sans mandat → {:ok, _} (exempté, pull via MCP)" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(forever_profile(), "ticket-forever",
                 pod_id: "pod-r18-forever-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end
  end

  test "spawn_pod returns {:ok, pid} and registers the pod" do
    pod_id = "pod-public-api-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Fleet.Spawner.spawn_pod(valid_profile(), "ticket-1",
               pod_id: pod_id,
               allow_no_mandate: true,
               repo_id: @test_repo_id
             )

    assert is_pid(pid)

    # Mi14 : registration synchrone (name: {:via, Registry, ...}) → pod enregistré dès {:ok, pid}.
    assert {:ok, %{pod_id: ^pod_id}} = Fleet.Spawner.pod_info(pod_id)
  end

  # STATE-004 (couplage DN-recovery B) : sous `:temporary`, un pod qui meurt sans
  # complétion n'est pas relancé → sa task active doit être libérée (clear_for_pod)
  # sinon elle reste orpheline. Backend en échec → transition_failed → clear.
  test "un pod qui échoue libère sa task active (STATE-004)" do
    pod_id = "pod-orphan-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    # task active présente avant l'échec
    assert {:ok, status} = Fleet.TaskQueue.pod_status(pod_id)
    refute is_nil(status)

    # backend en échec → le pod meurt via transition_failed → clear_pod_task
    StubBackend.set_reply({:error, :stub_launch_fail})

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "ticket-orphan",
        pod_id: pod_id,
        allow_no_mandate: true,
        repo_id: @test_repo_id
      )

    # la task active passe à `:cleared` (≠ `:pending`/`:assigned`) — best-effort, async → poll borné
    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "la task du pod mort devrait être :cleared, statut actuel : #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"
  end

  # LIFE-002 (DN-recovery B) : un pod long-lived (re)spawné avec un snapshot
  # `state.json` en phase `:monitoring` doit RESTAURER la session (`--resume`) ET
  # RE-LANCER le backend (`:process_launched`), PAS reprendre directement en
  # `:monitor` sur un backend mort (le supervisor ne ressuscite jamais sous B).
  test "recovery : pod long-lived repris à :monitoring restaure la session + re-launch (LIFE-002)" do
    # BL-035 : `:resume` opt-in (défaut OFF). Ce test exerce le chemin :resume → gate ON.
    Application.put_env(:fleet_spawner, :recovery_resume_enabled, true)
    on_exit(fn -> Application.delete_env(:fleet_spawner, :recovery_resume_enabled) end)

    pod_id = "pod-recover-#{System.unique_integer([:positive])}"

    # 1er spawn → récupère le state_fs_path réel, puis kill (kill_pod n'écrit pas
    # de state sous B — pas de do_release), donc notre snapshot ci-dessous fait foi.
    {:ok, _} =
      Fleet.Spawner.spawn_pod(forever_profile(), "ticket-rec",
        pod_id: pod_id,
        repo_id: @test_repo_id
      )

    assert {:ok, %{state_fs_path: path}} = Fleet.Spawner.pod_info(pod_id)
    :ok = Fleet.Spawner.kill_pod(pod_id)
    assert wait_until(fn -> match?({:error, :not_found}, Fleet.Spawner.pod_info(pod_id)) end)

    # snapshot recovery : session connue + phase active
    resumed_sid = "11111111-2222-4333-8444-555555555555"
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "v" => 1,
        "session_id" => resumed_sid,
        "phase" => "monitoring",
        "cap_profile_name" => "engineer",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "conditions" => [],
        "ticket_id" => "ticket-rec"
      })
    )

    # re-spawn même pod_id → recovery_action(forever, :monitoring) = :resume
    {:ok, _} =
      Fleet.Spawner.spawn_pod(forever_profile(), "ticket-rec",
        pod_id: pod_id,
        repo_id: @test_repo_id
      )

    # :resume RE-MATÉRIALISE (:home_projected = do_project a re-composé le SP, pas
    # dans le snapshot) PUIS re-lance (:process_launched). Sans le re-project, sp=nil
    # → build_spawn :invalid_args en backend réel (bug gatekeeper-permanent live).
    assert wait_until(fn ->
             case Fleet.Spawner.pod_info(pod_id) do
               {:ok, %{session_id: ^resumed_sid, conditions: conds}} ->
                 :home_projected in conds and :process_launched in conds

               _ ->
                 false
             end
           end),
           "le pod repris devrait restaurer #{resumed_sid}, RE-MATÉRIALISER (:home_projected) ET re-lancer (:process_launched), info: #{inspect(Fleet.Spawner.pod_info(pod_id))}"

    Fleet.Spawner.kill_pod(pod_id)
  end

  # LIFE-003 (DN-recovery B §5) : kill_pod = release DÉLIBÉRÉE (handle_call(:kill) →
  # teardown + clear_for_pod + état :killed), pas un terminate_child brutal. Discriminant :
  # la task active est libérée (`:cleared`) — un kill brutal ne clearait pas.
  test "kill_pod fait une release propre : task libérée + pod parti (LIFE-003)" do
    pod_id = "pod-killclean-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(forever_profile(), "ticket-kill",
        pod_id: pod_id,
        repo_id: @test_repo_id
      )

    assert wait_until(fn -> match?({:ok, _}, Fleet.Spawner.pod_info(pod_id)) end)

    assert :ok = Fleet.Spawner.kill_pod(pod_id)

    # release propre : la task est libérée (vs kill brutal qui ne clear pas)
    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "kill_pod devrait libérer la task (release propre), statut : #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"

    assert wait_until(fn -> match?({:error, :not_found}, Fleet.Spawner.pod_info(pod_id)) end)
  end

  test "pod_info returns :not_found when pod doesn't exist" do
    assert {:error, :not_found} = Fleet.Spawner.pod_info("nonexistent-pod-id")
  end

  test "kill_pod terminates the pod" do
    pod_id = "pod-kill-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "ticket-2",
        pod_id: pod_id,
        allow_no_mandate: true,
        repo_id: @test_repo_id
      )

    assert :ok = Fleet.Spawner.kill_pod(pod_id)
    # Mi14 : terminate_child est sync sur la mort, MAIS le cleanup Registry (via monitor) est
    # async → poll borné déterministe (≤200ms) au lieu d'un sleep fixe flaky.
    assert :ok = wait_unregistered(pod_id)
    assert {:error, :not_found} = Fleet.Spawner.pod_info(pod_id)
  end

  test "kill_pod :not_found for unknown pod_id" do
    assert {:error, :not_found} = Fleet.Spawner.kill_pod("never-spawned")
  end

  test "spawn_pod uses UUID by default if no :pod_id opt given" do
    {:ok, pid1} =
      Fleet.Spawner.spawn_pod(valid_profile(), "ticket-uuid-1",
        allow_no_mandate: true,
        repo_id: @test_repo_id
      )

    {:ok, pid2} =
      Fleet.Spawner.spawn_pod(valid_profile(), "ticket-uuid-2",
        allow_no_mandate: true,
        repo_id: @test_repo_id
      )

    assert pid1 != pid2
  end

  test "count_pods returns the number of active pods" do
    assert is_integer(Fleet.Spawner.count_pods())

    pod_id = "pod-count-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "ticket-count",
        pod_id: pod_id,
        allow_no_mandate: true,
        repo_id: @test_repo_id
      )

    # Mi14 : count_children reflète l'enfant actif dès {:ok} de start_child. Le pod que JE
    # viens de spawner est actif → count ≥ 1. PAS d'assertion sur un DELTA `initial+1` : le
    # registre pods est GLOBAL (singleton DynamicSupervisor) partagé entre tests async → un
    # spawn/terminate concurrent fausse le delta (flaky observé). `≥ 1` est déterministe.
    assert Fleet.Spawner.count_pods() >= 1
  end

  describe "wake_pod/1" do
    test "wake_pod :not_found for unknown pod_id" do
      assert {:error, :not_found} = Fleet.Spawner.wake_pod("never-spawned-id")
    end

    test "wake_pod :not_a_tmux_pod si le pod existe mais pas via TmuxBackend (StubBackend → tmux_session nil)" do
      pod_id = "pod-wake-stub-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Fleet.Spawner.spawn_pod(valid_profile(), "ticket-wake",
          pod_id: pod_id,
          allow_no_mandate: true,
          repo_id: @test_repo_id
        )

      # StubBackend ne pose pas tmux_session dans launched → pod_info renvoie
      # tmux_session: nil → wake_pod refuse proprement (pas de send-keys).
      assert {:error, :not_a_tmux_pod} = Fleet.Spawner.wake_pod(pod_id)

      Fleet.Spawner.kill_pod(pod_id)
    end

    @tag :tmp_dir
    test "write_turn_flag : token UNIQUE à chaque appel (anti-collision watch.sh content-based)",
         %{
           tmp_dir: tmp
         } do
      assert :ok = Fleet.Spawner.write_turn_flag(tmp)
      t1 = File.read!(Path.join(tmp, "turn.flag"))
      assert :ok = Fleet.Spawner.write_turn_flag(tmp)
      t2 = File.read!(Path.join(tmp, "turn.flag"))
      # watch.sh fire sur `cur != last` → chaque écriture DOIT changer le contenu.
      assert t1 != t2
    end

    @tag :tmp_dir
    test "write_turn_flag : dir absent → :ok best-effort (log-loud, pas de crash)", %{
      tmp_dir: tmp
    } do
      assert :ok = Fleet.Spawner.write_turn_flag(Path.join(tmp, "nope/missing"))
    end
  end

  # Poll borné déterministe (Mi14) : attend le cleanup Registry async post-terminate_child
  # (≤200ms). Remplace un sleep fixe : réussit dès que nettoyé, échoue après le bound.
  defp wait_unregistered(pod_id, tries \\ 100) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [] ->
        :ok

      _ when tries > 0 ->
        Process.sleep(2)
        wait_unregistered(pod_id, tries - 1)

      _ ->
        :timeout
    end
  end
end

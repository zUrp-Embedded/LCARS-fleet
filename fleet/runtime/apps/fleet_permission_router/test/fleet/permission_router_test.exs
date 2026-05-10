defmodule Fleet.PermissionRouterTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.PermissionRouter
  alias Fleet.PermissionRouter.RelayStubs

  @ipc_test_patterns [
    %{
      "name" => "force-push",
      "regex" => "git\\s+push\\s+--force",
      "severity" => "critical",
      "justification" => "test force push",
      "added_date" => "2026-05-09"
    }
  ]

  setup %{tmp_dir: tmp_dir} do
    ipc_patterns_path = Path.join(tmp_dir, "refuse-patterns.json")
    audit_path = Path.join(tmp_dir, "fleet-audit.jsonl")
    File.write!(ipc_patterns_path, Jason.encode!(@ipc_test_patterns))

    Application.put_env(:fleet_ipc_filter, :refuse_patterns_path, ipc_patterns_path)
    Application.put_env(:fleet_ipc_filter, :audit_log_path, audit_path)

    Application.put_env(
      :fleet_ipc_filter,
      :event_backend,
      Fleet.IpcFilter.EventBackend.NotWiredYet
    )

    :ok = Fleet.IpcFilter.init_patterns!()
    :ok = Fleet.IpcFilter.reset_drift()

    Application.put_env(:fleet_permission_router, :audit_log_path, audit_path)
    Application.put_env(:fleet_permission_router, :relay_timeout_ms, 100)
    Application.put_env(:fleet_permission_router, :relay_backend, RelayStubs.Capture)
    Application.put_env(:fleet_permission_router, :relay_capture_target, self())

    # Démarre le router avec timeout court pour tests
    {:ok, _pid} = PermissionRouter.start_link(relay_timeout_ms: 100)

    on_exit(fn ->
      [
        {:fleet_ipc_filter, :refuse_patterns_path},
        {:fleet_ipc_filter, :audit_log_path},
        {:fleet_ipc_filter, :event_backend},
        {:fleet_permission_router, :audit_log_path},
        {:fleet_permission_router, :relay_timeout_ms},
        {:fleet_permission_router, :relay_backend},
        {:fleet_permission_router, :relay_capture_target}
      ]
      |> Enum.each(fn {app, key} -> Application.delete_env(app, key) end)
    end)

    %{audit_path: audit_path}
  end

  defp cap_profile(scope, policy \\ "silent") do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "test"},
      spec: %{
        "scope" => scope,
        "invocation" => %{"policy" => policy}
      }
    }
  end

  defp ctx(cap, opts \\ []) do
    %{
      cap_profile: cap,
      pod_id: Keyword.get(opts, :pod_id, "pod-test"),
      ticket_id: Keyword.get(opts, :ticket_id, "ticket-test")
    }
  end

  describe "step 1 — IpcFilter deny" do
    test "REFUSE_PATTERN match → propagation deny avec reason" do
      cap = cap_profile(%{"allowedTools" => ["Bash"], "disallowedTools" => []})

      assert {:deny, reason} =
               PermissionRouter.can_use_tool(
                 "Bash",
                 %{"command" => "git push --force"},
                 ctx(cap)
               )

      assert reason =~ "REFUSE_PATTERN matched"
      assert reason =~ "force-push"
    end
  end

  describe "step 2 — auto-allow allowedTools" do
    test "tool dans allowedTools → :allow" do
      cap = cap_profile(%{"allowedTools" => ["Read", "Glob"], "disallowedTools" => []})

      assert :allow = PermissionRouter.can_use_tool("Read", %{}, ctx(cap))
      assert :allow = PermissionRouter.can_use_tool("Glob", %{}, ctx(cap))
    end
  end

  describe "step 3 — auto-deny disallowedTools" do
    test "tool dans disallowedTools → {:deny, ...}" do
      cap = cap_profile(%{"allowedTools" => [], "disallowedTools" => ["Bash"]})

      assert {:deny, "tool in disallowedTools"} =
               PermissionRouter.can_use_tool("Bash", %{"command" => "ls"}, ctx(cap))
    end

    test "tool présent dans allowedTools (et absent des disallowed) → :allow" do
      cap = cap_profile(%{"allowedTools" => ["Bash"], "disallowedTools" => []})

      assert :allow = PermissionRouter.can_use_tool("Bash", %{"command" => "ls"}, ctx(cap))
    end

    test "tool présent dans les DEUX listes — allowed prioritaire (cond order)" do
      cap = cap_profile(%{"allowedTools" => ["Bash"], "disallowedTools" => ["Bash"]})

      assert :allow = PermissionRouter.can_use_tool("Bash", %{"command" => "ls"}, ctx(cap))
    end
  end

  describe "step 4 — relay (policy :show)" do
    test "relay broadcast capturé + receive matching ref → decision propagée" do
      cap = cap_profile(%{"allowedTools" => [], "disallowedTools" => []}, "show")
      tool_input = %{"command" => "ls"}

      router_pid = Process.whereis(PermissionRouter)

      task =
        Task.async(fn ->
          PermissionRouter.can_use_tool("Bash", tool_input, ctx(cap))
        end)

      assert_receive {:relay_request, ref, payload}, 1_000
      assert payload.tool_name == "Bash"
      assert payload.tool_input == tool_input
      assert payload.pod_id == "pod-test"

      send(router_pid, {:permission_relay_response, %{ref: ref, decision: :allow}})

      assert :allow = Task.await(task)
    end

    test "relay timeout sans réponse → {:deny, \"relay timeout\"}" do
      cap = cap_profile(%{"allowedTools" => [], "disallowedTools" => []}, "show")

      assert {:deny, reason} =
               PermissionRouter.can_use_tool("Bash", %{"command" => "ls"}, ctx(cap))

      assert reason =~ "relay timeout"
      assert_received {:relay_request, _ref, _payload}
    end

    test "relay log audit append-only sur timeout", %{audit_path: audit_path} do
      cap = cap_profile(%{"allowedTools" => [], "disallowedTools" => []}, "show")

      {:deny, _} = PermissionRouter.can_use_tool("Bash", %{}, ctx(cap, pod_id: "pod-relay-1"))

      assert File.exists?(audit_path)

      lines =
        File.read!(audit_path)
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&Jason.decode!/1)

      relay_entries = Enum.filter(lines, &(&1["action"] == "relay_timeout"))
      assert Enum.any?(relay_entries, &(&1["pod_id"] == "pod-relay-1"))
    end
  end

  describe "step 5 — default deny" do
    test "tool ni allowed ni disallowed + policy != :show → {:deny, default_deny}" do
      cap = cap_profile(%{"allowedTools" => ["Read"], "disallowedTools" => []}, "silent")

      assert {:deny, reason} =
               PermissionRouter.can_use_tool("Bash", %{"command" => "ls"}, ctx(cap))

      assert reason =~ "default deny"
    end

    test "default_deny log audit", %{audit_path: audit_path} do
      cap = cap_profile(%{"allowedTools" => ["Read"], "disallowedTools" => []}, "silent")

      {:deny, _} = PermissionRouter.can_use_tool("Bash", %{}, ctx(cap, pod_id: "pod-default-1"))

      lines =
        File.read!(audit_path)
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&Jason.decode!/1)

      default_entries = Enum.filter(lines, &(&1["action"] == "default_deny"))
      assert Enum.any?(default_entries, &(&1["pod_id"] == "pod-default-1"))
    end
  end

  describe "default RelayBackend.NotWiredYet" do
    test "step 4 relay sans backend câblé → timeout systématique" do
      Application.put_env(
        :fleet_permission_router,
        :relay_backend,
        Fleet.PermissionRouter.RelayBackend.NotWiredYet
      )

      cap = cap_profile(%{"allowedTools" => [], "disallowedTools" => []}, "show")

      assert {:deny, reason} = PermissionRouter.can_use_tool("Bash", %{}, ctx(cap))
      assert reason =~ "relay timeout"
    end
  end

  describe "behaviour conformance" do
    test "Fleet.PermissionRouter.Callback définit can_use_tool/3" do
      callbacks = Fleet.PermissionRouter.Callback.behaviour_info(:callbacks)
      assert {:can_use_tool, 3} in callbacks
    end

    test "Fleet.PermissionRouter expose can_use_tool/3 (callback Callback)" do
      assert function_exported?(Fleet.PermissionRouter, :can_use_tool, 3)
    end
  end

  describe "context shape robuste" do
    test "context avec atom keys cap_profile/pod_id/ticket_id" do
      cap = cap_profile(%{"allowedTools" => ["Read"], "disallowedTools" => []})
      ctx = %{cap_profile: cap, pod_id: "p", ticket_id: "t"}

      assert :allow = PermissionRouter.can_use_tool("Read", %{}, ctx)
    end

    test "context avec string keys" do
      cap = cap_profile(%{"allowedTools" => ["Read"], "disallowedTools" => []})
      ctx = %{"cap_profile" => cap, "pod_id" => "p", "ticket_id" => "t"}

      assert :allow = PermissionRouter.can_use_tool("Read", %{}, ctx)
    end
  end
end

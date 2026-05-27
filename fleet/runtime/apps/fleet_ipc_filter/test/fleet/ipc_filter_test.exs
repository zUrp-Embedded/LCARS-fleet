defmodule Fleet.IPCFilterTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.IPCFilter
  alias Fleet.IPCFilter.EventCapture

  @sample_patterns [
    %{
      "name" => "force-push",
      "regex" => "git\\s+push\\s+(--force\\b|-f\\b)",
      "severity" => "critical",
      "justification" => "test force push",
      "added_date" => "2026-05-09"
    },
    %{
      "name" => "rm-git",
      "regex" => "rm\\s+-rf?\\s+\\.git\\b",
      "severity" => "critical",
      "justification" => "test rm git",
      "added_date" => "2026-05-09"
    },
    %{
      "name" => "web-search-attempted",
      "regex" => "^web_search\\b",
      "severity" => "medium",
      "justification" => "test F-CONT-RISK",
      "added_date" => "2026-05-09"
    }
  ]

  setup %{tmp_dir: tmp_dir} do
    patterns_path = Path.join(tmp_dir, "refuse-patterns.json")
    audit_path = Path.join(tmp_dir, "fleet-audit.jsonl")
    File.write!(patterns_path, Jason.encode!(@sample_patterns))

    Application.put_env(:fleet_ipc_filter, :refuse_patterns_path, patterns_path)
    Application.put_env(:fleet_ipc_filter, :audit_log_path, audit_path)
    Application.put_env(:fleet_ipc_filter, :event_backend, EventCapture)
    Application.put_env(:fleet_ipc_filter, :event_capture_target, self())
    Application.put_env(:fleet_ipc_filter, :drift_threshold, 3)

    :ok = IPCFilter.init_patterns!()
    :ok = IPCFilter.reset_drift()

    on_exit(fn ->
      [
        :refuse_patterns_path,
        :audit_log_path,
        :event_backend,
        :event_capture_target,
        :drift_threshold
      ]
      |> Enum.each(&Application.delete_env(:fleet_ipc_filter, &1))
    end)

    %{patterns_path: patterns_path, audit_path: audit_path}
  end

  describe "init_patterns!/0" do
    test "charge le catalogue + crée les tables ETS named" do
      assert :ets.whereis(:fleet_ipc_filter_patterns) != :undefined
      assert :ets.whereis(:fleet_ipc_filter_drift) != :undefined
      assert :ets.info(:fleet_ipc_filter_patterns, :size) == 3
    end

    test "raise si schema invalide", %{patterns_path: patterns_path} do
      bad = [%{"name" => "bad"}]
      File.write!(patterns_path, Jason.encode!(bad))

      assert_raise RuntimeError, ~r/schema invalide/, fn ->
        IPCFilter.init_patterns!()
      end
    end

    test "raise si regex invalide", %{patterns_path: patterns_path} do
      bad = [
        %{
          "name" => "bad-regex",
          "regex" => "[unclosed",
          "severity" => "critical",
          "justification" => "test",
          "added_date" => "2026-05-09"
        }
      ]

      File.write!(patterns_path, Jason.encode!(bad))

      assert_raise RuntimeError, ~r/regex invalide/, fn ->
        IPCFilter.init_patterns!()
      end
    end

    test "raise si fichier introuvable" do
      Application.put_env(:fleet_ipc_filter, :refuse_patterns_path, "/nonexistent/path.json")

      assert_raise File.Error, fn ->
        IPCFilter.init_patterns!()
      end
    end
  end

  describe "filter_tool_call/2 — happy path :allow" do
    test "tool_call sans match retourne :allow" do
      tool_call = %{"name" => "Read", "input" => %{"path" => "/tmp/foo.txt"}}
      ctx = %{pod_id: "pod-1", ticket_id: "ticket-42"}

      assert :allow = IPCFilter.filter_tool_call(tool_call, ctx)
    end

    test "tool_call avec input vide retourne :allow" do
      assert :allow =
               IPCFilter.filter_tool_call(%{"name" => "Glob", "input" => %{}}, %{pod_id: "p"})
    end
  end

  describe "filter_tool_call/2 — match deny" do
    test "force-push détecté + reason explicite" do
      tool_call = %{
        "name" => "Bash",
        "input" => %{"command" => "git push --force origin main"}
      }

      assert {:deny, reason} =
               IPCFilter.filter_tool_call(tool_call, %{pod_id: "p1", ticket_id: "t1"})

      assert reason =~ "REFUSE_PATTERN matched: force-push"
    end

    test "rm -rf .git détecté" do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "rm -rf .git"}}

      assert {:deny, reason} =
               IPCFilter.filter_tool_call(tool_call, %{pod_id: "p1", ticket_id: "t1"})

      assert reason =~ "rm-git"
    end

    test "F-CONT-RISK web_search observable" do
      tool_call = %{"name" => "web_search", "input" => %{"query" => "fleet"}}

      assert {:deny, reason} =
               IPCFilter.filter_tool_call(tool_call, %{pod_id: "p1", ticket_id: "t1"})

      assert reason =~ "web-search-attempted"
    end

    test "broadcast :refuse_pattern_match avec payload pod_id+ticket+pattern" do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}
      ctx = %{pod_id: "pod-X", ticket_id: "T-99"}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)

      assert_received {:ipc_event, :refuse_pattern_match,
                       %{pod_id: "pod-X", ticket_id: "T-99", pattern: "force-push"}}
    end

    test "log audit append-only NDJSON contient pattern_matched + tool_name", %{
      audit_path: audit_path
    } do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}
      ctx = %{pod_id: "pod-A", ticket_id: "T-1"}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)

      assert File.exists?(audit_path)
      line = File.read!(audit_path) |> String.trim()
      decoded = Jason.decode!(line)
      assert decoded["pattern_matched"] == "force-push"
      assert decoded["tool_name"] == "Bash"
      assert decoded["severity"] == "critical"
      assert decoded["pod_id"] == "pod-A"
      assert decoded["ticket_id"] == "T-1"
      assert decoded["action"] == "deny"
      assert decoded["ts"]
    end

    test "audit log append (pas overwrite)", %{audit_path: audit_path} do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}
      ctx = %{pod_id: "pod-A", ticket_id: "T-1"}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)

      lines = File.read!(audit_path) |> String.trim() |> String.split("\n")
      assert length(lines) == 3
    end
  end

  describe "drift counter — escalade :pod_drift après 3 strikes" do
    test "drift_for/1 = 0 si jamais incrémenté" do
      assert IPCFilter.drift_for("pod-fresh") == 0
    end

    test "drift increment cumul cross-calls" do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}
      ctx = %{pod_id: "pod-drift-1", ticket_id: "T"}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      assert IPCFilter.drift_for("pod-drift-1") == 1

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      assert IPCFilter.drift_for("pod-drift-1") == 2
    end

    test ":pod_drift broadcast au seuil 3" do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}
      ctx = %{pod_id: "pod-escalade", ticket_id: "T"}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      refute_received {:ipc_event, :pod_drift, _}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, ctx)
      assert_received {:ipc_event, :pod_drift, %{pod_id: "pod-escalade", drift_count: 3}}
    end

    test "drift counters par pod_id distincts" do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, %{pod_id: "pod-A", ticket_id: "T"})
      {:deny, _} = IPCFilter.filter_tool_call(tool_call, %{pod_id: "pod-B", ticket_id: "T"})

      assert IPCFilter.drift_for("pod-A") == 1
      assert IPCFilter.drift_for("pod-B") == 1
    end

    test "reset_drift/0 efface tous les compteurs" do
      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, %{pod_id: "pod-Z", ticket_id: "T"})
      assert IPCFilter.drift_for("pod-Z") == 1

      :ok = IPCFilter.reset_drift()
      assert IPCFilter.drift_for("pod-Z") == 0
    end
  end

  describe "EventBackend swap" do
    test "default NotWiredYet retourne :ok sans broadcast" do
      Application.put_env(
        :fleet_ipc_filter,
        :event_backend,
        Fleet.IPCFilter.EventBackend.NotWiredYet
      )

      tool_call = %{"name" => "Bash", "input" => %{"command" => "git push --force"}}

      {:deny, _} = IPCFilter.filter_tool_call(tool_call, %{pod_id: "pod-nw", ticket_id: "T"})
      refute_received {:ipc_event, _, _}
    end
  end

  describe "behaviour conformance" do
    test "Fleet.IPCFilter implémente Fleet.IPCFilter.Filter" do
      callbacks = Fleet.IPCFilter.Filter.behaviour_info(:callbacks)
      assert {:filter_tool_call, 2} in callbacks
    end
  end
end

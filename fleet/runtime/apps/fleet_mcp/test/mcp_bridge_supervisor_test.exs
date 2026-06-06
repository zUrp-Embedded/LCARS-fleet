defmodule Fleet.MCP.BridgeSupervisorTest do
  @moduledoc """
  Lot 1 inc4 — `Fleet.MCP.Bridge` (2 gates : schema-invalide→fail-fast,
  config-absente→graceful) + forward `pubsub_to_mcp` + `Fleet.MCP.Supervisor`.
  Bridge sous **noms uniques** (test-seam `:name`) → pas de fight avec le
  singleton umbrella. `async: false` (Fleet.PubSub partagé).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.{Bridge, Server}

  setup_all do
    unless Process.whereis(Fleet.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Fleet.PubSub})
    end

    :ok
  end

  defp uniq, do: :"br_#{System.unique_integer([:positive])}"

  @valid_yaml """
  bridges:
    mcp_to_pubsub:
      - mcp_channel: "fleet-control.coord.*"
        pubsub_topic: "fleet.events"
        event_type_prefix: "coord"
    pubsub_to_mcp:
      - pubsub_topic: "fleet.events"
        event_type: "coord.action.*"
        mcp_channel_template: "fleet-control.{target_role}.coord"
  """

  @bad_yaml """
  bridges:
    mcp_to_pubsub: "pas-une-liste"
  """

  defp tmp(dir, name, content) do
    p = Path.join(dir, name)
    File.write!(p, content)
    p
  end

  @tag :tmp_dir
  test "config absente → graceful degradation (ok, 0 mapping)", %{tmp_dir: dir} do
    n = uniq()
    assert {:ok, pid} = Bridge.start_link(name: n, bridge_config_path: Path.join(dir, "x.yaml"))
    assert %{pubsub_to_mcp: [], mcp_to_pubsub: []} = Bridge.mappings(n)
    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "config schema-invalide → fail-fast {:error,:bridge_config_invalid}", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    p = tmp(dir, "bad.yaml", @bad_yaml)

    assert {:error, {:bridge_config_invalid, errs}} =
             Bridge.start_link(name: uniq(), bridge_config_path: p)

    assert is_list(errs) and errs != []
  end

  @tag :tmp_dir
  test "config valide → mappings chargés + init_bridges :ok", %{tmp_dir: dir} do
    n = uniq()
    p = tmp(dir, "ok.yaml", @valid_yaml)
    {:ok, pid} = Bridge.start_link(name: n, bridge_config_path: p)
    m = Bridge.mappings(n)
    assert [%{"event_type" => "coord.action.*"}] = m.pubsub_to_mcp
    assert [%{"mcp_channel" => "fleet-control.coord.*"}] = m.mcp_to_pubsub
    assert Bridge.init_bridges(n) == :ok
    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "forward pubsub_to_mcp : event fleet.events → push channel résolu", %{tmp_dir: dir} do
    p = tmp(dir, "fwd.yaml", @valid_yaml)
    {:ok, pid} = Bridge.start_link(name: uniq(), bridge_config_path: p)
    :ok = Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet-control.engineer.coord")

    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet.events", %{
      "event_type" => "coord.action.handoff",
      "target_role" => "engineer",
      "payload" => "x"
    })

    assert_receive %{"event_type" => "coord.action.handoff", "target_role" => "engineer"}, 100
    GenServer.stop(pid)
  end

  # Bug audit externe 2026-05-24 (#1) : Bus.broadcast publie `{event_atom, map}`
  # (tuple), pas la map directe. Avant fix, le bridge ne match que `is_map(event)`
  # → tuple fall through au catch-all → 0 event consommé en prod. Ce test prouve
  # que le tuple-shape de Bus est désormais routé correctement (parité prod).
  @tag :tmp_dir
  test "forward Bus-shape : {event_atom, map} tuple → push channel résolu", %{tmp_dir: dir} do
    p = tmp(dir, "fwd_tuple.yaml", @valid_yaml)
    {:ok, pid} = Bridge.start_link(name: uniq(), bridge_config_path: p)
    :ok = Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet-control.engineer.coord")

    # Shape EXACTE produite par Fleet.EventRouter.Bus.broadcast/3.
    event = %{
      "event_type" => "coord.action.handoff",
      "target_role" => "engineer",
      "payload" => "x"
    }

    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet.events", {:"coord.action.handoff", event})

    assert_receive %{"event_type" => "coord.action.handoff", "target_role" => "engineer"}, 100
    GenServer.stop(pid)
  end

  # RC-1 (audit Codex 2026-06-06, NOM-001/SEAM-003) : depuis la couture R1-R2,
  # les producteurs canon (Executor, TaskQueue…) émettent `%Fleet.Event{}` via
  # `Bus.broadcast/2`. Le bridge ne fermait PAS ce contrat : `event["event_type"]`
  # sur une struct (clés atomiques, pas d'`Access`) lève/`nil` → routing perdu /
  # bridge crashé. Ce test prouve que la struct canon est désormais routée.
  @tag :tmp_dir
  test "forward canon : %Fleet.Event{} struct → push channel résolu (RC-1)", %{tmp_dir: dir} do
    p = tmp(dir, "fwd_canon.yaml", @valid_yaml)
    {:ok, pid} = Bridge.start_link(name: uniq(), bridge_config_path: p)
    :ok = Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet-control.engineer.coord")

    event = %Fleet.Event{
      source: :coord,
      type: :"coord.action.handoff",
      timestamp: DateTime.utc_now(),
      pod_id: "pod-x",
      payload: %{"target_role" => "engineer", "answer" => "x"}
    }

    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet.events", event)

    assert_receive %{"event_type" => "coord.action.handoff", "target_role" => "engineer"}, 200
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  # RC-1 (juge FAIL-1) : une map à clés ATOMIQUES doit aussi être normalisée —
  # sinon `event["event_type"]` (clé string) = nil → routing silencieusement
  # perdu. Tient la promesse SEAM-003 « on ne lit jamais une forme non normalisée ».
  @tag :tmp_dir
  test "forward map à clés atomiques → push channel résolu (RC-1 hermétique)", %{tmp_dir: dir} do
    p = tmp(dir, "fwd_atom.yaml", @valid_yaml)
    {:ok, pid} = Bridge.start_link(name: uniq(), bridge_config_path: p)
    :ok = Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet-control.engineer.coord")

    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet.events", %{
      event_type: "coord.action.handoff",
      target_role: "engineer",
      payload: "x"
    })

    assert_receive %{"event_type" => "coord.action.handoff", "target_role" => "engineer"}, 200
    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "forward : template non résolu → skip graceful (pas de crash)", %{tmp_dir: dir} do
    p = tmp(dir, "fwd2.yaml", @valid_yaml)
    {:ok, pid} = Bridge.start_link(name: uniq(), bridge_config_path: p)

    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet.events", %{
      "event_type" => "coord.action.handoff"
    })

    # Mi14 : :sys.get_state = barrière (le broadcast PubSub local est déjà en mailbox, FIFO).
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "Supervisor umbrella : Server + Bridge vivants (boot host)" do
    # L'Application fleet_mcp a booté Fleet.MCP.Supervisor (DN trigger §2).
    assert is_pid(Process.whereis(Fleet.MCP.Supervisor))
    assert is_pid(Process.whereis(Fleet.MCP.Server))
    assert is_pid(Process.whereis(Fleet.MCP.Bridge))
  end

  test "conformance ADR-C : Server refuse :pod (cascade Supervisor documentée)" do
    n = :"srvp_#{System.unique_integer([:positive])}"
    assert {:error, :forbidden_in_pod} = Server.start_link(boot_environment: :pod, name: n)
    assert Process.whereis(n) == nil
  end
end

defmodule Fleet.TaskMonitorTest do
  @moduledoc """
  DN ring1/fleet-task-monitor. `map_event/2` pur (async) + intégration
  GenServer FS (tmp_dir async-safe, name unique, `subscribe: false`).
  Contrat Bus réel `{event_atom, %{"payload"=>,"ticket_id"=>}}`
  (vérifié vs pseudo-code DN).
  """
  use ExUnit.Case, async: true

  alias Fleet.TaskMonitor

  @pfx "lcars-fleet-"

  describe "map_event/2 — mapping pur (DN §Mapping)" do
    test "dispatch_started → create in_progress, id+title canon" do
      assert {:create, id, %{"title" => t, "status" => "in_progress"} = task} =
               TaskMonitor.map_event(:dispatch_started, %{
                 "ticket_id" => "491",
                 "payload" => %{"role" => "engineer", "brief" => "fleet_gk"}
               })

      assert id == @pfx <> "dispatch-491"
      assert t == "⚙️ engineer #491: fleet_gk"
      assert task["metadata"]["lcars"] == true
    end

    test "dispatch_completed/failed → update status" do
      assert {:update, "lcars-fleet-dispatch-7", %{"status" => "completed"}} =
               TaskMonitor.map_event(:dispatch_completed, %{"ticket_id" => "7"})

      assert {:update, "lcars-fleet-dispatch-7", %{"status" => "failed"}} =
               TaskMonitor.map_event(:dispatch_failed, %{"ticket_id" => "7"})
    end

    test "gatekeeper spawned/terminated" do
      assert {:create, "lcars-fleet-gk-projX", %{"status" => "in_progress"}} =
               TaskMonitor.map_event(:gatekeeper_spawned, %{
                 "payload" => %{"slug" => "projX"}
               })

      assert {:update, "lcars-fleet-gk-projX", %{"status" => "completed"}} =
               TaskMonitor.map_event(:gatekeeper_terminated, %{
                 "payload" => %{"slug" => "projX"}
               })
    end

    test "pipeline_stage_transition → update title" do
      assert {:update, "lcars-fleet-dispatch-9", %{"title" => title}} =
               TaskMonitor.map_event(:pipeline_stage_transition, %{
                 "ticket_id" => "9",
                 "payload" => %{"stage" => "code-review"}
               })

      assert title =~ "code-review"
    end

    test "ticket_new_route_architect → create pending" do
      assert {:create, "lcars-fleet-ticket-42", %{"status" => "pending"} = task} =
               TaskMonitor.map_event(:ticket_new_route_architect, %{
                 "ticket_id" => "42",
                 "payload" => %{"title" => "bug X"}
               })

      assert task["title"] =~ "Ticket #42: bug X"
    end

    test "event inconnu → :ignore (défensif)" do
      assert :ignore = TaskMonitor.map_event(:something_else, %{})

      # défensif : payload absent ne crash pas, défauts sains
      assert {:create, "lcars-fleet-dispatch-?", %{"status" => "in_progress"}} =
               TaskMonitor.map_event(:dispatch_started, %{})
    end
  end

  describe "GenServer FS (tmp_dir, async-safe)" do
    @tag :tmp_dir
    test "heartbeat sentinel écrit au boot, status in_progress permanent",
         %{tmp_dir: dir} do
      {:ok, _} = start_monitor(dir, :hb)
      hb = Path.join([dir, "fleet-monitor-v1", "#{@pfx}heartbeat.json"])
      assert File.exists?(hb)

      assert %{"status" => "in_progress", "metadata" => %{"sentinel" => true}} =
               hb |> File.read!() |> Jason.decode!()
    end

    @tag :tmp_dir
    test "event create → JSON atomique ; update → merge", %{tmp_dir: dir} do
      {:ok, pid} = start_monitor(dir, :ev)
      f = Path.join([dir, "fleet-monitor-v1", "#{@pfx}dispatch-491.json"])

      send(
        pid,
        {:dispatch_started,
         %{"ticket_id" => "491", "payload" => %{"role" => "eng", "brief" => "b"}}}
      )

      assert wait_file(f)
      assert %{"status" => "in_progress"} = f |> File.read!() |> Jason.decode!()
      refute File.exists?(f <> ".tmp"), "écriture non-atomique (tmp résiduel)"

      send(pid, {:dispatch_completed, %{"ticket_id" => "491"}})

      assert wait_until(fn ->
               match?(
                 %{"status" => "completed", "title" => _},
                 f |> File.read!() |> Jason.decode!()
               )
             end)
    end

    @tag :tmp_dir
    test "event inconnu → no-op (pas de fichier parasite)", %{tmp_dir: dir} do
      {:ok, pid} = start_monitor(dir, :noop)
      send(pid, {:totally_unknown, %{"payload" => %{}}})
      Process.sleep(30)
      files = Path.wildcard(Path.join([dir, "fleet-monitor-v1", "*.json"]))
      # Seul le heartbeat doit exister.
      assert files == [Path.join([dir, "fleet-monitor-v1", "#{@pfx}heartbeat.json"])]
    end
  end

  defp start_monitor(dir, tag) do
    start_supervised(
      {TaskMonitor,
       name: :"tm_#{tag}_#{System.unique_integer([:positive])}", tasks_root: dir, subscribe: false}
    )
  end

  defp wait_file(path), do: wait_until(fn -> File.exists?(path) end)

  defp wait_until(fun, tries \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    try do
      if fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            wait_until(fun, tries - 1)
          )
    rescue
      _ ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end

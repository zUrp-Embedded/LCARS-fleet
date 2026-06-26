defmodule Fleet.TaskMonitorTest do
  @moduledoc """
  DN ring1/fleet-task-monitor. `map_event/1` pur (async) + intégration
  GenServer FS (tmp_dir async-safe, name unique, `subscribe: false`).
  Contrat Bus canon `%Fleet.Event{type:, payload:, correlation_id:, pod_id:}`
  (R2b — D1 schema unique, ex-tuple legacy retiré).
  """
  use ExUnit.Case, async: true

  alias Fleet.Event
  alias Fleet.TaskMonitor

  @pfx "lcars-fleet-"

  # Helper : construit la struct canon `%Fleet.Event{}`. La source est
  # ignorée par le consommateur (dashboard multi-source) — on garde une
  # source plausible par event (cf. intersections cross-docs DN).
  defp ev(type, opts \\ []) do
    Event.new(Keyword.get(opts, :source, :spawner), type,
      correlation_id: Keyword.get(opts, :ticket),
      pod_id: Keyword.get(opts, :pod_id),
      payload: Keyword.get(opts, :payload, %{})
    )
  end

  describe "map_event/1 — mapping pur (DN §Mapping)" do
    test "dispatch_started → create in_progress, id+title canon" do
      assert {:create, id, %{"title" => t, "status" => "in_progress"} = task} =
               TaskMonitor.map_event(
                 ev(:dispatch_started,
                   ticket: "491",
                   payload: %{"role" => "engineer", "brief" => "fleet_gk"}
                 )
               )

      assert id == @pfx <> "dispatch-491"
      assert t == "⚙️ engineer #491: fleet_gk"
      assert task["metadata"]["lcars"] == true
    end

    test "dispatch_completed/failed → update status" do
      assert {:update, "lcars-fleet-dispatch-7", %{"status" => "completed"}} =
               TaskMonitor.map_event(ev(:dispatch_completed, ticket: "7"))

      assert {:update, "lcars-fleet-dispatch-7", %{"status" => "failed"}} =
               TaskMonitor.map_event(ev(:dispatch_failed, ticket: "7"))
    end

    test "gatekeeper spawned/terminated" do
      assert {:create, "lcars-fleet-gk-projX", %{"status" => "in_progress"}} =
               TaskMonitor.map_event(
                 ev(:gatekeeper_spawned, source: :starfleet, payload: %{"slug" => "projX"})
               )

      assert {:update, "lcars-fleet-gk-projX", %{"status" => "completed"}} =
               TaskMonitor.map_event(
                 ev(:gatekeeper_terminated, source: :starfleet, payload: %{"slug" => "projX"})
               )
    end

    test "pipeline_stage_transition → update title" do
      assert {:update, "lcars-fleet-dispatch-9", %{"title" => title}} =
               TaskMonitor.map_event(
                 ev(:pipeline_stage_transition,
                   source: :pipeline,
                   ticket: "9",
                   payload: %{"stage" => "code-review"}
                 )
               )

      assert title =~ "code-review"
    end

    test "ticket_new_route_architect → create pending" do
      assert {:create, "lcars-fleet-ticket-42", %{"status" => "pending"} = task} =
               TaskMonitor.map_event(
                 ev(:ticket_new_route_architect, ticket: "42", payload: %{"title" => "bug X"})
               )

      assert task["title"] =~ "Ticket #42: bug X"
    end

    test "event inconnu → :ignore (défensif)" do
      assert :ignore = TaskMonitor.map_event(ev(:something_else))

      # défensif : payload absent ne crash pas. Le ticket = correlation_id ; absent (nil) → pas
      # de défaut fabriqué "?", l'id porte l'absence honnêtement (suffixe vide).
      assert {:create, "lcars-fleet-dispatch-", %{"status" => "in_progress"}} =
               TaskMonitor.map_event(ev(:dispatch_started))
    end

    test "ticket = correlation_id (canon) ; legacy payload[\"ticket\"] ignoré" do
      # correlation_id est la SEULE source du ticket : même si un payload legacy porte
      # un "ticket", l'id suit le correlation_id, pas le payload.
      assert {:update, "lcars-fleet-dispatch-491", _} =
               TaskMonitor.map_event(
                 ev(:dispatch_completed, ticket: "491", payload: %{"ticket" => "999"})
               )
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
        ev(:dispatch_started, ticket: "491", payload: %{"role" => "eng", "brief" => "b"})
      )

      assert wait_file(f)
      assert %{"status" => "in_progress"} = f |> File.read!() |> Jason.decode!()
      refute File.exists?(f <> ".tmp"), "écriture non-atomique (tmp résiduel)"

      send(pid, ev(:dispatch_completed, ticket: "491"))

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
      send(pid, ev(:totally_unknown))
      # Mi14 : :sys.get_state = barrière (l'event inconnu est traité avant, FIFO).
      _ = :sys.get_state(pid)
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

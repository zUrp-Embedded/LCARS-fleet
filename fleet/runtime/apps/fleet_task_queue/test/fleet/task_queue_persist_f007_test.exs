defmodule Fleet.TaskQueue.PersistF007Test do
  # async: false — capture_log global (swap backend logger) : isolation hors des tests concurrents.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias Fleet.TaskQueue
  alias Fleet.TaskQueue.Server

  # F-007 : un échec d'écriture de state.json ne dégrade plus en SILENCE (ex-Logger.warning). Il est
  # loggé **error** (durabilité du point de recovery rompue) ET le broker SURVIT (pas de crash : un
  # blip disque ne doit pas tuer les work items en vol ; réconciliation par le rail forge-driven).
  test "persist write échoue → Logger.error (loud) + broker survit", %{tmp_dir: tmp_dir} do
    topic = "fleet.events.test.f007.#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Fleet.PubSub, topic)

    # state_path dont le parent est un FICHIER régulier → `File.mkdir_p!` lève → rescue persist.
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "x")
    bad_path = Path.join([blocker, "nested", "state.json"])

    {:ok, q} =
      start_supervised({Server, name: nil, topic: topic, state_path: bad_path}, id: :q_f007)

    log =
      capture_log(fn ->
        assert {:ok, _task} = TaskQueue.enqueue(q, "pod-A", %{brief: "fix X"})

        # enqueue → handle_call synchrone → persist tente l'écriture → échec loggé avant le reply.
      end)

    assert log =~ "persist ÉCHEC"
    assert log =~ "durabilité"

    # le broker n'a PAS crashé : le work item est toujours servi depuis la RAM.
    assert {:ok, %{state: :assigned}} = TaskQueue.get_for_pod(q, "pod-A")
  end
end

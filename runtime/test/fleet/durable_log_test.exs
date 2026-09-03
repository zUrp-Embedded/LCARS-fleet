defmodule Fleet.DurableLogTest do
  # async: false — `:logger.add_handler` is a NODE-GLOBAL registration.
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  BL-6-41 — `config :logger, level:` was the project's only logger config: every load-bearing
  warning lived in the daemon's tmux ring buffer and died with it.

  What is pinned here is the CONTRACT, not the formatting: warning+ reaches the file, info does
  not, the parent directory is created (a handler that installs and writes nowhere is the exact
  defect this closes), and a failure to install never takes the boot down — a trace that refuses
  to let the fleet start has become the incident it was meant to record.
  """

  alias Fleet.DurableLog

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    path = Path.join([tmp, "nested", "log", "fleet.log"])
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :durable_log, path: path, level: :warning)
    on_exit(fn -> :logger.remove_handler(:lcars_durable_log) end)
    {:ok, path: path}
  end

  defp read_log(path) do
    # `logger_std_h` writes asynchronously; sync/1 flushes it, so no sleep and no polling.
    :ok = :logger_std_h.filesync(:lcars_durable_log)
    File.read!(path)
  end

  test "warning+ lands on disk, and the parent directory is CREATED", %{path: path} do
    refute File.exists?(Path.dirname(path))

    assert :ok = DurableLog.attach()
    assert File.dir?(Path.dirname(path))

    Logger.warning("publish_deadline fired for pod-42")
    Logger.error("pr-open-fail issue-7")

    trace = read_log(path)
    assert trace =~ "publish_deadline fired for pod-42"
    assert trace =~ "pr-open-fail issue-7"

    # NO ANSI. Measured on a live bench before this assertion existed: the file carried
    # `\e[33m`/`\e[0m` around every line, inherited from the console's colour setting. A trace
    # exists to be read after the fact — escape codes break a grep and a parser alike.
    refute trace =~ "\e["
  end

  test "info does NOT land — a line per routine pass buries the one that matters", %{path: path} do
    assert :ok = DurableLog.attach()

    Logger.info("nominal tick, nothing to do")
    Logger.warning("the line an incident review looks for")

    trace = read_log(path)
    refute trace =~ "nominal tick"
    assert trace =~ "the line an incident review looks for"
  end

  test "attaching twice is a no-op, not an error (supervisor restart, double call)" do
    assert :ok = DurableLog.attach()
    assert :ok = DurableLog.attach()

    assert [:lcars_durable_log] =
             Enum.filter(:logger.get_handler_ids(), &(&1 == :lcars_durable_log))
  end

  test "no config = disabled, and `path/0` says so rather than guessing" do
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :durable_log, nil)

    assert :ok = DurableLog.attach()
    assert DurableLog.path() == nil
    refute :lcars_durable_log in :logger.get_handler_ids()
  end

  test "an un-creatable path does NOT take the boot down — it warns and names the reason", %{
    tmp_dir: tmp
  } do
    # A FILE where the log's parent directory should be: mkdir_p fails with :enotdir.
    blocker = Path.join(tmp, "blocker")
    File.write!(blocker, "")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :durable_log, path: Path.join(blocker, "f.log"))

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = DurableLog.attach() end)

    assert log =~ "DurableLog: NOT installed"
    # The consequence is spelled out: a bare "could not install" tells an operator nothing about
    # what they just lost.
    assert log =~ "no recoverable trace"
    refute :lcars_durable_log in :logger.get_handler_ids()
  end
end

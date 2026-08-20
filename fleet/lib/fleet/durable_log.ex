defmodule Fleet.DurableLog do
  use Boundary, deps: [], exports: []
  require Logger

  @moduledoc """
  The warning-and-above trace, ON DISK (BL-6-41).

  `config :logger, level:` was the project's ONLY logger configuration — no file handler, no
  rotation. Every load-bearing warning (a `publish_deadline` firing, a drift, a `pr-open-fail`, a
  swallowed arrival chrono) lived in the daemon's tmux ring buffer and died with it.

  `Fleet.Spawner.Pod` names the consequence at the exact spot where it bites: *"THIS WARNING IS
  THE ONLY TRACE, AND IT IS NOT RECOVERABLE — nobody can find out AFTER THE FACT whether this ever
  fired. Not for lack of access, because nothing records it."* The comment left the decision open
  and nobody took it. Taken here.

  ## The two decisions the item asked for

  **Which level becomes durable: `warning` and above.** Not `info`, and the reason is the same one
  that keeps the poller's nominal tick silent — a rail that writes a line per routine pass buries
  the one line that matters. Warning is the level at which this codebase already says "something
  degraded"; below it there is nothing an incident review would look for.

  **Where: `<human home>/.lcars/log/fleet.log`**, beside `fleet_v2.env` and the rest of the
  human's LCARS state, rotated. NOT under the release: a release directory is replaced by the next
  deploy, and a trace that a deploy erases is not a trace.

  ## What this is NOT

  It is not the old domain audit NDJSON (mort avec le rail de severite max, brouette 2026-08-19)
  — that one was a business
  ledger with its own schema and its own two producers — tous morts avec lui, donc il ne reste rien
  a lui reserver.
  This is the operational trace: whatever any module chose to log at warning or above, in the
  order it happened, surviving the process. Merging them would give the ledger a shape nobody can
  parse and the trace a filter nobody wants.

  ## Rotation, and why the console stays

  OTP's own `logger_std_h` rotates (`max_no_bytes` + `max_no_files`) — no dependency, no custom
  writer, and the same bounds the container already applies to its json-file driver (10 MB × 5).
  The default console handler is untouched: a fleet whose operator is watching a pane must keep
  answering in that pane. This handler is ADDED, never substituted.

  Absent config = disabled, and it stays disabled in `:test`. A suite that appends to the human's
  real log would both pollute it and make the tests depend on a writable home.
  """

  @handler_id :lcars_durable_log
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  @doc """
  Adds the file handler if `:lcars_fleet, :durable_log` names a path; otherwise a no-op.

  Returns `:ok` in every case — INCLUDING a failure to install, which is logged and swallowed.
  The trace is a safety net, and a net that refuses to let the fleet boot has become the incident
  it was meant to record. The one thing it must never do is fail silently, hence the log line and
  its named reason.
  """
  @spec attach() :: :ok
  def attach do
    case Application.get_env(:lcars_fleet, :durable_log) do
      nil -> :ok
      opts -> do_attach(opts)
    end
  end

  @doc "Path the handler writes to, or `nil` when durable logging is off. For probes and the deck."
  @spec path() :: Path.t() | nil
  def path do
    case Application.get_env(:lcars_fleet, :durable_log) do
      nil -> nil
      opts -> Keyword.get(opts, :path)
    end
  end

  defp do_attach(opts) do
    path = Keyword.fetch!(opts, :path)

    # `mkdir_p` first: `logger_std_h` does not create the parent directory, and its failure mode is
    # a handler that installs and then silently writes nowhere — the exact shape of the defect
    # this module exists to close.
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> add_handler(path, opts)
      {:error, reason} -> warn_off(path, {:mkdir, reason})
    end
  end

  defp add_handler(path, opts) do
    config = %{
      config: %{
        type: {:file, String.to_charlist(path)},
        max_no_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
        max_no_files: Keyword.get(opts, :max_files, @default_max_files),
        # Rotation compresses the closed files: a warning trace is mostly repeated text, and the
        # bound above is a DISK budget, so compression buys retention rather than space.
        compress_on_rotate: true
      },
      level: Keyword.get(opts, :level, :warning),
      # `colors: [enabled: false]` — NOT cosmetic. Measured 2026-08-03 on a live bench: the file
      # came out carrying `\e[33m`/`\e[0m` around every line, because the formatter inherits the
      # console's colour setting. A trace exists to be READ AFTER THE FACT, by a human grepping or
      # an agent parsing; escape codes break both (`grep "^\[warning\]"` matches nothing, and every
      # line has invisible bytes at its ends). Colour belongs to a terminal, not to a file.
      formatter:
        Logger.Formatter.new(
          format: "$time $metadata[$level] $message\n",
          colors: [enabled: false]
        )
    }

    case :logger.add_handler(@handler_id, :logger_std_h, config) do
      :ok ->
        Logger.info("DurableLog: warning+ trace to #{path} (rotated)")

      # Already installed: a supervisor restart of the app, or a second call. Not a failure —
      # the handler is global to the node, and one is exactly what we want.
      {:error, {:already_exist, _}} ->
        :ok

      {:error, reason} ->
        warn_off(path, reason)
    end
  end

  defp warn_off(path, reason) do
    Logger.warning(
      "DurableLog: NOT installed (path=#{path} reason=#{inspect(reason)}) — warnings stay " <>
        "volatile, an incident after this point leaves no recoverable trace"
    )

    :ok
  end
end

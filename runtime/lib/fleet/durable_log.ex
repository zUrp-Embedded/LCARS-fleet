defmodule Fleet.DurableLog do
  use Boundary, deps: [], exports: []
  require Logger

  @moduledoc """
  Adds a rotating file trace alongside console logging, using OTP logger_std_h.
  The default threshold is warning, keeping routine info out of incident traces; opts may override it.
  Rotation defaults to 10 MiB and five archive files, compressed, with ANSI colours disabled.
  This is operational log text, separate from domain audit ledgers and their schemas.

  runtime.exs resolves the operator's path. Choose a location outside the replaceable release;
  this module does not enforce that placement. Missing config disables the handler, as in normal
  test config; tests that attach it must supply their own temporary path.
  """

  @handler_id :lcars_durable_log
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  @doc """
  Adds the file handler if `:lcars_fleet, :durable_log` names a path; otherwise a no-op.

  Directory-creation and handler-installation errors are logged and return :ok so logging failure
  does not prevent boot. Malformed opts can still raise; an existing handler is left unchanged.
  """
  @spec attach() :: :ok
  def attach do
    case Application.get_env(:lcars_fleet, :durable_log) do
      nil -> :ok
      opts -> do_attach(opts)
    end
  end

  @doc "Configured path, or nil without one; does not verify that a handler is installed or writing."
  @spec path() :: Path.t() | nil
  def path do
    case Application.get_env(:lcars_fleet, :durable_log) do
      nil -> nil
      opts -> Keyword.get(opts, :path)
    end
  end

  defp do_attach(opts) do
    path = Keyword.fetch!(opts, :path)

    # Create the parent explicitly so a filesystem failure is diagnosed before handler installation.
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
        # Compress closed archives; the byte threshold applies before compression.
        compress_on_rotate: true
      },
      level: Keyword.get(opts, :level, :warning),
      # Do not inherit console ANSI colours into files consumed by grep or parsers.
      formatter:
        Logger.Formatter.new(
          format: "$time $metadata[$level] $message\n",
          colors: [enabled: false]
        )
    }

    case :logger.add_handler(@handler_id, :logger_std_h, config) do
      :ok ->
        Logger.info("DurableLog: warning+ trace to #{path} (rotated)")

      # Node-global registration can survive an application supervisor restart.
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

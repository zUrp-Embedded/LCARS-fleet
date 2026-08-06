defmodule Fleet.Spawner.Pod.Fs do
  @moduledoc """
  Non-raising filesystem writes for pod provisioning.

  Failures retain the operation, path and filesystem reason so callers can enter their normal
  failed transition instead of crashing the pod process.

  **Last revised**: 2026-08-02
  """

  @doc "Creates a directory tree and returns a contextual `:mkdir_failed` error."
  @spec safe_mkdir_p(Path.t()) :: :ok | {:error, {:mkdir_failed, Path.t(), File.posix()}}
  def safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  @doc "Writes a file and returns a contextual `:write_failed` error."
  @spec safe_write(Path.t(), iodata()) :: :ok | {:error, {:write_failed, Path.t(), File.posix()}}
  def safe_write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end
end

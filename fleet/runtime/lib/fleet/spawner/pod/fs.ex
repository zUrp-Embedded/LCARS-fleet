defmodule Fleet.Spawner.Pod.Fs do
  @moduledoc """
  Shared FS primitives of pod provisioning — non-bang variants of `File.write`/`File.mkdir_p`.

  The bang variants (`File.mkdir_p!`, `File.write!`, `File.rename!`) raise on
  error → brutal kill of the pod process (gen_statem) → death without a clean
  transition → state.json potentially stale/corrupt on the recovery side.
  These helpers return `{:ok | :error}` with context (path + reason) →
  propagation via `with` → clean transition_failed (state.json
  phase=failed written before `{:stop, ...}`).

  Pure deterministic FS writes: no state, no Port, no timer. Shared
  by `Fleet.Spawner.Pod` (transition chain) and its extraction island
  `Fleet.Spawner.Pod.McpProvision` (provisioning of `.mcp-fleet.json`) — one primitive,
  a single site.

  **Last revised**: 2026-07-18
  """

  @doc """
  `File.mkdir_p` non-bang: `:ok` or `{:error, {:mkdir_failed, path, reason}}` — the tag + the path
  contextualize the failed step in the caller's `transition_failed`.
  """
  @spec safe_mkdir_p(Path.t()) :: :ok | {:error, {:mkdir_failed, Path.t(), File.posix()}}
  def safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  @doc """
  `File.write` non-bang: `:ok` or `{:error, {:write_failed, path, reason}}` — the tag + the path
  contextualize the failed step in the caller's `transition_failed`.
  """
  @spec safe_write(Path.t(), iodata()) :: :ok | {:error, {:write_failed, Path.t(), File.posix()}}
  def safe_write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end
end

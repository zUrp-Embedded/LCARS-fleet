defmodule Fleet.Spawner.Pod.Fs do
  @moduledoc """
  Primitives FS partagées du provisioning pod — variantes non-bang de `File.write`/`File.mkdir_p`.

  Les variantes bang (`File.mkdir_p!`, `File.write!`, `File.rename!`) raise sur
  erreur → kill brutal du process pod (gen_statem) → mort sans transition
  propre → state.json potentiellement obsolète/corrompu côté recovery.
  Ces helpers retournent `{:ok | :error}` avec contexte (path + reason) →
  propagation via `with` → transition_failed clean (state.json
  phase=failed écrit avant `{:stop, ...}`).

  Pures écritures FS déterministes : aucun state, aucun Port, aucun timer. Partagées
  par `Fleet.Spawner.Pod` (chaîne de transition) et son île d'extraction
  `Fleet.Spawner.Pod.McpProvision` (provisioning du `.mcp-fleet.json`) — une primitive,
  un seul site.
  """

  @doc """
  `File.mkdir_p` non-bang : `:ok` ou `{:error, {:mkdir_failed, path, reason}}` — le tag + le path
  contextualisent l'étape en échec dans le `transition_failed` de l'appelant.
  """
  @spec safe_mkdir_p(Path.t()) :: :ok | {:error, {:mkdir_failed, Path.t(), File.posix()}}
  def safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  @doc """
  `File.write` non-bang : `:ok` ou `{:error, {:write_failed, path, reason}}` — le tag + le path
  contextualisent l'étape en échec dans le `transition_failed` de l'appelant.
  """
  @spec safe_write(Path.t(), iodata()) :: :ok | {:error, {:write_failed, Path.t(), File.posix()}}
  def safe_write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end
end

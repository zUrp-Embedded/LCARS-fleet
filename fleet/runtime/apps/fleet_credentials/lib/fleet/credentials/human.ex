defmodule Fleet.Credentials.Human do
  @moduledoc """
  Source UNIQUE de « l'humain de la fleet » = l'user OS du process runtime (`id -un`).

  Doctrine 2026-06-11 : la fleet ENTIÈRE tourne sous l'user de l'humain qui la lance
  (`User=<humain>`) → l'user courant EST l'humain. F027 : avant, `id -un` était shellé en
  DEUX endroits à politique d'échec divergente (`ForgeIdentity.resolve_human` → `{:error}` ;
  `Fleet.Spawner.Pod.runtime_user` → raise) → si la règle évolue, spawn-ownership (pod_dir/UID)
  et commit-identity (git author) peuvent diverger et casser l'invariant F-01. Tout passe ici.
  """

  @doc "L'humain courant (`id -un`). `{:ok, login}` | `{:error, reason}`."
  @spec current() :: {:ok, String.t()} | {:error, term()}
  def current do
    case System.cmd("id", ["-un"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      other -> {:error, {:human_unresolved, other}}
    end
  end

  @doc "L'humain courant, fail-loud (un défaut littéral masquerait un trou de câblage — I-CBC)."
  @spec current!() :: String.t()
  def current! do
    case current() do
      {:ok, human} ->
        human

      {:error, reason} ->
        raise "Fleet.Credentials.Human: user courant irrésoluble (#{inspect(reason)})"
    end
  end
end

defmodule Fleet.Credentials.Human do
  @moduledoc """
  Source UNIQUE de « l'humain de la fleet » = l'user OS du process runtime (`id -un`).

  Doctrine 2026-06-11 : la fleet ENTIÈRE tourne sous l'user de l'humain qui la lance
  (`User=<humain>`) → l'user courant EST l'humain. SOURCE UNIQUE de `id -un` : tout consommateur
  passe ici, jamais un `id -un` shellé en propre. Sinon deux résolveurs à politique d'échec
  divergente (`ForgeIdentity.resolve_human` → `{:error}` ; `Fleet.Spawner.Pod.LaunchEnv.runtime_user` → raise) ;
  si la règle évolue, spawn-ownership (pod_dir/UID) et commit-identity (git author) divergent.
  """

  @doc "L'humain courant (`id -un`). `{:ok, login}` | `{:error, reason}`."
  @spec current() :: {:ok, String.t()} | {:error, term()}
  def current do
    case System.cmd("id", ["-un"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      other -> {:error, {:human_unresolved, other}}
    end
  end

  @doc "L'humain courant, fail-loud (un défaut littéral masquerait un trou de câblage)."
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

defmodule Fleet.Credentials.Human do
  @moduledoc """
  SINGLE source of "the fleet's human" = the OS user of the runtime process (`id -un`).

  Runtime model: the ENTIRE fleet runs under the user of the human who launches it (the human runs
  `bin/fleet_v2`; the BEAM inherits their UID — there is no systemd `User=` directive) → the current
  user IS the human. SINGLE SOURCE of `id -un`: every consumer
  comes through here, never an `id -un` shelled on its own. Otherwise two resolvers with a
  divergent failure policy (`ForgeIdentity.resolve_human` → `{:error}`; `Fleet.Spawner.Pod.LaunchEnv.runtime_user` → raise);
  if the rule evolves, spawn-ownership (pod_dir/UID) and commit-identity (git author) diverge.
  """

  @doc "The current human (`id -un`). `{:ok, login}` | `{:error, reason}`."
  @spec current() :: {:ok, String.t()} | {:error, term()}
  def current do
    case System.cmd("id", ["-un"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      other -> {:error, {:human_unresolved, other}}
    end
  end

  @doc "The current human, fail-loud (a literal default would mask a wiring hole)."
  @spec current!() :: String.t()
  def current! do
    case current() do
      {:ok, human} ->
        human

      {:error, reason} ->
        raise "Fleet.Credentials.Human: current user unresolvable (#{inspect(reason)})"
    end
  end
end

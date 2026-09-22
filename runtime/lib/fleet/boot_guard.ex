defmodule Fleet.BootGuard do
  use Boundary, deps: [], exports: []

  @moduledoc """
  GUARD B / R-no-root-runtime: who may run the fleet daemon on this machine.

  Refuses root, the reserved SYSADMIN seat, and any uid outside the human range the system
  declares. A fleet under the seat would run sudo-capable pods, the exact inverse of the sandbox.
  This is cooperative launch hygiene, not an anti-adversary boundary.

  Two machine facts decide, and neither has a coded default:

    * the seat, read from the provisioned file with NO numeric fallback. A process env value could
      otherwise redefine the seat and disarm the guard, so `LCARS_SEAT_UID_FILE` moves the path
      (tests) and nothing moves the value. This reader does not verify file ownership.
    * the system/human boundary, read from `login.defs` (`PASSWD_DEFS` overrides the path), the
      same source as `bin/fleet`, human convergence and provisioning. Matching uses the first
      column-zero declaration's digit prefix; it validates neither the whole line nor min/max order.

  An unreadable fact REFUSES: a boot that cannot be verified is not a boot that passes.

  `verify/1` returns `:ok` or `{:error, message}` — `config/runtime.exs` raises that message, and
  nothing else in the tree decides this. The readers are injectable so the witnesses drive every
  branch without launching a VM per case.
  """

  @seat_path_default "/etc/lcars/seat.uid"
  @bounds_path_default "/etc/login.defs"

  @typedoc "A successful `id -u`, or why it could not be read."
  @type uid_reading :: String.t() | {:unreadable, String.t()}

  @doc """
  Judges this process against the machine's facts.

  Options, all defaulted from the machine: `:uid_reading` (see `t:uid_reading/0`),
  `:seat_uid_path`, `:uid_bounds_path`.
  """
  @spec verify(keyword()) :: :ok | {:error, String.t()}
  def verify(opts \\ []) do
    seat_path =
      Keyword.get_lazy(opts, :seat_uid_path, fn ->
        System.get_env("LCARS_SEAT_UID_FILE", @seat_path_default)
      end)

    bounds_path =
      Keyword.get_lazy(opts, :uid_bounds_path, fn ->
        System.get_env("PASSWD_DEFS", @bounds_path_default)
      end)

    with {:ok, seat} <- seat_uid(seat_path),
         {:ok, min} <- uid_bound(bounds_path, "UID_MIN"),
         {:ok, max} <- uid_bound(bounds_path, "UID_MAX") do
      judge(Keyword.get_lazy(opts, :uid_reading, &read_uid/0), seat, min, max)
    end
  end

  @doc """
  Reads this process's uid through `id -u`, or why it could not be read.

  A failed execution is not judged here: `verify/1` reads the machine policy files first, so an
  unreadable seat or boundary refuses with its own cause rather than with this one.
  """
  @spec read_uid() :: uid_reading()
  def read_uid do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out)
      {out, code} -> {:unreadable, "`id -u` exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e -> {:unreadable, Exception.message(e)}
  end

  defp seat_uid(path) do
    with {:ok, body} <- File.read(path),
         {n, ""} when n >= 0 <- Integer.parse(String.trim(body)) do
      {:ok, Integer.to_string(n)}
    else
      _ ->
        {:error,
         "R-no-seat: the seat UID could not be established (#{path} missing or not " <>
           "an integer) — GUARD B refuses a boot it cannot verify. This machine is not " <>
           "installed: on a workstation, `deploy/workstation up` sets it; in a container, the boot " <>
           "init sets it (`deploy/container config` from the host, then `deploy/container up`)."}
    end
  end

  defp uid_bound(path, name) do
    with {:ok, body} <- File.read(path),
         [_, raw] <- Regex.run(~r/^#{name}\s+(\d+)/m, body),
         {n, ""} <- Integer.parse(raw) do
      {:ok, n}
    else
      _ ->
        {:error,
         "R-no-uid-min: the system/human boundary could not be established (#{name} " <>
           "unreadable in #{path}) — GUARD B refuses a boot it cannot verify. The " <>
           "bound is declared by the system, not by this process: fix #{path}."}
    end
  end

  defp judge("0", _seat, _min, _max) do
    {:error,
     "R-no-root-runtime: the fleet daemon refuses to run as root " <>
       "(launch under your human UID via bin/fleet, never as root)"}
  end

  defp judge(seat, seat, _min, _max) do
    {:error,
     "R-no-root-runtime: the fleet daemon refuses to run under the SYSADMIN seat " <>
       "(uid #{seat}) — GUARD B: a fleet under the seat would run sudo-capable " <>
       "pods, the exact inverse of the sandbox. The seat administers the machine; a fleet human " <>
       "runs the fleet (bin/fleet under a worker account)."}
  end

  defp judge({:unreadable, why}, _seat, _min, _max) do
    {:error,
     "R-no-root-runtime: the runtime UID could not be established (#{why}) — the anti-root " <>
       "guard refuses a boot it cannot verify (launch via bin/fleet)"}
  end

  defp judge(uid, _seat, min, max) when is_binary(uid) do
    case Integer.parse(uid) do
      {n, ""} when n < min ->
        {:error,
         "R-no-root-runtime: the fleet daemon refuses to run under a SYSTEM account " <>
           "(uid #{n} < UID_MIN #{min}) — the fleet runs under a HUMAN uid " <>
           "(launch via bin/fleet under a worker account)"}

      {n, ""} when n > max ->
        {:error,
         "R-no-root-runtime: the fleet daemon refuses to run under an account ABOVE the " <>
           "human range (uid #{n} > UID_MAX #{max}) — `nobody` and the high service " <>
           "uids are not fleet humans; the fleet runs under a HUMAN uid (launch via " <>
           "bin/fleet under a worker account)"}

      _human_or_unparseable ->
        :ok
    end
  end
end

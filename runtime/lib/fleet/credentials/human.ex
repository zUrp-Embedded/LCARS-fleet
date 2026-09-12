defmodule Fleet.Credentials.Human do
  @moduledoc """
  Single bounded resolver for the fleet human's OS login and UID. The runtime
  inherits its launcher's user, which anchors both workspace ownership and commit identity.
  """

  @doc "The current human (`id -un`). `{:ok, login}` | `{:error, reason}`."
  @spec current() :: {:ok, String.t()} | {:error, term()}
  def current do
    # Bounded (Shell authority): `id` resolves through NSS — a hung backend (LDAP/SSSD)
    # would hold the caller indefinitely on the unbounded form.
    case Fleet.Credentials.Shell.run("id", ["-un"], timeout_ms: 5_000) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
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

  @doc """
  Parses the current OS UID from bounded id -u output. SessionId uses it to distinguish
  humans sharing an OAuth account. The parser accepts an integer prefix without checking
  sign or trailing text; real id output supplies the non-negative UID promised by the spec.
  """
  @spec current_uid() :: {:ok, non_neg_integer()} | {:error, term()}
  def current_uid do
    case Fleet.Credentials.Shell.run("id", ["-u"], timeout_ms: 5_000) do
      {:ok, {out, 0}} ->
        case Integer.parse(String.trim(out)) do
          {uid, _} -> {:ok, uid}
          :error -> {:error, {:uid_unparseable, out}}
        end

      other ->
        {:error, {:uid_unresolved, other}}
    end
  end

  @doc "The current human's OS UID, fail-loud."
  @spec current_uid!() :: non_neg_integer()
  def current_uid! do
    case current_uid() do
      {:ok, uid} ->
        uid

      {:error, reason} ->
        raise "Fleet.Credentials.Human: current UID unresolvable (#{inspect(reason)})"
    end
  end
end

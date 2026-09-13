defmodule Fleet.TestEnv do
  use Boundary, deps: [Fleet.Credentials], exports: []

  @moduledoc """
  Token-fixture and Application-env helpers. Call restoration helpers from setup/test
  in the test process. fetch_env preserves absent keys versus keys set to nil or false;
  on_exit callbacks unwind nested changes in reverse order.

  Environment writes are global to the node: tests using them must be async: false.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Returns a path under System.tmp_dir!() containing the OS pid and a per-VM counter.
  This separates concurrent VMs sharing a pid namespace and calls within one VM, but
  stale paths can recur after pid reuse. Creates nothing; callers own creation and cleanup.
  """
  @spec tmp_path(String.t()) :: Path.t()
  def tmp_path(prefix) when is_binary(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  @doc """
  Writes the token at RoleIdentity.token_path/1, creating parent directories, and returns
  that path. Account-derived filenames distinguish catalogue tiers. Raises if the role
  cannot resolve to an account or the write fails.
  """
  def put_role_token!(role, content) do
    case Fleet.Credentials.RoleIdentity.token_path(role) do
      {:ok, path} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        path

      :error ->
        raise "TestEnv.put_role_token!: no forge login for #{inspect(role)} — the catalogue in " <>
                "scope declares no such role, so no account and no token can exist for it. " <>
                "Name a role the fixture's catalogue actually carries."
    end
  end

  @doc """
  Removes the resolved token path recursively and returns it, even if already absent.
  Raises for an undeclared role or removal error. Use to remove a signer token explicitly
  when a fixture otherwise provisions all signers required at boot.
  """
  def delete_role_token!(role) do
    case Fleet.Credentials.RoleIdentity.token_path(role) do
      {:ok, path} ->
        _ = File.rm_rf!(path)
        path

      :error ->
        raise "TestEnv.delete_role_token!: no forge login for #{inspect(role)} — the catalogue " <>
                "in scope declares no such role. Name a role the fixture's catalogue carries."
    end
  end

  @doc """
  Sets an Application value after registering restoration on test exit.
  The write is global; use only in synchronous tests.
  """
  def put_env_restoring(app, key, value) do
    restore_env_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Registers restoration of the current value or absence on test exit without changing it.
  Call before direct mutations in a synchronous test.
  """
  def restore_env_on_exit(app, key) do
    prev = Application.fetch_env(app, key)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end

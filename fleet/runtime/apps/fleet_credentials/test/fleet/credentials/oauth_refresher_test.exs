defmodule Fleet.Credentials.OAuthRefresherTest do
  use ExUnit.Case, async: false

  alias Fleet.Credentials.OAuthRefresher
  alias Fleet.Credentials.OAuthRefresher.StubBackend

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev_root = Application.get_env(:fleet_credentials, :creds_root)
    prev_backend = Application.get_env(:fleet_credentials, :oauth_refresh_backend)
    prev_backoff = Application.get_env(:fleet_credentials, :refresh_retry_backoff_ms)

    Application.put_env(:fleet_credentials, :creds_root, tmp_dir)
    Application.put_env(:fleet_credentials, :oauth_refresh_backend, StubBackend)
    Application.put_env(:fleet_credentials, :refresh_retry_backoff_ms, 50)

    {:ok, _} = ensure_registries()

    on_exit(fn ->
      StubBackend.clear()

      case prev_root do
        nil -> Application.delete_env(:fleet_credentials, :creds_root)
        v -> Application.put_env(:fleet_credentials, :creds_root, v)
      end

      case prev_backend do
        nil -> Application.delete_env(:fleet_credentials, :oauth_refresh_backend)
        v -> Application.put_env(:fleet_credentials, :oauth_refresh_backend, v)
      end

      case prev_backoff do
        nil -> Application.delete_env(:fleet_credentials, :refresh_retry_backoff_ms)
        v -> Application.put_env(:fleet_credentials, :refresh_retry_backoff_ms, v)
      end
    end)

    :ok
  end

  defp ensure_registries do
    # In test mode the application doesn't auto-start sub-supervisor;
    # manually start the two registries needed by OAuthRefresher.
    case Registry.start_link(keys: :unique, name: Fleet.Credentials.Registry) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
    |> case do
      {:ok, _} ->
        case Registry.start_link(keys: :duplicate, name: Fleet.Credentials.PubSub) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  defp seed_coffre(role, refresh_token, expires_at_ms) do
    role_dir = Fleet.Credentials.coffre_path(role, "")
    File.mkdir_p!(role_dir)
    File.write!(Path.join(role_dir, "oauth_refresh_token"), refresh_token)
    File.write!(Path.join(role_dir, "oauth_access_token"), "at-initial")
    File.write!(Path.join(role_dir, "oauth_scopes"), "user:inference user:sessions:claude_code")
    File.write!(Path.join(role_dir, "expires_at"), to_string(expires_at_ms))
  end

  describe "GenServer lifecycle" do
    test "starts and reads coffre at init" do
      future = :os.system_time(:millisecond) + 60 * 60 * 1_000
      seed_coffre("engineer", "rt-old", future)

      assert {:ok, pid} = OAuthRefresher.start_link("engineer")
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "init fails when coffre missing" do
      assert {:error, {:coffre_load_failed, _}} = OAuthRefresher.start_link("ghost-role")
    end

    test "fires refresh immediately when expires_at is past" do
      past = :os.system_time(:millisecond) - 60_000
      seed_coffre("engineer", "rt-stale", past)

      StubBackend.set_parent(self())

      StubBackend.set_next_reply(
        {:ok,
         %{
           "refreshToken" => "rt-fresh",
           "accessToken" => "at-fresh",
           "scopes" => ["user:inference", "user:sessions:claude_code"],
           "expiresAt" => :os.system_time(:millisecond) + 60 * 60 * 1_000
         }}
      )

      {:ok, pid} = OAuthRefresher.start_link("engineer")

      assert_receive {:refresh_called, "rt-stale"}, 1_000

      Process.sleep(50)

      assert File.read!(Fleet.Credentials.coffre_path("engineer", "oauth_refresh_token")) ==
               "rt-fresh"

      GenServer.stop(pid)
    end

    test "stops with auth_refresh_failed on :unauthorized" do
      past = :os.system_time(:millisecond) - 60_000
      seed_coffre("engineer", "rt-revoked", past)

      StubBackend.set_parent(self())
      StubBackend.set_next_reply({:error, :unauthorized})

      Process.flag(:trap_exit, true)
      {:ok, pid} = OAuthRefresher.start_link("engineer")

      assert_receive {:refresh_called, "rt-revoked"}, 1_000
      assert_receive {:EXIT, ^pid, :auth_refresh_failed}, 1_000
    end

    test "broadcasts :auth_refreshed to subscribers" do
      past = :os.system_time(:millisecond) - 60_000
      seed_coffre("engineer", "rt", past)

      {:ok, _} = Registry.register(Fleet.Credentials.PubSub, {:auth, "engineer"}, nil)

      StubBackend.set_parent(self())

      StubBackend.set_next_reply(
        {:ok,
         %{
           "refreshToken" => "rt-new",
           "accessToken" => "at-new",
           "scopes" => ["user:inference", "user:sessions:claude_code"],
           "expiresAt" => :os.system_time(:millisecond) + 60 * 60 * 1_000
         }}
      )

      {:ok, pid} = OAuthRefresher.start_link("engineer")

      assert_receive {:auth_refreshed, "engineer"}, 1_000

      GenServer.stop(pid)
    end
  end

  describe "name/1" do
    test "returns :via tuple registry-based" do
      assert {:via, Registry, {Fleet.Credentials.Registry, {:refresher, "engineer"}}} =
               OAuthRefresher.name("engineer")
    end
  end
end

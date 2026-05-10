defmodule Fleet.Credentials.StoreDocTest do
  # Module dédié aux doctests — pas de setup tmp_dir pour les exemples
  # purs (`encode_scopes/1`). Sépare le module test à setup partagé
  # (StoreTest, intégration FS) des doctests qui n'en ont pas besoin.
  use ExUnit.Case, async: true

  doctest Fleet.Credentials.Store
end

defmodule Fleet.Credentials.StoreTest do
  use ExUnit.Case, async: false

  alias Fleet.Credentials.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev = Application.get_env(:fleet_credentials, :creds_root)
    Application.put_env(:fleet_credentials, :creds_root, tmp_dir)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:fleet_credentials, :creds_root)
        v -> Application.put_env(:fleet_credentials, :creds_root, v)
      end
    end)

    :ok
  end

  describe "write_atomic_coffre/2" do
    test "writes 4 files atomically (tmp + rename)" do
      creds = %{
        "refreshToken" => "rt-new",
        "accessToken" => "at-new",
        "scopes" => ["user:inference", "user:sessions:claude_code"],
        "expiresAt" => 9_999_999_999_999
      }

      assert :ok = Store.write_atomic_coffre("engineer", creds)

      role_dir = Fleet.Credentials.coffre_path("engineer", "")
      assert File.read!(Path.join(role_dir, "oauth_refresh_token")) == "rt-new"
      assert File.read!(Path.join(role_dir, "oauth_access_token")) == "at-new"

      assert File.read!(Path.join(role_dir, "oauth_scopes")) ==
               "user:inference user:sessions:claude_code"

      assert File.read!(Path.join(role_dir, "expires_at")) == "9999999999999"
    end

    test "no leftover .tmp files after atomic write" do
      creds = %{
        "refreshToken" => "rt",
        "accessToken" => "at",
        "scopes" => ["user:inference"],
        "expiresAt" => 1
      }

      :ok = Store.write_atomic_coffre("engineer", creds)

      role_dir = Fleet.Credentials.coffre_path("engineer", "")
      tmp_files = role_dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "."))
      assert tmp_files == []
    end

    test "scopes string passes through unchanged" do
      creds = %{
        "refreshToken" => "rt",
        "accessToken" => "at",
        "scopes" => "user:inference user:sessions:claude_code",
        "expiresAt" => 1
      }

      :ok = Store.write_atomic_coffre("engineer", creds)
      role_dir = Fleet.Credentials.coffre_path("engineer", "")

      assert File.read!(Path.join(role_dir, "oauth_scopes")) ==
               "user:inference user:sessions:claude_code"
    end
  end
end

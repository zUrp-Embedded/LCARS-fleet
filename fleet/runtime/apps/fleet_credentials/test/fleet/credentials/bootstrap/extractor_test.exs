defmodule Fleet.Credentials.Bootstrap.ExtractorTest do
  use ExUnit.Case, async: false

  alias Fleet.Credentials.Bootstrap.Extractor

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    coffre_root = Path.join(tmp_dir, "coffre")
    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(home_dir, ".claude"))
    File.mkdir_p!(coffre_root)

    prev = Application.get_env(:fleet_credentials, :creds_root)
    Application.put_env(:fleet_credentials, :creds_root, coffre_root)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:fleet_credentials, :creds_root)
        v -> Application.put_env(:fleet_credentials, :creds_root, v)
      end
    end)

    {:ok, home: home_dir, coffre_root: coffre_root}
  end

  defp write_creds_file(home, oauth_map) do
    path = Path.join([home, ".claude", ".credentials.json"])
    File.write!(path, Jason.encode!(%{"claudeAiOauth" => oauth_map}))
    path
  end

  defp valid_oauth do
    %{
      "accessToken" => "at-1",
      "refreshToken" => "rt-1",
      "expiresAt" => 9_999_999_999_999,
      "scopes" => ["user:inference", "user:sessions:claude_code"],
      "subscriptionType" => "max",
      "rateLimitTier" => "tier_1"
    }
  end

  test "extracts and writes coffre on happy path", %{home: home, coffre_root: root} do
    write_creds_file(home, valid_oauth())

    assert {:ok, "engineer"} = Extractor.extract(role: "engineer", home: home)

    assert File.read!(Path.join([root, "engineer", "oauth_refresh_token"])) == "rt-1"
    assert File.read!(Path.join([root, "engineer", "oauth_access_token"])) == "at-1"

    assert File.read!(Path.join([root, "engineer", "oauth_scopes"])) ==
             "user:inference user:sessions:claude_code"

    assert File.read!(Path.join([root, "engineer", "expires_at"])) == "9999999999999"
  end

  test "missing credentials file returns unreadable", %{home: home} do
    assert {:error, {:credentials_file_unreadable, _path, :enoent}} =
             Extractor.extract(role: "engineer", home: home)
  end

  test "invalid json returns json_invalid", %{home: home} do
    File.write!(Path.join([home, ".claude", ".credentials.json"]), "not-json{")

    assert {:error, {:credentials_json_invalid, _reason}} =
             Extractor.extract(role: "engineer", home: home)
  end

  test "missing claudeAiOauth key returns schema_invalid", %{home: home} do
    path = Path.join([home, ".claude", ".credentials.json"])
    File.write!(path, Jason.encode!(%{"unrelated" => "value"}))

    assert {:error, {:schema_invalid, ["claudeAiOauth"]}} =
             Extractor.extract(role: "engineer", home: home)
  end

  test "schema missing fields returns list of missing", %{home: home} do
    write_creds_file(home, %{
      "accessToken" => "at",
      "refreshToken" => "rt"
    })

    assert {:error, {:schema_invalid, missing}} = Extractor.extract(role: "engineer", home: home)

    assert "expiresAt" in missing
    assert "scopes" in missing
    assert "subscriptionType" in missing
    assert "rateLimitTier" in missing
  end

  test "scope-coverage check refuses install if scopes insufficient for flags", %{home: home} do
    oauth =
      valid_oauth()
      |> Map.put("scopes", ["user:inference", "user:sessions:claude_code"])

    write_creds_file(home, oauth)

    assert {:error, {:insufficient_scopes, missing}} =
             Extractor.extract(
               role: "engineer",
               home: home,
               role_profile_flags: %{"bridge_enabled" => true}
             )

    assert "user:profile" in missing
  end

  test "atomic write : no .tmp files leftover", %{home: home, coffre_root: root} do
    write_creds_file(home, valid_oauth())

    {:ok, "engineer"} = Extractor.extract(role: "engineer", home: home)

    role_dir = Path.join(root, "engineer")
    leftover = role_dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "."))
    assert leftover == []
  end
end

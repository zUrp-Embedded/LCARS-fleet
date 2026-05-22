defmodule Fleet.CredentialsTest do
  use ExUnit.Case, async: false

  doctest Fleet.Credentials

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

  defp write_coffre(role, %{} = files) do
    role_dir = Fleet.Credentials.coffre_path(role, "")
    File.mkdir_p!(role_dir)

    Enum.each(files, fn {name, content} ->
      File.write!(Path.join(role_dir, name), content)
    end)
  end

  defp profile(extra \\ %{}) do
    spec =
      Map.merge(
        %{
          "lifetime_scope" => "one-shot",
          "scope" => %{},
          "knowledge" => %{},
          "invocation" => %{},
          "injects" => %{},
          "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 60},
          "modop_set" => []
        },
        extra
      )

    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: spec
    }
  end

  describe "creds_root/0 + coffre_path/2" do
    test "creds_root reads config knob with default" do
      Application.put_env(:fleet_credentials, :creds_root, "/etc/test")
      assert Fleet.Credentials.creds_root() == "/etc/test"
    end

    test "coffre_path joins root + role + file" do
      Application.put_env(:fleet_credentials, :creds_root, "/srv/coffre")

      assert Fleet.Credentials.coffre_path("engineer", "oauth_refresh_token") ==
               "/srv/coffre/engineer/oauth_refresh_token"
    end
  end

  describe "resolve_env/2" do
    test "happy path returns RT + scopes env vars" do
      write_coffre("engineer", %{
        "oauth_refresh_token" => "rt-abc-123\n",
        "oauth_access_token" => "at-xyz-456\n",
        "oauth_scopes" => "user:inference user:sessions:claude_code\n"
      })

      assert {:ok, env} = Fleet.Credentials.resolve_env("engineer", profile())

      assert env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == "rt-abc-123"
      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "at-xyz-456"
      assert env["CLAUDE_CODE_OAUTH_SCOPES"] == "user:inference user:sessions:claude_code"
    end

    test "never injects ANTHROPIC_API_KEY (G24 invariant)" do
      write_coffre("engineer", %{
        "oauth_refresh_token" => "rt",
        "oauth_access_token" => "at",
        "oauth_scopes" => "user:inference"
      })

      {:ok, env} = Fleet.Credentials.resolve_env("engineer", profile())
      refute Map.has_key?(env, "ANTHROPIC_API_KEY")
    end

    test "useRoleCredentials=false falls back to starfleet coffre" do
      write_coffre("starfleet", %{
        "oauth_refresh_token" => "rt-starfleet",
        "oauth_access_token" => "at-starfleet",
        "oauth_scopes" => "user:inference user:sessions:claude_code"
      })

      profile = profile(%{"injects" => %{"useRoleCredentials" => false}})
      assert {:ok, env} = Fleet.Credentials.resolve_env("engineer", profile)
      assert env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == "rt-starfleet"
    end

    test "gitconfig=true adds GIT_AUTHOR + GIT_COMMITTER vars" do
      write_coffre("engineer", %{
        "oauth_refresh_token" => "rt",
        "oauth_access_token" => "at",
        "oauth_scopes" => "user:inference"
      })

      profile = profile(%{"injects" => %{"gitconfig" => true}})
      {:ok, env} = Fleet.Credentials.resolve_env("engineer", profile)

      assert env["GIT_AUTHOR_NAME"] == "LCARS-engineer"
      assert env["GIT_AUTHOR_EMAIL"] == "engineer@lcars.local"
      assert env["GIT_COMMITTER_NAME"] == "LCARS-engineer"
      assert env["GIT_COMMITTER_EMAIL"] == "engineer@lcars.local"
    end

    test "gitconfig default false omits GIT_* vars" do
      write_coffre("engineer", %{
        "oauth_refresh_token" => "rt",
        "oauth_access_token" => "at",
        "oauth_scopes" => "user:inference"
      })

      {:ok, env} = Fleet.Credentials.resolve_env("engineer", profile())
      refute Map.has_key?(env, "GIT_AUTHOR_NAME")
    end

    test "missing coffre returns :coffre_missing" do
      assert {:error, {:coffre_missing, "ghost"}} =
               Fleet.Credentials.resolve_env("ghost", profile())
    end
  end
end

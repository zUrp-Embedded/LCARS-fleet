defmodule Fleet.Credentials.ForgeIdentityFallbackTest do
  @moduledoc """
  The OS derivation of the human identity when no global Git identity exists. Serialized: it lifts
  the application-wide identity override that config/test.exs pins for every other test.
  """
  use ExUnit.Case, async: false

  alias Fleet.Credentials.ForgeIdentity

  setup do
    # config/test.exs pins an application-wide identity override; the OS derivation is what we test.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_forge_identity_override, nil)
    :ok
  end

  describe "no global Git identity" do
    # 2026-09-23: the human had no ~/.gitconfig; every fleet deliverable was committed as
    # `captain@Nico-SuperCharged` — an address no forge account carries, and the workshop guard
    # refused the fleet's own import commit for it.
    test "the email is the login's FORGE address, never login@hostname" do
      assert {:ok, id} =
               ForgeIdentity.for_role("engineer", human: "captain", git_config: fn _ -> nil end)

      assert id.author_email == "captain@lcars.local"
      assert id.committer_email == "captain@lcars.local"
      refute id.author_email =~ elem(:inet.gethostname(), 1) |> List.to_string()
    end

    test "a declared global email still wins — the human's file is theirs" do
      read = fn
        "user.email" -> "lordzurp.dev@gmail.com"
        "user.name" -> "Lord Zurp"
      end

      assert {:ok, id} = ForgeIdentity.for_role("engineer", human: "captain", git_config: read)
      assert id.author_email == "lordzurp.dev@gmail.com"
      assert id.author_name == "Lord Zurp"
    end
  end
end

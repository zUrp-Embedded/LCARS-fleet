defmodule Fleet.Pipeline.ForgeIdentityTest do
  @moduledoc """
  Z4 (forge-identité B') — l'author = l'humain du mandat (catalogue), le rôle = trailer
  `Co-authored-by: LCARS-<role>` vérifié. Tests purs (humain + catalogue injectés, zéro IO).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.ForgeIdentity

  @catalog %{
    "users" => %{
      "lordzurp" => %{"name" => "Lord Zurp", "email" => "lordzurp.dev@gmail.com"}
    }
  }

  defp opts, do: [human: "lordzurp", catalog: @catalog]

  test "for_role : author/committer = l'humain (pas le rôle)" do
    assert {:ok, id} = ForgeIdentity.for_role("engineer", opts())
    assert id.author_name == "Lord Zurp"
    assert id.author_email == "lordzurp.dev@gmail.com"
    assert id.committer_name == "Lord Zurp"
    assert id.committer_email == "lordzurp.dev@gmail.com"
    assert id.human == "lordzurp"
    assert id.role == "engineer"
  end

  test "for_role : le rôle est porté par le trailer Co-authored-by (pas l'identité)" do
    assert {:ok, id} = ForgeIdentity.for_role("reviewer", opts())
    assert id.coauthor_trailer == "Co-authored-by: LCARS-reviewer <reviewer@lcars.local>"
    # l'identité ne contient JAMAIS le rôle (non-négo #1 : pas d'aplatissement)
    refute id.author_email =~ "reviewer"
  end

  test "coauthor_trailer : canon vérifiable" do
    assert ForgeIdentity.coauthor_trailer("gatekeeper") ==
             "Co-authored-by: LCARS-gatekeeper <gatekeeper@lcars.local>"
  end

  test "allowed_emails : git_native = humain seul ; payload = humain + système" do
    assert ForgeIdentity.allowed_emails(:git_native, "h@x.tld") == ["h@x.tld"]
    assert ForgeIdentity.allowed_emails(:payload, "h@x.tld") == ["h@x.tld", "system@lcars.local"]
    assert ForgeIdentity.system_email() == "system@lcars.local"
  end

  test "fail-loud : humain absent du catalogue → {:error, {:human_not_in_catalog, _}}" do
    assert {:error, {:human_not_in_catalog, "inconnu"}} =
             ForgeIdentity.for_role("engineer", human: "inconnu", catalog: @catalog)
  end

  test "fail-loud : entrée catalogue incomplète (email manquant) → {:error, _}" do
    bad = %{"users" => %{"lordzurp" => %{"name" => "Lord Zurp"}}}

    assert {:error, {:catalog_entry_invalid, "lordzurp"}} =
             ForgeIdentity.for_role("engineer", human: "lordzurp", catalog: bad)
  end

  test "fail-loud : catalogue introuvable (path bidon, pas d'injection) → {:error, _}" do
    assert {:error, {:catalog_unreadable, _path, _reason}} =
             ForgeIdentity.for_role("engineer",
               human: "lordzurp",
               catalog_path: "/nonexistent/settings_users.yaml"
             )
  end
end

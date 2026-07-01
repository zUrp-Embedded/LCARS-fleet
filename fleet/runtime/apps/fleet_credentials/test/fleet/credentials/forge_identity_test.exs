defmodule Fleet.Credentials.ForgeIdentityTest do
  @moduledoc """
  Z4 (forge-identité B') — l'author = l'humain du brief (identité dérivée de l'OS),
  le rôle = trailer `Co-authored-by: LCARS-<role>` vérifié. Tests purs (humain +
  identité injectés via `:identity` — zéro IO ; la dérivation OS réelle git config/GECOS
  est validée en deploy-env, non hermétique en unit).
  """
  use ExUnit.Case, async: true

  alias Fleet.Credentials.ForgeIdentity

  # `:identity` court-circuite la dérivation OS (et l'override config) → assemblée testable.
  defp opts,
    do: [human: "lordzurp", identity: %{name: "Lord Zurp", email: "lordzurp.dev@gmail.com"}]

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

  test "pas de catalogue : un humain quelconque résout TOUJOURS (on n'over-filtre pas)" do
    # `:identity` injecté → l'assemblée réussit sans aucun catalogue ni fichier, pour
    # n'importe quel login. Plus de fail-loud {:human_not_in_catalog}.
    assert {:ok, %{human: "qui-que-ce-soit", author_email: "x@y.tld"}} =
             ForgeIdentity.for_role("engineer",
               human: "qui-que-ce-soit",
               identity: %{name: "X", email: "x@y.tld"}
             )
  end
end

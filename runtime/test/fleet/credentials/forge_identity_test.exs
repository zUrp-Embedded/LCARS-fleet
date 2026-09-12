defmodule Fleet.Credentials.ForgeIdentityTest do
  @moduledoc """
  Checks human identity assembly, role trailers and accepted-email policy using explicit
  human/name/email fixtures. Does not verify live OS derivation, forge accounts or commit gates.
  """
  use ExUnit.Case, async: true

  alias Fleet.Credentials.ForgeIdentity

  # `:identity` short-circuits the OS derivation (and the config override) → testable assembly.
  defp opts,
    do: [human: "lordzurp", identity: %{name: "Lord Zurp", email: "lordzurp.dev@gmail.com"}]

  test "for_role: author/committer = the human (not the role)" do
    assert {:ok, id} = ForgeIdentity.for_role("engineer", opts())
    assert id.author_name == "Lord Zurp"
    assert id.author_email == "lordzurp.dev@gmail.com"
    assert id.committer_name == "Lord Zurp"
    assert id.committer_email == "lordzurp.dev@gmail.com"
    assert id.human == "lordzurp"
    assert id.role == "engineer"
  end

  test "R1-14: name/email with newline/control → hygiened (no injection into the git identity)" do
    assert {:ok, id} =
             ForgeIdentity.for_role("engineer",
               human: "lordzurp",
               identity: %{name: "Foo\nBar", email: "a@b\r.tld"}
             )

    assert id.author_name == "FooBar"
    assert id.author_email == "a@b.tld"
    assert id.committer_name == "FooBar"
    refute id.author_name =~ "\n"
    refute id.committer_email =~ "\r"
  end

  test "for_role: the role is carried by the Co-authored-by trailer (not the identity)" do
    assert {:ok, id} = ForgeIdentity.for_role("reviewer", opts())
    assert id.coauthor_trailer == "Co-authored-by: LCARS-reviewer <reviewer@lcars.local>"
    refute id.author_email =~ "reviewer"
  end

  test "coauthor_trailer: verifiable canon" do
    assert ForgeIdentity.coauthor_trailer("gatekeeper") ==
             "Co-authored-by: LCARS-gatekeeper <gatekeeper@lcars.local>"
  end

  test "F-C018 R1-14: role with newline/control → hygiened (trailer + email), no commit-header injection" do
    # Exercise control stripping at both role-to-header sinks, independently of catalogue validation.
    trailer = ForgeIdentity.coauthor_trailer("engineer\nBcc: evil")
    refute trailer =~ ~r/[\x00-\x1F]/, "trailer: no control char (R1-14 injection)"

    email = ForgeIdentity.role_email("qualifier\r\ninjected")
    refute email =~ ~r/[\x00-\x1F]/, "role_email: no control char"
  end

  test "allowed_emails: git_native = human only; payload = human + system" do
    assert ForgeIdentity.allowed_emails(:git_native, "h@x.tld") == ["h@x.tld"]
    # Pin the system literal once, then check policy and identity accessors agree with it.
    assert ForgeIdentity.system_email() == "system_starfleet@lcars.local"

    assert ForgeIdentity.allowed_emails(:payload, "h@x.tld") == [
             "h@x.tld",
             ForgeIdentity.system_email()
           ]

    assert ForgeIdentity.system_identity() == %{
             name: "system_starfleet",
             email: ForgeIdentity.system_email()
           }

    assert ForgeIdentity.role_email("starfleet") == "starfleet@lcars.local"
  end

  test "no catalog: any human ALWAYS resolves (we do not over-filter)" do
    # An injected human/identity is assembled without a catalogue membership check.
    assert {:ok, %{human: "qui-que-ce-soit", author_email: "x@y.tld"}} =
             ForgeIdentity.for_role("engineer",
               human: "qui-que-ce-soit",
               identity: %{name: "X", email: "x@y.tld"}
             )
  end
end

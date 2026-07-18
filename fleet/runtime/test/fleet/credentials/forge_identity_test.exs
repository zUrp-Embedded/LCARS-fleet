defmodule Fleet.Credentials.ForgeIdentityTest do
  @moduledoc """
  Z4 (forge-identity B') — the author = the brief's human (identity derived from the OS),
  the role = a verified `Co-authored-by: LCARS-<role>` trailer. Pure tests (human +
  identity injected via `:identity` — zero IO; the real OS derivation git config/GECOS
  is validated in deploy-env, not hermetic in unit).
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
    # the identity NEVER contains the role (non-negotiable #1: no flattening)
    refute id.author_email =~ "reviewer"
  end

  test "coauthor_trailer: verifiable canon" do
    assert ForgeIdentity.coauthor_trailer("gatekeeper") ==
             "Co-authored-by: LCARS-gatekeeper <gatekeeper@lcars.local>"
  end

  test "F-C018 R1-14: role with newline/control → hygiened (trailer + email), no commit-header injection" do
    # Symmetric to the name/email test: the role (= cap-profile `metadata.name`, a schema-OPEN field
    # without a pattern) is interpolated into the Co-authored-by trailer + the role email. A
    # newline/control (mis-authored cap profile) would inject a commit-header line (R1-14). The SAME
    # defense as for the HUMAN fields applies to the role (sink-side, source-agnostic).
    trailer = ForgeIdentity.coauthor_trailer("engineer\nBcc: evil")
    refute trailer =~ ~r/[\x00-\x1F]/, "trailer: no control char (R1-14 injection)"

    email = ForgeIdentity.role_email("qualifier\r\ninjected")
    refute email =~ ~r/[\x00-\x1F]/, "role_email: no control char"
  end

  test "allowed_emails: git_native = human only; payload = human + system" do
    assert ForgeIdentity.allowed_emails(:git_native, "h@x.tld") == ["h@x.tld"]
    # H2: the system identity = the REAL forge account lcars-system (an identity without an
    # actual forge account would be a ghost). The payload allow-list DERIVES from system_email
    # (structural coherence tested, not the literal retyped twice).
    assert ForgeIdentity.system_email() == "lcars-system@lcars.local"

    assert ForgeIdentity.allowed_emails(:payload, "h@x.tld") == [
             "h@x.tld",
             ForgeIdentity.system_email()
           ]

    assert ForgeIdentity.system_identity() == %{
             name: "lcars-system",
             email: ForgeIdentity.system_email()
           }

    assert ForgeIdentity.role_email("starfleet") == "starfleet@lcars.local"
  end

  test "no catalog: any human ALWAYS resolves (we do not over-filter)" do
    # `:identity` injected → the assembly succeeds without any catalog or file, for any
    # login. Never a `{:human_not_in_catalog}` fail-loud.
    assert {:ok, %{human: "qui-que-ce-soit", author_email: "x@y.tld"}} =
             ForgeIdentity.for_role("engineer",
               human: "qui-que-ce-soit",
               identity: %{name: "X", email: "x@y.tld"}
             )
  end
end

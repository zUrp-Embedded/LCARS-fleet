defmodule Fleet.Forge.Client.UrlSafeTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client.UrlSafe

  # Confinement E (WI-E4) — a hostile repo/path/ref segment produces a SAFE URL.
  # The right treatment = ENCODING (not slugging: repo=`owner/name`, path=`dir/file` carry legitimate `/`):
  # each COMPONENT is encoded, STRUCTURAL `/` preserved; an injected `..`/`/`/space/`?`/`#` is inert.
  # (The encoding authority lives in `ForgeClient.UrlSafe`.)
  describe "encode_seg/encode_repo/encode_path — per-segment encoding" do
    test "encode_seg neutralizes /, space, ?, # in an atomic component" do
      assert UrlSafe.encode_seg("a/b") == "a%2Fb"
      assert UrlSafe.encode_seg("a b") == "a%20b"
      assert UrlSafe.encode_seg("a?x=1") == "a%3Fx%3D1"
      assert UrlSafe.encode_seg("a#f") == "a%23f"
    end

    test "encode_repo preserves the structural owner/name / BUT neutralizes a traversal component" do
      assert UrlSafe.encode_repo("fleet/lcars") == "fleet/lcars"

      # REAL VECTOR: `fleet/../admin` — the `..` is a COMPONENT after split. www-form leaves `.`
      # untouched → without the dedicated case it would survive and the server would normalize it
      # (traversal). We render it inert:
      assert UrlSafe.encode_repo("fleet/../admin") == "fleet/%2E%2E/admin"
      refute UrlSafe.encode_repo("fleet/../admin") =~ ~r{/\.\.(/|$)}
      assert UrlSafe.encode_repo("fleet/a b") == "fleet/a%20b"
      # a `/` injected INSIDE a component (fake separator) is encoded:
      assert UrlSafe.encode_repo("fleet/x%2F..") == "fleet/x%252F.."
    end

    test "encode_path: structural / preserved, any .. component inert" do
      assert UrlSafe.encode_path("docs/sub/file.md") == "docs/sub/file.md"

      assert UrlSafe.encode_path("docs/../../../etc/passwd") ==
               "docs/%2E%2E/%2E%2E/%2E%2E/etc/passwd"

      refute UrlSafe.encode_path("docs/../../../etc/passwd") =~ ~r{/\.\.(/|$)}
      assert UrlSafe.encode_path(".") == "%2E"
    end
  end
end

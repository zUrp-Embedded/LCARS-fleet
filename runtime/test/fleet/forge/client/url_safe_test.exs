defmodule Fleet.Forge.Client.UrlSafeTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client.UrlSafe

  # WI-E4 : string encoding of components, preserving structural slashes.
  # These tests do not exercise HTTP normalization or server decoding.
  describe "encode_seg/encode_repo/encode_path — per-segment encoding" do
    test "encode_seg neutralizes /, space, ?, # in an atomic component" do
      assert UrlSafe.encode_seg("a/b") == "a%2Fb"
      assert UrlSafe.encode_seg("a b") == "a%20b"
      assert UrlSafe.encode_seg("a?x=1") == "a%3Fx%3D1"
      assert UrlSafe.encode_seg("a#f") == "a%23f"
    end

    test "encode_repo preserves the structural owner/name / BUT neutralizes a traversal component" do
      assert UrlSafe.encode_repo("fleet/lcars") == "fleet/lcars"

      # www-form leaves literal dot components unchanged without the dedicated clause.
      assert UrlSafe.encode_repo("fleet/../admin") == "fleet/%2E%2E/admin"
      refute UrlSafe.encode_repo("fleet/../admin") =~ ~r{/\.\.(/|$)}
      assert UrlSafe.encode_repo("fleet/a b") == "fleet/a%20b"
      # Already-percent-encoded input has its percent escaped again.
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

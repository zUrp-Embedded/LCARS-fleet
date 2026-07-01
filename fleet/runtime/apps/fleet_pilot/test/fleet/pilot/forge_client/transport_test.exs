defmodule Fleet.Pilot.ForgeClient.TransportTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeClient.Transport

  # Confinement E (WI-E4) — un segment repo/path/ref hostile produit une URL SÛRE.
  # Le bon traitement = ENCODAGE (pas slug : repo=`owner/name`, path=`dir/file` ont des `/` légitimes) :
  # chaque COMPOSANT est encodé, les `/` STRUCTURELS préservés ; un `..`/`/`/espace/`?`/`#` injecté inerte.
  describe "encode_seg/encode_repo/encode_path — encodage par segment" do
    test "encode_seg neutralise /, espace, ?, # dans un composant atomique" do
      assert Transport.encode_seg("a/b") == "a%2Fb"
      assert Transport.encode_seg("a b") == "a%20b"
      assert Transport.encode_seg("a?x=1") == "a%3Fx%3D1"
      assert Transport.encode_seg("a#f") == "a%23f"
    end

    test "encode_repo préserve le / structurel owner/name MAIS neutralise un composant de traversée" do
      assert Transport.encode_repo("fleet/lcars") == "fleet/lcars"

      # VECTEUR RÉEL : `fleet/../admin` — le `..` est un COMPOSANT après split. www-form ne touche pas
      # le `.` → sans le cas dédié il survivrait et le serveur normaliserait (traversée). On le rend inerte :
      assert Transport.encode_repo("fleet/../admin") == "fleet/%2E%2E/admin"
      refute Transport.encode_repo("fleet/../admin") =~ ~r{/\.\.(/|$)}
      assert Transport.encode_repo("fleet/a b") == "fleet/a%20b"
      # un `/` injecté DANS un composant (faux séparateur) est encodé :
      assert Transport.encode_repo("fleet/x%2F..") == "fleet/x%252F.."
    end

    test "encode_path : / structurels préservés, tout composant .. inerte" do
      assert Transport.encode_path("docs/sub/file.md") == "docs/sub/file.md"

      assert Transport.encode_path("docs/../../../etc/passwd") ==
               "docs/%2E%2E/%2E%2E/%2E%2E/etc/passwd"

      refute Transport.encode_path("docs/../../../etc/passwd") =~ ~r{/\.\.(/|$)}
      assert Transport.encode_path(".") == "%2E"
    end
  end
end

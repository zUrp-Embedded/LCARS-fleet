defmodule Fleet.Spawner.SessionIdTest do
  @moduledoc """
  Builder hexspeak déterministe (`Fleet.Spawner.SessionId`) — pur, async.
  Verrouille le scheme `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>` (BL-055).
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.SessionId

  describe "build/3 — UUID hexspeak déterministe" do
    test "arch = protégé 0badcafe, rôle 01, fleet-level" do
      assert {:ok, "0badcafe-feed-4dad-babe-0000dec0de01"} = SessionId.build("architect")
    end

    test "gatekeeper = worker 1badcafe, rôle 02" do
      assert {:ok, "1badcafe-feed-4dad-babe-0000dec0de02"} = SessionId.build("gatekeeper")
    end

    test "engineer = worker, rôle 03" do
      assert {:ok, "1badcafe-feed-4dad-babe-0000dec0de03"} = SessionId.build("engineer")
    end

    test "repo project-bound encodé en 4 hex (lowercase, padded)" do
      assert {:ok, "1badcafe-feed-4dad-babe-00abdec0de03"} = SessionId.build("engineer", 0x00AB)
      assert {:ok, "1badcafe-feed-4dad-babe-ffffdec0de03"} = SessionId.build("engineer", 0xFFFF)
    end

    test "pool dans le nibble haut de XX (P=1, R=3 → 13)" do
      assert {:ok, "1badcafe-feed-4dad-babe-0000dec0de13"} =
               SessionId.build("engineer", 0x0000, 1)
    end

    test "déterministe : même entrée → même UUID" do
      assert SessionId.build("reviewer", 0x12) == SessionId.build("reviewer", 0x12)
    end

    test "format UUID valide (version 4, variant RFC4122)" do
      {:ok, id} = SessionId.build("qualifier")
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "starfleet REFUSÉ — hors-fleet, jamais de pod fleet" do
      assert {:error, :starfleet_hors_fleet} = SessionId.build("starfleet")
    end

    test "rôle inconnu / slot réservé → erreur typée" do
      assert {:error, :unknown_role} = SessionId.build("vulcan")
      assert {:error, :unknown_role} = SessionId.build("")
    end
  end

  describe "deterministic?/1 + build!/3 + tier" do
    test "deterministic? : catalogués oui, starfleet/inconnu non" do
      assert SessionId.deterministic?("architect")
      assert SessionId.deterministic?("gatekeeper")
      refute SessionId.deterministic?("starfleet")
      refute SessionId.deterministic?("vulcan")
    end

    test "build! rend la string, ou raise sur refus" do
      assert "0badcafe-feed-4dad-babe-0000dec0de01" = SessionId.build!("architect")
      assert_raise ArgumentError, fn -> SessionId.build!("starfleet") end
    end

    test "tier : arch protégé (0badcafe), workers (1badcafe) — pkill -f 1badcafe épargne l'arch" do
      assert {:ok, "0badcafe" <> _} = SessionId.build("architect")

      for w <- ~w(gatekeeper engineer qualifier reviewer consultant) do
        assert {:ok, "1badcafe" <> _} = SessionId.build(w)
      end
    end
  end
end

defmodule Fleet.Spawner.SessionIdTest do
  @moduledoc """
  Encodeur hexspeak déterministe (`Fleet.Spawner.SessionId.encode/4`) — pur, async.
  Verrouille le scheme `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`. Le catalogue rôle → slot vit
  désormais dans le cap-profile (`metadata.role_index/protected/fleet_level`, testé côté
  `Fleet.CapProfileTest`) ; ici on ne teste que l'arithmétique de la string, pas un catalogue.
  Les UUID restent IDENTIQUES à l'ancien builder (preuve de non-régression : même scheme).
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.SessionId

  describe "encode/4 — UUID hexspeak déterministe" do
    test "ex-architect (role_index 1, protégé, fleet-level repo 0) → 0badcafe-…01" do
      assert SessionId.encode(1, true, 0) == "0badcafe-feed-4dad-babe-0000dec0de01"
    end

    test "ex-gatekeeper (role_index 2, worker, fleet-level repo 0) → 1badcafe-…02" do
      assert SessionId.encode(2, false, 0) == "1badcafe-feed-4dad-babe-0000dec0de02"
    end

    test "ex-engineer (role_index 3, worker) repo 0000 → 1badcafe-…03" do
      assert SessionId.encode(3, false, 0) == "1badcafe-feed-4dad-babe-0000dec0de03"
    end

    test "ex-starfleet (role_index 0, protégé) → 0badcafe-…00 — PLUS de refus de rôle (encodeur total)" do
      assert SessionId.encode(0, true, 0) == "0badcafe-feed-4dad-babe-0000dec0de00"
    end

    test "repo project-bound encodé en 4 chiffres DÉCIMAUX (la forge crée l'id en décimal → grep direct)" do
      assert SessionId.encode(3, false, 161) == "1badcafe-feed-4dad-babe-0161dec0de03"
      assert SessionId.encode(3, false, 9999) == "1badcafe-feed-4dad-babe-9999dec0de03"
    end

    test "pool dans le nibble haut de XX (P=1, R=3 → 13)" do
      assert SessionId.encode(3, false, 0x0000, 1) == "1badcafe-feed-4dad-babe-0000dec0de13"
    end

    test "déterministe : même entrée → même UUID" do
      assert SessionId.encode(5, false, 0x12) == SessionId.encode(5, false, 0x12)
    end

    test "format UUID valide (version 4, variant RFC4122)" do
      id = SessionId.encode(4, false, 0)
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "tier : protégé → 0badcafe, worker → 1badcafe (pkill -f 1badcafe épargne le protégé)" do
      assert "0badcafe" <> _ = SessionId.encode(1, true, 0)
      assert "1badcafe" <> _ = SessionId.encode(3, false, 0)
    end

    test "entrée hors-borne = bug appelant → function-clause (encodeur total, pas de {:error, _})" do
      assert_raise FunctionClauseError, fn -> SessionId.encode(16, false, 0) end
      assert_raise FunctionClauseError, fn -> SessionId.encode(1, true, 10_000) end
    end
  end

  describe "verrou anti-drift seed↔encodeur" do
    test "le base seed arch porte EXACTEMENT le session_id encodé (= ce que permanent_boot extrait)" do
      seed = Path.join([:code.priv_dir(:lcars_fleet), "spawner", "base_seeds", "architect.jsonl"])

      # même extraction que Fleet.Spawner.PermanentBoot.base_seed_uuid/1 (1er sessionId).
      [_, first_session_id] = Regex.run(~r/"sessionId":"([^"]+)"/, File.read!(seed))

      # arch = role_index 1, protégé, fleet-level (repo 0000) — son cap-profile canon le déclare.
      assert first_session_id == SessionId.encode(1, true, 0x0000)
      assert first_session_id == "0badcafe-feed-4dad-babe-0000dec0de01"
    end
  end
end

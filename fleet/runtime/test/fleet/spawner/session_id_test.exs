defmodule Fleet.Spawner.SessionIdTest do
  @moduledoc """
  Deterministic hexspeak encoder (`Fleet.Spawner.SessionId.encode/4`) — pure, async.
  Locks the scheme `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`. The role → slot catalog
  lives in the cap-profile (`metadata.role_index/protected/fleet_level`, tested in
  `Fleet.CapProfileTest`); here we only test the string arithmetic, not a catalog.
  The UUIDs stay IDENTICAL to the former builder (non-regression proof: same scheme).
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.SessionId

  describe "encode/4 — deterministic hexspeak UUID" do
    test "ex-architect (role_index 1, protected, fleet-level repo 0) → 0badcafe-…01" do
      assert SessionId.encode(1, true, 0) == "0badcafe-feed-4dad-babe-0000dec0de01"
    end

    test "ex-gatekeeper (role_index 2, worker, fleet-level repo 0) → 1badcafe-…02" do
      assert SessionId.encode(2, false, 0) == "1badcafe-feed-4dad-babe-0000dec0de02"
    end

    test "ex-engineer (role_index 3, worker) repo 0000 → 1badcafe-…03" do
      assert SessionId.encode(3, false, 0) == "1badcafe-feed-4dad-babe-0000dec0de03"
    end

    test "ex-starfleet (role_index 0, protected) → 0badcafe-…00 — NO role refusal (total encoder)" do
      assert SessionId.encode(0, true, 0) == "0badcafe-feed-4dad-babe-0000dec0de00"
    end

    test "project-bound repo encoded as 4 DECIMAL digits (the forge creates the id in decimal → direct grep)" do
      assert SessionId.encode(3, false, 161) == "1badcafe-feed-4dad-babe-0161dec0de03"
      assert SessionId.encode(3, false, 9999) == "1badcafe-feed-4dad-babe-9999dec0de03"
    end

    test "pool in the high nibble of XX (P=1, R=3 → 13)" do
      assert SessionId.encode(3, false, 0x0000, 1) == "1badcafe-feed-4dad-babe-0000dec0de13"
    end

    test "deterministic: same input → same UUID" do
      assert SessionId.encode(5, false, 0x12) == SessionId.encode(5, false, 0x12)
    end

    test "valid UUID format (version 4, RFC4122 variant)" do
      id = SessionId.encode(4, false, 0)
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "tier: protected → 0badcafe, worker → 1badcafe (pkill -f 1badcafe spares the protected)" do
      assert "0badcafe" <> _ = SessionId.encode(1, true, 0)
      assert "1badcafe" <> _ = SessionId.encode(3, false, 0)
    end

    test "out-of-bounds input = caller bug → function-clause (total encoder, no {:error, _})" do
      assert_raise FunctionClauseError, fn -> SessionId.encode(16, false, 0) end
      assert_raise FunctionClauseError, fn -> SessionId.encode(1, true, 10_000) end
    end
  end

  describe "cast/1 — validation of an explicit session_id (BND-024)" do
    test "valid UUID v4 (including a deterministic hexspeak id) → {:ok, uuid}" do
      # a genuine vendor v4 UUID
      assert {:ok, "abcdef01-2345-4678-9abc-def012345678"} =
               SessionId.cast("abcdef01-2345-4678-9abc-def012345678")

      # a deterministic id produced by encode/4 IS a legal UUID v4 → cast accepts it
      det = SessionId.encode(3, false, 161)
      assert {:ok, ^det} = SessionId.cast(det)
    end

    test "non-UUID / wrong version / wrong variant / non-binary → {:error, :not_uuid_shaped}" do
      for bad <- [
            "sess-xyz",
            "builder-det",
            "u9",
            # version nibble = 3 (not 4)
            "abcdef01-2345-3678-9abc-def012345678",
            # variant nibble = 7 (outside [89ab])
            "abcdef01-2345-4678-7abc-def012345678",
            # uppercase (the vendor returns lowercase)
            "ABCDEF01-2345-4678-9ABC-DEF012345678",
            "",
            nil,
            42
          ] do
        assert {:error, :not_uuid_shaped} = SessionId.cast(bad),
               "#{inspect(bad)} should be refused"
      end
    end
  end

  describe "seed↔encoder anti-drift lock" do
    test "the arch base seed carries EXACTLY the encoded session_id (= what permanent_boot extracts)" do
      seed = Path.join([:code.priv_dir(:lcars_fleet), "spawner", "base_seeds", "architect.jsonl"])

      # same extraction as Fleet.Spawner.PermanentBoot.base_seed_uuid/1 (1st sessionId).
      [_, first_session_id] = Regex.run(~r/"sessionId":"([^"]+)"/, File.read!(seed))

      # arch = role_index 1, protected, fleet-level (repo 0000) — its canon cap-profile declares it.
      assert first_session_id == SessionId.encode(1, true, 0x0000)
      assert first_session_id == "0badcafe-feed-4dad-babe-0000dec0de01"
    end
  end
end

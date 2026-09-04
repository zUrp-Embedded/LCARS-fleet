defmodule Fleet.Spawner.SessionIdTest do
  @moduledoc """
  Deterministic hexspeak encoder (`Fleet.Spawner.SessionId.encode/5`) — pure, async.
  Locks the scheme `<X>badcafe-<UID>-4dad-babe-<REPO4>dec0de<P><R>` (class + uid). This is a
  PURE encoder: the class is an ARGUMENT, so these cases name a class, never a role — which role
  carries which class is `CapProfile.kill_class/1`, and citing it here is how a title goes stale. The role→slot
  catalog + the kill-class derivation live in the cap-profile (tested in `Fleet.CapProfileTest`);
  here we test only the string arithmetic. A fixed `@uid` keeps the asserts deterministic.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.SessionId

  @uid 1017

  describe "encode/5 — deterministic hexspeak UUID (class + uid)" do
    test "class 1 (costs a live conversation), role 1, fleet repo 0 → 1badcafe-<uid>-…01" do
      assert SessionId.encode(1, 1, @uid, 0) == "1badcafe-1017-4dad-babe-0000dec0de01"
    end

    test "starfleet (role 0, class 0, fleet repo 0) → 0badcafe-<uid>-…00 (spared by kill)" do
      assert SessionId.encode(0, 0, @uid, 0) == "0badcafe-1017-4dad-babe-0000dec0de00"
    end

    test "role 2, class 1, fleet repo 0 → 1badcafe-<uid>-…02" do
      assert SessionId.encode(2, 1, @uid, 0) == "1badcafe-1017-4dad-babe-0000dec0de02"
    end

    test "role 3, class 2 (a ticket resident), repo 47 → 2badcafe-<uid>-0047…03" do
      assert SessionId.encode(3, 2, @uid, 47) == "2badcafe-1017-4dad-babe-0047dec0de03"
    end

    test "role 5, class 3 (cold, swept), repo 161 → 3badcafe-…05" do
      assert SessionId.encode(5, 3, @uid, 161) == "3badcafe-1017-4dad-babe-0161dec0de05"
    end

    test "uid folded DECIMAL — distinguishes two humans on ONE OAuth (1017 vs 1000)" do
      assert SessionId.encode(1, 1, 1017, 0) != SessionId.encode(1, 1, 1000, 0)
      assert SessionId.encode(1, 1, 1000, 0) == "1badcafe-1000-4dad-babe-0000dec0de01"
    end

    test "repo as 4 DECIMAL digits (forge id, grep-direct)" do
      assert SessionId.encode(3, 1, @uid, 9999) == "1badcafe-1017-4dad-babe-9999dec0de03"
    end

    test "pool in the high nibble of XX (P=1, R=3 → 13)" do
      assert SessionId.encode(3, 1, @uid, 0, 1) == "1badcafe-1017-4dad-babe-0000dec0de13"
    end

    test "kill class in the head nibble → 0/1/2 badcafe (pkill -f 2badcafe reaps judges, 0 spared)" do
      assert "0badcafe" <> _ = SessionId.encode(0, 0, @uid, 0)
      assert "1badcafe" <> _ = SessionId.encode(1, 1, @uid, 0)
      assert "2badcafe" <> _ = SessionId.encode(5, 2, @uid, 0)
    end

    test "deterministic: same input → same UUID" do
      assert SessionId.encode(5, 2, @uid, 0x12) == SessionId.encode(5, 2, @uid, 0x12)
    end

    test "valid UUID v4 format (version 4, RFC4122 variant)" do
      id = SessionId.encode(4, 2, @uid, 0)
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "out-of-bounds input = caller bug → function-clause (total encoder, no {:error, _})" do
      assert_raise FunctionClauseError, fn -> SessionId.encode(16, 1, @uid, 0) end
      assert_raise FunctionClauseError, fn -> SessionId.encode(1, 1, @uid, 10_000) end
      assert_raise FunctionClauseError, fn -> SessionId.encode(1, 1, 10_000, 0) end
      assert_raise FunctionClauseError, fn -> SessionId.encode(1, 16, @uid, 0) end
    end
  end

  describe "cast/1 — validation of an explicit session_id (BND-024)" do
    test "valid UUID v4 (including a deterministic hexspeak id) → {:ok, uuid}" do
      # a genuine vendor v4 UUID
      assert {:ok, "abcdef01-2345-4678-9abc-def012345678"} =
               SessionId.cast("abcdef01-2345-4678-9abc-def012345678")

      # a deterministic id produced by encode/5 IS a legal UUID v4 → cast accepts it
      det = SessionId.encode(3, 1, @uid, 161)
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

  # JG-032 (`S2`) — LE JUMEAU ETAIT GARDE, CELUI-CI NON. `<UID>` et `<REPO4>` sont les deux champs
  # de quatre chiffres decimaux de la MEME identite, tous deux durs-gardes dans `encode/5`, et seul
  # `<REPO4>` avait un refus DIAGNOSTIQUE cote appelant (DR-020). L'autre rendait une
  # `FunctionClauseError` nue — et pas sur un chemin exotique : `encode/5` est atteint par TOUT role
  # catalogue, fleet-scope compris, donc sur un hote dont l'humain siege au-dessus de 9999 AUCUN POD
  # NE PEUT ETRE CREE, avec une erreur qui ne nomme ni l'uid ni la borne.
  #
  # 0..9999 est une hypothese de DEPLOIEMENT, pas une propriete : les uid de bureau y tiennent, les
  # plages userns/subuid des conteneurs vivent a 100000+. Refuser plutot que replier, pour la raison
  # deja arbitree sur `<REPO4>` : un `rem` donnerait a deux humains une seule identite deterministe,
  # et un pod reprendrait la conversation de l'autre.
  describe "JG-032 — un uid hors borne est refuse en le NOMMANT, jamais par clause de fonction" do
    defp cap(name),
      do: %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => name, "role_index" => 1, "kill_class" => 2},
        spec: %{}
      }

    test "uid 9999 → nominal, l'identite est encodee" do
      id = Fleet.Spawner.Pod.SessionMint.mint(cap("engineer"), uid: 9999, repo_id: 7)
      assert id =~ ~r/^[0-9a-f]badcafe-9999-4dad-babe-0007dec0de/
    end

    test "uid 10000 → ArgumentError qui NOMME l'uid et la borne" do
      assert_raise ArgumentError, ~r/uid 10000 is outside the <UID>.*0\.\.9999/s, fn ->
        Fleet.Spawner.Pod.SessionMint.mint(cap("engineer"), uid: 10_000, repo_id: 7)
      end
    end

    test "uid 65534 (nobody) → meme refus nomme" do
      assert_raise ArgumentError, ~r/uid 65534 is outside/, fn ->
        Fleet.Spawner.Pod.SessionMint.mint(cap("engineer"), uid: 65_534, repo_id: 7)
      end
    end

    # Le role fleet-scope (role_index 0) empruntait une AUTRE branche du `cond` et n'etait donc pas
    # epargne : il atteint `encode/5` avec le meme uid. Le refus doit le couvrir aussi.
    test "fleet-scope (role_index 0) est couvert par le meme refus" do
      fleet = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "starfleet", "role_index" => 0, "kill_class" => 0},
        spec: %{}
      }

      assert_raise ArgumentError, ~r/uid 100000 is outside/, fn ->
        Fleet.Spawner.Pod.SessionMint.mint(fleet, uid: 100_000)
      end
    end

    # DEUX HUMAINS DISTINCTS NE COLLISIONNENT PAS — la seconde moitie de la preuve de sortie. Elle
    # tient parce qu'on REFUSE au lieu de replier : il n'existe aucun couple d'uid distincts rendant
    # la meme identite.
    test "deux uid valides distincts donnent deux identites distinctes" do
      a = Fleet.Spawner.Pod.SessionMint.mint(cap("engineer"), uid: 1000, repo_id: 7)
      b = Fleet.Spawner.Pod.SessionMint.mint(cap("engineer"), uid: 9000, repo_id: 7)
      refute a == b
    end
  end
end

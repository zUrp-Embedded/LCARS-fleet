defmodule Fleet.CapProfileReservedSeatTest do
  # async: false — publishes/unpublishes the GLOBAL image (persistent_term), like the image test.
  use ExUnit.Case, async: false

  @moduledoc """
  BL-6-28 — the ReservedSeat kind: a kept, non-spawnable seat in the role catalogue.

  The contract under test: indexed AND validated (no rot behind the exclusion), never
  enumerated (list/list_from_published filter on the shared predicate — an unfiltered
  enumeration feeds the seat to CanonProof/PermanentBoot, which fail-loud into
  fleet.boot_failed), and an explicit load answers `{:error, {:role_reserved, name}}` on BOTH
  regimes — the seat exists, the box is closed; `:not_found` would lie about the first half.
  """

  alias Fleet.CapProfile.{Catalog, Image, Schema}

  @moduletag :tmp_dir

  @seat """
  kind: ReservedSeat
  metadata:
    name: vulcan
    role_index: 8
  """

  defp write_canon(tmp) do
    File.mkdir_p!(Path.join(tmp, "modop"))

    real =
      Application.app_dir(
        :lcars_fleet,
        "priv/catalogue/cap_profile/canon/cap-profiles/engineer.yaml"
      )
      |> File.read!()

    File.write!(Path.join(tmp, "engineer.yaml"), real)
    File.write!(Path.join(tmp, "vulcan.yaml"), @seat)
    tmp
  end

  setup %{tmp_dir: tmp} do
    Fleet.TestEnv.put_env_restoring(:fleet_cap_profile, :root_dir, write_canon(tmp))
    on_exit(fn -> Image.unpublish() end)
    :ok
  end

  describe "reserved-seat-v1.json (Schema.validate :reserved_seat)" do
    test "a bare seat (kind + metadata.name) is valid" do
      raw = %{"kind" => "ReservedSeat", "metadata" => %{"name" => "vulcan", "role_index" => 8}}
      assert :ok = Schema.validate(raw, :reserved_seat)
    end

    test "a seat carrying a spec is REJECTED — a spec for an unspawnable role is an invented inventory" do
      raw = %{"kind" => "ReservedSeat", "metadata" => %{"name" => "vulcan"}, "spec" => %{}}
      assert {:error, :invalid_schema} = Schema.validate(raw, :reserved_seat)
    end

    test "the SHIPPED vulcan.yaml conforms to the seat schema" do
      {:ok, raw} =
        :lcars_fleet
        |> Application.app_dir("priv/catalogue/cap_profile/canon/cap-profiles/vulcan.yaml")
        |> YamlElixir.read_from_file()

      assert :ok = Schema.validate(raw, :reserved_seat)
    end
  end

  describe "disk regime (no image published)" do
    test "list/1 excludes the seat — enumerators never see it" do
      assert {:ok, roles} = Catalog.list()
      assert "engineer" in roles
      refute "vulcan" in roles
    end

    test "read_role by explicit name refuses NAMED — the seat exists, the box is closed" do
      assert {:error, {:role_reserved, "vulcan"}} = Catalog.read_role("vulcan")
    end

    test "load through the facade carries the named refusal (spawn admission reads this)" do
      assert {:error, {:role_reserved, "vulcan"}} = Fleet.CapProfile.load("vulcan")
    end
  end

  describe "image regime (published)" do
    test "publish! VALIDATES the seat (no rot behind the exclusion) and names it in the log" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Image.publish!()
        end)

      assert log =~ "reserved seat(s): vulcan"
    end

    test "list_from_published excludes the seat; read_role refuses named — same rules as disk" do
      :ok = Image.publish!()

      assert {:ok, roles} = Fleet.CapProfile.list_from_published()
      refute "vulcan" in roles
      assert "engineer" in roles

      assert {:error, {:role_reserved, "vulcan"}} = Catalog.read_role("vulcan")
    end

    test "an INVALID seat makes publish! raise — proven-good or do not boot", %{tmp_dir: tmp} do
      # A seat with a spec violates ITS schema: the branch must validate against the seat
      # schema, not wave the entry through because it is excluded from the spawnable world.
      File.write!(Path.join(tmp, "vulcan.yaml"), @seat <> "spec: {}\n")
      assert_raise RuntimeError, ~r/INVALID.*do not boot/s, fn -> Image.publish!() end
    end

    test "an UNKNOWN kind makes publish! raise loud — never mis-validated by a default", %{
      tmp_dir: tmp
    } do
      File.write!(Path.join(tmp, "weird.yaml"), "kind: Banana\nmetadata:\n  name: weird\n")
      assert_raise RuntimeError, ~r/unknown kind/, fn -> Image.publish!() end
    end
  end
end

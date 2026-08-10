defmodule Fleet.CapProfileImageTest do
  @moduledoc """
  The proven-good image, tier B — the EPOCH is closed at the deployment scale: once published,
  a disk mutation changes NOTHING until a restart republishes; consumption is the closed world
  of the image, not the live disk.
  """
  use ExUnit.Case, async: false

  alias Fleet.CapProfile.Image

  @moduletag :tmp_dir

  # A VALID canon under tmp roots: the REAL engineer profile (schema-proof by construction)
  # + one modop overlay. Epoch mutations below edit metadata.description (schema-neutral).
  defp write_canon(tmp) do
    File.mkdir_p!(Path.join(tmp, "modop/tdd"))

    real =
      Application.app_dir(
        :lcars_fleet,
        "priv/catalogue/cap_profile/canon/cap-profiles/engineer.yaml"
      )
      |> File.read!()

    File.write!(Path.join(tmp, "engineer.yaml"), real)
    File.write!(Path.join(tmp, "modop/tdd/profile.yaml"), "{}\n")
    tmp
  end

  # Epoch mutation on a SCHEMA-ADMITTED field: metadata.role_index (integer) — bumped to a
  # sentinel value the assertions can read on both regimes.
  #
  # ⚠ THE SENTINEL IS NOT FREE TO CHOOSE, and it stopped being so on 2026-08-10. It was 14, picked
  # as an arbitrary high number; `publish!/0` now refuses two names on one slot on the MERGED
  # catalogue, and the slot convention put `gatekeeper` on 14 — so the mutation collided with a
  # system role and the test died on the guard instead of measuring the epoch. It must be a slot no
  # role of the SYSTEM catalogue holds (0, d, e, f) and none of the business fixture holds.
  @mutated_role_index 9

  defp mutate_role_index(tmp) do
    path = Path.join(tmp, "engineer.yaml")
    content = File.read!(path)

    mutated =
      Regex.replace(~r/^  role_index: \d+$/m, content, "  role_index: #{@mutated_role_index}")

    if mutated == content, do: raise("mutation anchor missing (role_index)")
    File.write!(path, mutated)
  end

  defp role_index_of({:ok, %Fleet.CapProfile{metadata: md}}), do: md["role_index"]

  setup %{tmp_dir: tmp} do
    Fleet.TestEnv.put_env_restoring(:fleet_cap_profile, :root_dir, write_canon(tmp))
    on_exit(fn -> Image.unpublish() end)
    :ok
  end

  test "EPOCH CLOSURE: after publish!, a disk mutation changes NOTHING — before it, the disk leads",
       %{tmp_dir: tmp} do
    # Disk regime (no image): the live file is the truth.
    original = role_index_of(Fleet.CapProfile.load("engineer"))
    assert is_integer(original) and original != @mutated_role_index

    :ok = Image.publish!()

    # MUTATE the catalogue on disk (a mid-life redeploy/edit).
    mutate_role_index(tmp)

    # The image leads: the mutation is INVISIBLE to consumption (one epoch per deployment).
    assert role_index_of(Fleet.CapProfile.load("engineer")) == original

    # Back to the disk regime (as a restart-republish would): the new epoch is seen.
    Image.unpublish()
    assert role_index_of(Fleet.CapProfile.load("engineer")) == @mutated_role_index
  end

  test "closed world: a role ADDED on disk after publish! does not exist until republish", %{
    tmp_dir: tmp
  } do
    :ok = Image.publish!()

    File.write!(Path.join(tmp, "latecomer.yaml"), """
    api_version: lcars/v2.5
    kind: CapabilityProfile
    metadata:
      name: latecomer
    spec: {}
    """)

    assert {:error, :not_found} = Fleet.CapProfile.load("latecomer")
  end

  test "modop overlays are frozen too (read_modops serves the image)", %{tmp_dir: tmp} do
    :ok = Image.publish!()
    assert {:ok, [%{}]} = Fleet.CapProfile.Catalog.read_modops(["tdd"])

    # An overlay added on disk after publish is not activable (closed world).
    File.mkdir_p!(Path.join(tmp, "modop/ghost"))
    File.write!(Path.join(tmp, "modop/ghost/profile.yaml"), "{}\n")
    assert {:error, :modop_not_found} = Fleet.CapProfile.Catalog.read_modops(["ghost"])
  end

  test "proven-good or do not boot: an INVALID profile makes publish! raise", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "broken.yaml"), """
    api_version: lcars/v2.5
    kind: CapabilityProfile
    metadata:
      name: broken
    spec:
      scope: "not a map"
    """)

    assert_raise RuntimeError, ~r/INVALID.*do not boot/s, fn -> Image.publish!() end
    assert Image.published() == nil
  end

  # Derives a second entry from the real engineer profile — schema-proof by construction, so the
  # publish reaches the uniqueness pass instead of dying on the schema before it.
  defp write_twin(tmp, name, role_index) do
    body =
      tmp
      |> Path.join("engineer.yaml")
      |> File.read!()
      |> String.replace(~r/^  name: .*$/m, "  name: #{name}")
      |> String.replace(~r/^  role_index: \d+$/m, "  role_index: #{role_index}")

    File.write!(Path.join(tmp, "#{name}.yaml"), body)
  end

  test "two DIFFERENT names on one role_index: the boot refuses, and it names the slot", %{
    tmp_dir: tmp
  } do
    # The slot is a kill class. `dev` and `gatekeeper` shipped on slot 2 together and the bench
    # stayed green only because their kill_class happened to differ — the guard the schema (per
    # file) and the contract check (per root) both structurally cannot hold, since neither sees
    # the merged catalogue.
    write_twin(tmp, "twin", 3)

    assert_raise RuntimeError, ~r/role_index 3 claimed by engineer, twin/, fn ->
      Image.publish!()
    end

    assert Image.published() == nil
  end

  test "superposing a SYSTEM entry by name is one entry, one slot — not a collision", %{
    tmp_dir: tmp
  } do
    # The legitimate case the search path made free: a business catalogue overriding `architect`
    # carries its slot too. It must NOT read as two claims on that slot, or the override would be
    # unusable — which is precisely why the check reads the merged index and not the files.
    #
    # The slot is READ from the system profile rather than typed: it was `1` here, and the slot
    # convention moved the architect to `d` on 2026-08-10. A literal would have kept passing (same
    # NAME, one entry, whatever the number) while describing a catalogue that no longer exists —
    # green prose next to a green test is the hardest kind to notice.
    {:ok, system_arch} = Fleet.CapProfile.load("architect")
    write_twin(tmp, "architect", Fleet.CapProfile.role_index(system_arch))

    assert :ok = Image.publish!()
  end

  test "the image is versioned (two different canons → two versions)", %{tmp_dir: tmp} do
    :ok = Image.publish!()
    %{version: v1} = Image.published()
    assert is_binary(v1) and byte_size(v1) == 12

    mutate_role_index(tmp)
    :ok = Image.publish!()
    %{version: v2} = Image.published()
    assert v1 != v2
  end
end

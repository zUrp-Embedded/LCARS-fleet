defmodule Fleet.CapProfileImageTest do
  @moduledoc """
  Checks that profile and overlay reads use the published snapshot despite disk edits,
  and that publication rejects invalid profiles and merged role-index collisions.
  Explicit republishing replaces the snapshot without requiring a restart in these tests.
  """
  use ExUnit.Case, async: false

  alias Fleet.CapProfile.Image

  @moduletag :tmp_dir

  # Use the bundled engineer profile and an empty overlay to reach publication validation.
  defp write_canon(tmp) do
    File.mkdir_p!(Path.join(tmp, "modop/tdd"))

    real =
      Application.app_dir(
        :lcars_fleet,
        "priv/catalogue/cap_profile/cap-profiles/engineer.yaml"
      )
      |> File.read!()

    File.write!(Path.join(tmp, "engineer.yaml"), real)
    File.write!(Path.join(tmp, "modop/tdd/profile.yaml"), "{}\n")
    tmp
  end

  # Must remain schema-valid and unused by the system/fixture roles; a collision would
  # test uniqueness failure instead of snapshot replacement.
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
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :cap_profile_root_dir, write_canon(tmp))
    on_exit(fn -> Image.unpublish() end)
    :ok
  end

  test "EPOCH CLOSURE: after publish!, a disk mutation changes NOTHING — before it, the disk leads",
       %{tmp_dir: tmp} do
    original = role_index_of(Fleet.CapProfile.load("engineer"))
    assert is_integer(original) and original != @mutated_role_index

    :ok = Image.publish!()

    mutate_role_index(tmp)

    assert role_index_of(Fleet.CapProfile.load("engineer")) == original

    # Removing the image restores live disk reads.
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

  # Preserve schema conformance so tests reach the merged-index uniqueness check.
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
    # Role index is distinct from kill class; uniqueness is required in the merged catalogue.
    write_twin(tmp, "twin", 3)

    assert_raise RuntimeError, ~r/role_index 3 claimed by engineer, twin/, fn ->
      Image.publish!()
    end

    assert Image.published() == nil
  end

  test "superposing a SYSTEM entry by name is one entry, one slot — not a collision", %{
    tmp_dir: tmp
  } do
    # Same-name override is one merged entry. Read its real index: an arbitrary literal
    # could pass while no longer representing the system role being overridden.
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

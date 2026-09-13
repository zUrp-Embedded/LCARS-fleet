defmodule Fleet.CapProfile.MonksFrozenTest do
  # Serial: mutates global cap_profile_root_dir.
  use ExUnit.Case, async: false

  # Archived at priv/memory-x/monks, outside boot. Re-home per-project/system profiles,
  # update these old paths and restore the scan before re-enabling.
  @moduletag skip:
               "Memory-X frozen (BL) — monk cap-profiles archived; re-enable at per-project re-home"

  alias Fleet.CapProfile

  @canon_dir Path.join([
               __DIR__,
               "..",
               "..",
               "..",
               "priv",
               "catalogue",
               "cap_profile",
               "cap-profiles"
             ])
             |> Path.expand()

  setup do
    prev = Application.get_env(:lcars_fleet, :cap_profile_root_dir)
    Application.put_env(:lcars_fleet, :cap_profile_root_dir, @canon_dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :cap_profile_root_dir, prev),
        else: Application.delete_env(:lcars_fleet, :cap_profile_root_dir)
    end)

    :ok
  end

  # Dormant expectations only: Catalog currently excludes monks from enumeration and loading.
  test "load(\"archivist\") resolves the monk profile (monks/ scan)" do
    assert {:ok, _cap} = CapProfile.load("archivist")
  end

  test "list/1 includes the monk profiles (archivist + one monk-beta)" do
    assert {:ok, names} = CapProfile.list(@canon_dir)
    assert "archivist" in names
    assert "monk-beta-findings-recent" in names
  end
end

defmodule Fleet.CapProfile.MonksFrozenTest do
  # async: false — mutates the global :root_dir config.
  use ExUnit.Case, async: false

  # FROZEN (BL — Memory-X frozen): tests that `list/load` scan `cap-profiles/monks/`,
  # now ARCHIVED (`priv/catalogue/cap_profile/canon/_frozen-monks/`, out of the boot loop). Re-enable when Memory-X
  # is re-homed (per-project + system-wide under lcars). cf. work/backlog.md.
  @moduletag skip:
               "Memory-X frozen (BL) — monk cap-profiles archived; re-enable at per-project re-home"

  alias Fleet.CapProfile

  @canon_dir Path.join([
               __DIR__,
               "..",
               "priv",
               "catalogue",
               "cap_profile",
               "canon",
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

  # F-041: `name_index/1` must scan `monks/*.yaml` in addition to `*.yaml` + `archivistes/*.yaml`.
  # Otherwise the canon Memory-X profiles (archivist, monk-alpha-*, monk-beta-*) are invisible to
  # `list/1`/`load/1` → `PermanentBoot` (which enumerates via `list/1`) never boots them. Memory-X
  # WILL live → the scan must include them.
  test "load(\"archivist\") resolves the monk profile (monks/ scan)" do
    assert {:ok, _cap} = CapProfile.load("archivist")
  end

  test "list/1 includes the monk profiles (archivist + one monk-beta)" do
    assert {:ok, names} = CapProfile.list(@canon_dir)
    assert "archivist" in names
    assert "monk-beta-findings-recent" in names
  end
end

defmodule Fleet.CapProfile.MonksF041Test do
  # async: false — mute la config globale :root_dir.
  use ExUnit.Case, async: false

  # GELÉ (BL — Memory-X frozen 2026-06-19) : teste que `list/load` scannent `cap-profiles/monks/`,
  # désormais ARCHIVÉ (`priv/canon/_frozen-monks/`, hors boucle de boot). Ré-activer au re-home de
  # Memory-X (per-project + system-wide sous lcars). cf. work/backlog.md.
  @moduletag skip:
               "Memory-X gelé (BL) — cap-profiles monks archivés ; ré-activer au re-home per-project"

  alias Fleet.CapProfile

  @canon_dir Path.join([__DIR__, "..", "priv", "cap_profile", "canon", "cap-profiles"])
             |> Path.expand()

  setup do
    prev = Application.get_env(:fleet_cap_profile, :root_dir)
    Application.put_env(:fleet_cap_profile, :root_dir, @canon_dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_cap_profile, :root_dir, prev),
        else: Application.delete_env(:fleet_cap_profile, :root_dir)
    end)

    :ok
  end

  # F-041 : avant le fix, `name_index/1` scannait `*.yaml` + `archivistes/*.yaml` mais PAS `monks/*.yaml`.
  # Les profils Memory-X canon (archivist, monk-alpha-*, monk-beta-*) étaient donc invisibles de
  # `list/1`/`load/1` → `PermanentBoot` (qui énumère via `list/1`) ne les bootait jamais. Memory-X VA
  # vivre → le scan doit les inclure.
  test "load(\"archivist\") résout le profil monk (scan monks/)" do
    assert {:ok, _cap} = CapProfile.load("archivist")
  end

  test "list/1 inclut les profils monks (archivist + un monk-beta)" do
    assert {:ok, names} = CapProfile.list(@canon_dir)
    assert "archivist" in names
    assert "monk-beta-findings-recent" in names
  end
end

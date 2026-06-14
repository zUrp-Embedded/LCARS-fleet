defmodule Fleet.Pilot.ApplicationTest do
  # async: false — le test d'intégration mute la config app `:fleet_pilot` (globale VM).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Application, as: PilotApp

  @keys [:start_dispatcher, :stage_dispatch?, :poll_repo, :forge]

  # F054 — garde mutual-exclusion (logique pure, sans config) : >1 Fleet.Pilot.Poller → fail-loud.
  describe "guard_no_duplicate_poller!/1 (logique)" do
    test "deux Fleet.Pilot.Poller (legacy + stage) → raise CLAIR" do
      children = [
        Fleet.Pilot.AutoDispatcher,
        {Fleet.Pilot.Poller, repo: "o/r"},
        {Fleet.Pilot.Poller, repo: "o/r", stage_dispatch?: true},
        {Fleet.Pilot.HopConsumer, repo: "o/r"}
      ]

      assert_raise RuntimeError, ~r/MUTUELLEMENT EXCLUSIF/, fn ->
        PilotApp.guard_no_duplicate_poller!(children)
      end
    end

    test "un seul Poller (+ autres ids) → :ok (pas d'off-by-one)" do
      assert :ok =
               PilotApp.guard_no_duplicate_poller!([
                 {Fleet.Pilot.Poller, repo: "o/r", stage_dispatch?: true},
                 {Fleet.Pilot.HopConsumer, repo: "o/r"}
               ])
    end

    test "aucun Poller → :ok" do
      assert :ok = PilotApp.guard_no_duplicate_poller!([])
      assert :ok = PilotApp.guard_no_duplicate_poller!([Fleet.Pilot.AutoDispatcher])
    end
  end

  # F054 — câblage : la VRAIE config (les 2 modes ON) assemble bien 2 Poller → start/2 fail-loud
  # AVANT start_link (aucun second superviseur démarré). Couvre le chemin de bout en bout.
  describe "start/2 (câblage config → garde)" do
    setup do
      saved = for k <- @keys, into: %{}, do: {k, Application.get_env(:fleet_pilot, k)}

      on_exit(fn ->
        for {k, v} <- saved do
          if is_nil(v),
            do: Application.delete_env(:fleet_pilot, k),
            else: Application.put_env(:fleet_pilot, k, v)
        end
      end)

      :ok
    end

    test "DISPATCHER + STAGE ensemble → fail-loud clair (pas de crash duplicate opaque)" do
      Application.put_env(:fleet_pilot, :start_dispatcher, true)
      Application.put_env(:fleet_pilot, :stage_dispatch?, true)
      Application.put_env(:fleet_pilot, :poll_repo, "owner/repo")

      # `:forge` base_url → `hop_remote` résout → `stage_children` non-vide (sinon stage off = pas de collision).
      Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")

      assert_raise RuntimeError, ~r/MUTUELLEMENT EXCLUSIF/, fn ->
        PilotApp.start(:normal, [])
      end
    end
  end
end

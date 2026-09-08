defmodule Fleet.Pilot.ApplicationStepGuardsTest do
  alias Fleet.Workflow.Loader

  # async: false — mutates the global `:lcars_fleet` config (pilot_step_dispatch?/pilot_poll_repo/...).
  use ExUnit.Case, async: false

  @keys [:pilot_step_dispatch?, :pilot_poll_repo, :pilot_hop_remote, :pilot_forge]

  setup do
    # Tests set these keys themselves; we only register their restoration here.
    Enum.each(@keys, &Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, &1))
    Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :workflow_workflow_maps_root)
    # step_children! publishes the catalogue image; :persistent_term outlives the test —
    # erase every image so no test serves another test's proven catalogue.
    on_exit(fn -> Loader.unpublish_all_images() end)
    :ok
  end

  # F-027 + F-037: with `step_dispatch?: true` + incomplete config, a `step_children` returning `[]`
  # in SILENCE would boot the pilot app "green" without Poller/StepRunConsumer (forge rail dead, zero
  # log). Instead: the operator ASKED for step mode → incomplete config = broken deploy → raise at
  # boot. F-037 re-targeted the guard: it is not `:poll_repo` (the poller DISCOVERS via
  # org-membership, WS3) nor a frozen remote (per-step-run), but the forge `base_url` — without it,
  # neither discovery (`list_org_repos`) nor push (per-step-run remote) work.

  test "F-037: step_dispatch? true without forge base_url (:forge absent) → raise (dead rail avoided)" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.delete_env(:lcars_fleet, :pilot_forge)

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.init([])
    end
  end

  test "F-037: step_dispatch? true but :forge without :base_url → raise" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, token: "x")

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.init([])
    end
  end

  test "F-037: :poll_repo is NOT required anymore (org-membership discovery) — no raise on its absence alone" do
    # The guard no longer depends on :poll_repo. With a forge base_url present, a missing :poll_repo
    # triggers NOTHING (we verify via step_children! that no "base_url" RuntimeError is raised).
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    Application.delete_env(:lcars_fleet, :pilot_poll_repo)

    # We exercise child-spec resolution (without starting the supervisor, which would register the
    # singletons under their global names and conflict). `:poll_repo` absent → no raise.
    children = Fleet.Pilot.Application.step_children_for_test()
    assert Enum.any?(children, &match?({Fleet.Pilot.Poller, _}, &1))
    assert Enum.any?(children, &match?({Fleet.Pilot.StepRunConsumer, _}, &1))
  end

  test "step_status probes EXACTLY the rail step_children! starts (no hollow-green drift)" do
    # The readiness rail (step_rail_processes) must equal the processes actually started (step_children!):
    # a started-but-unprobed process reads operational while dead; a probed-but-unstarted one reads
    # degraded forever. A new rail child added to step_children! without step_rail_processes fails HERE.
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")

    started =
      Fleet.Pilot.Application.step_children_for_test()
      |> Enum.map(&child_name/1)
      |> MapSet.new()

    probed =
      Fleet.Pilot.Application.step_rail_processes()
      |> Enum.map(fn {_key, name} -> name end)
      |> MapSet.new()

    assert started == probed,
           "readiness drift — started but not probed: #{inspect(MapSet.difference(started, probed) |> MapSet.to_list())}; " <>
             "probed but not started: #{inspect(MapSet.difference(probed, started) |> MapSet.to_list())}"
  end

  # Registered name of a supervisor child-spec (the name step_status probes via Process.whereis).
  defp child_name({Task.Supervisor, opts}) when is_list(opts), do: Keyword.fetch!(opts, :name)
  defp child_name({mod, _opts}) when is_atom(mod), do: mod
  defp child_name(mod) when is_atom(mod), do: mod

  # F-C061 Vector 2, re-seated on the CARDS: the jury lives in each workflow map
  # (spec.jury — no engine config). The schema guards the shape, the boot guard the
  # CONTENT: every jury role of every canon card must resolve to a judge cap-profile —
  # else the card would lay a non-judging reviewer on PRs and wedge at dispatch.
  @moduletag :tmp_dir

  defp canon_with_jury(tmp, jury) do
    File.write!(Path.join(tmp, "bad-card.yaml"), """
    kind: WorkflowMap
    metadata:
      name: bad-card
    spec:
      jury: #{jury}
      ci: ignore
      max_rework_rounds: 1
      steps:
        only:
          role: engineer
    """)

    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)
  end

  # A missing/empty workflow catalogue used to enumerate to `[]`, turning both card
  # guards into vacuous truths: the rail booted green with zero loadable card and the
  # first route raised far from the deploy fault. The boot now refuses both states —
  # and step mode OFF keeps its zero-card-by-design semantics (no enumeration at all).

  test "step rail boot: MISSING workflow maps root → raise (no vacuous green)", %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, Path.join(tmp, "nowhere"))

    assert_raise RuntimeError, ~r/does not exist/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "step rail boot: EMPTY workflow catalogue → raise (no vacuous green)", %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)

    assert_raise RuntimeError, ~r/no \*\.yaml card/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "step mode OFF: zero card stays BY DESIGN — no enumeration, no raise, no children", %{
    tmp_dir: tmp
  } do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, false)
    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, Path.join(tmp, "nowhere"))

    assert Fleet.Pilot.Application.step_children_for_test() == []
  end

  test "the rail boot PUBLISHES the image the guards proved — a post-boot disk edit is inert", %{
    tmp_dir: tmp
  } do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")

    File.write!(Path.join(tmp, "proven.yaml"), """
    kind: WorkflowMap
    metadata:
      name: proven
    spec:
      max_rework_rounds: 1
      jury: []
      ci: ignore
      steps:
        only:
          role: engineer
    """)

    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)

    assert [_ | _] = Fleet.Pilot.Application.step_children_for_test()

    # The catalogue mutates after boot: the runtime keeps serving the PROVEN card.
    File.rm!(Path.join(tmp, "proven.yaml"))
    assert %{"name" => "proven"} = Loader.load!("proven")
    assert Loader.canon_names() == ["proven"]
  end

  test "F-C061 V2 (cards): a card jury with a NON-role login (human) → raise at boot",
       %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    canon_with_jury(tmp, "[qualifier, lordzurp]")

    assert_raise RuntimeError, ~r/does NOT resolve/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "F-C061 V2 (cards): a card jury with a NON-judge role (worker) → raise at boot",
       %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    # engineer resolves (cap-profile) but brief_kind: worker → not a valid juror.
    canon_with_jury(tmp, "[qualifier, engineer]")

    assert_raise RuntimeError, ~r/NOT a judge/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  @tag :tmp_dir
  test "DEUX cartes revendiquant le rail atelier : le publish refuse, et il les NOMME", %{
    tmp_dir: tmp
  } do
    # Ici et pas dans application_test.exs : ce test pose `:lcars_fleet, :workflow_workflow_maps_root`,
    # une cle GLOBALE, et ce fichier est `async: false` pour exactement cette raison. Pose dans un
    # fichier async, il faisait tomber un voisin qui cherchait sa propre carte — mesure.
    #
    # Ce que le garde tient : le rail doc se resout par PROPRIETE (un producteur sur `face:
    # workshop`), donc deux revendiquants n'ont pas de reponse. Sans lui, `Enum.find` rendrait la
    # premiere par ordre alphabetique — un rail choisi par un tri, ce que personne n'a decide.
    for name <- ~w(atelier-un atelier-deux) do
      File.write!(Path.join(tmp, "#{name}.yaml"), """
      kind: WorkflowMap
      metadata:
        name: #{name}
        description: "carte de fixture"
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: engineer
            face: workshop
            needs: []
            inputs:
              - ticket.body
      """)
    end

    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)
    on_exit(&Loader.unpublish_all_images/0)

    err = assert_raise RuntimeError, fn -> Loader.publish_image!() end
    assert err.message =~ "atelier-deux, atelier-un"
    assert err.message =~ "One card per catalogue"
  end

  # ─── LE GARDE DES SIGNATAIRES A CHANGE DE NATURE SANS CHANGER DE LIGNE ─────────────────────────
  #
  # « pas de jeton de signataire » voulait dire UNE chose tant que le jeton etait un fichier local :
  # le provisionnement n'a pas tourne, le conteneur est mal deploye, il ne demarre pas.
  #
  # Depuis que le jeton se DEMANDE au service d'autorite, la meme absence recouvre aussi « le
  # service ne repond pas encore » et « la forge est injoignable » — deux etats TRANSITOIRES. Le
  # garde inchange aurait tue le boot sur un hoquet de reseau, en accusant `provision-role-tokens.sh`.
  #
  # Ces deux temoins sont un COUPLE : chacun seul se satisferait d'un garde degenere. Sans le
  # premier, un garde qui ne leve jamais passe ; sans le second, un garde qui leve toujours passe.
  describe "signataires de merge : la cause decide, pas l'absence" do
    @tag :tmp_dir
    test "provisionnement manquant (no_role_token) → RAISE : le conteneur ne demarre pas", %{
      tmp_dir: tmp
    } do
      Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
      Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
      # Un repertoire de jetons VIDE : le service repond, et il repond qu'il n'y a rien a servir.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

      assert_raise RuntimeError, ~r/merge signer/, fn ->
        Fleet.Pilot.Application.step_children_for_test()
      end
    end

    @tag :tmp_dir
    test "forge injoignable → PAS de raise, mais un journal qui NOMME la porte", %{tmp_dir: tmp} do
      Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
      Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

      Fleet.Test.AuthorityDouble.force_fail(:forge_unreachable)
      on_exit(fn -> Fleet.Test.AuthorityDouble.force_fail(nil) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [_ | _] = Fleet.Pilot.Application.step_children_for_test()
        end)

      # ⚠ « PAS DE RAISE » NE SUFFIT PAS, ET C'EST LA MOITIE QUI COMPTE. Un rail qui demarre vert
      # sur un conteneur structurellement incapable de sceller est exactement le succes muet que ce
      # chantier retire ailleurs. Le journal doit dire QUELLE porte ne repond pas, et dire que ce
      # n'est PAS un defaut de provisionnement — sinon l'operateur relance un `provision apply` qui
      # n'a aucune chance d'y changer quoi que ce soit.
      assert log =~ "forge_unreachable"
      assert log =~ "PAS un defaut de provisionnement"
      assert log =~ "TOUT SCELLEMENT ECHOUERA"
    end
  end
end

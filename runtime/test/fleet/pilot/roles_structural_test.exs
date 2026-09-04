defmodule Fleet.Project.RolesStructuralTest do
  @moduledoc """
  Resolution des roles STRUCTURELS par capability, et son refus des deux cotes.

  `async: false` — DELIBERE et load-bearing. Ces tests repointent `:lcars_fleet, :cap_profile_root_dir` et
  depublient l'image : deux etats GLOBAUX. En async ils ont fait tomber trois suites voisines
  (StepDispatcher, StepRunCompleter, StepRunConsumerGate) qui resolvent le producteur pendant ce
  temps-la. C'est la raison pour laquelle ce fichier est separe de `roles_test.exs`, qui reste async
  parce qu'il ne touche a rien de partage.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Roles

  # Un defaut est une exigence qui a renonce a etre verifiee : avant, un catalogue sans producteur
  # bootait VERT et mourait au premier dispatch. Ces deux tests sont la seule raison pour laquelle
  # le litteral a ete retire.
  setup do
    tmp = Fleet.TestEnv.tmp_path("roles-cat")
    File.mkdir_p!(tmp)
    # LES DEUX racines vers la fixture : ce bloc mesure des catalogues qu'il ecrit lui-meme, et la
    # racine systeme y apporterait quatre roles que le test n'a pas declares — « 2 roles declarent
    # exception_judge » sur une fixture qui en ecrit un.
    Fleet.Test.CatalogueIsolation.isolate!(tmp)

    # L'image publiee court-circuiterait le disque : on la retire pour ce bloc. Elle est REPUBLIEE
    # a la sortie — sans ca, la depublication survit au fichier et tout le reste du run resout ses
    # roles par le disque au lieu de l'image. Le `root_dir`, lui, etait deja restaure : c'est
    # l'asymetrie entre les deux etats globaux du meme setup qui l'a rendue invisible.
    published_before = Fleet.CapProfile.Image.published()

    on_exit(fn ->
      File.rm_rf(tmp)

      case published_before do
        %{} = image -> Fleet.CapProfile.Image.republish(image)
        _ -> :ok
      end
    end)

    Fleet.CapProfile.Image.unpublish()
    {:ok, dir: tmp}
  end

  # Les fixtures DERIVENT d'un profil canon reel : `load/1` valide contre le schema, donc un YAML
  # minimal echouerait a charger et `roles_with_capability` — fail-closed par contrat — le compterait
  # comme ne declarant rien. Le test mesurerait alors le mauvais refus.
  @canon_dir Path.join(File.cwd!(), "priv/catalogue/cap_profile/cap-profiles")

  defp write_role!(dir, name, caps) do
    body =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> File.read!()
      |> String.replace(~r/^  name: .*$/m, "  name: #{name}")
      |> String.replace(
        ~r/^  capabilities: \[.*\]$/m,
        "  capabilities: [#{Enum.join(caps, ", ")}]"
      )

    File.write!(Path.join(dir, "#{name}.yaml"), body)
  end

  test "aucun role ne declare la capability → refus nomme", %{dir: dir} do
    write_role!(dir, "someone", ["onboarder"])

    assert_raise RuntimeError, ~r/no catalogue role declares the producer capability/, fn ->
      Roles.producer_role()
    end
  end

  test "PLUSIEURS producteurs est un catalogue legitime — le boot l'accepte", %{dir: dir} do
    # Le cas `eng_hw` + `eng_sw`. La carte nomme son producteur par step (`role`, schema-required)
    # et le run le porte dans la branche `lcars/issue-N-<producer>` : exiger un singleton fleet-wide
    # refuserait la readiness a une fleet specialisee, pour une politique que personne n'a demandee.
    write_role!(dir, "eng-hw", ["producer"])
    write_role!(dir, "eng-sw", ["producer"])
    # Two capabilities on one role, which is the canon shape: the sealer signs the merge AND takes
    # the tier-2 conflict today. They are two KEYS, so a catalogue may split them across two roles
    # without the seal noticing.
    write_role!(dir, "sealer", ["exception_judge", "conflict_resolver"])
    write_role!(dir, "arbitre", ["project_delegate"])

    assert %{
             producers: ["eng-hw", "eng-sw"],
             gatekeeper: "sealer",
             conflict_resolver: "sealer",
             project_delegate: "arbitre"
           } = Roles.resolve_structural_roles!()
  end

  test "un catalogue SANS delegue est refuse au BOOT, plus au premier create_project", %{dir: dir} do
    # La mesure qui justifie le geste : avant, ce catalogue bootait vert et cassait des heures plus
    # tard, chez l'operateur, au premier `project_create` ou a la premiere escalade.
    write_role!(dir, "eng", ["producer"])
    write_role!(dir, "sealer", ["exception_judge", "conflict_resolver"])

    assert_raise RuntimeError,
                 ~r/no catalogue role declares the project delegate capability/,
                 fn ->
                   Roles.resolve_structural_roles!()
                 end
  end

  test "deux delegues : le boot refuse, et il les NOMME", %{dir: dir} do
    write_role!(dir, "eng", ["producer"])
    write_role!(dir, "sealer", ["exception_judge", "conflict_resolver"])
    write_role!(dir, "arch-hw", ["project_delegate"])
    write_role!(dir, "arch-sw", ["project_delegate"])

    assert_raise RuntimeError, ~r/"arch-hw".*"arch-sw"/, fn ->
      Roles.resolve_structural_roles!()
    end
  end

  test "le motif d'unicite est celui du role, pas celui du scelleur recopie", %{dir: dir} do
    # Une phrase unique couvrant les trois singletons ne pouvait etre vraie que d'un seul : elle
    # disait « single writer of the signed merge » pour le delegue aussi. C'est le message que
    # l'operateur lit quand son catalogue est refuse.
    write_role!(dir, "arch-hw", ["project_delegate"])
    write_role!(dir, "arch-sw", ["project_delegate"])

    assert_raise RuntimeError, ~r/single addressee of a project escalation/, fn ->
      Roles.project_delegate_role()
    end
  end

  test "…mais le repli de DERNIER RECOURS refuse de deviner lequel", %{dir: dir} do
    # `producer_role/0` n'est pas « qui produit » : c'est le repli d'un seul appelant, quand la
    # branche du run est illisible. La, avec deux producteurs, aucune reponse n'existe — et signer
    # sous le mauvais producteur est pire que le dire.
    write_role!(dir, "eng-hw", ["producer"])
    write_role!(dir, "eng-sw", ["producer"])

    assert_raise RuntimeError, ~r/LAST-RESORT path/, fn -> Roles.producer_role() end
  end

  test "deux scelleurs restent un refus : le singleton est PAR CONCEPTION", %{dir: dir} do
    write_role!(dir, "alpha", ["exception_judge"])
    write_role!(dir, "beta", ["exception_judge"])

    assert_raise RuntimeError, ~r/unique BY DESIGN/, fn -> Roles.gatekeeper_role() end
  end

  # JG-025 — LES DEUX BRANCHES DE `roles_with_capability/1` NE FILTRAIENT PAS PAREIL. Sans image
  # publiee elle passe par `Catalog.list/1`, qui ecarte les `ReservedSeat` (BL-6-45) ; avec image,
  # elle balayait l'index brut sans ce filtre.
  #
  # ⚠ MESURE QUI CHANGE LA CONCLUSION : la divergence est INATTEIGNABLE aujourd'hui, et ce n'est pas
  # `roles_with_capability/1` qui la ferme. Le schema `reserved-seat-v1.json` est
  # `additionalProperties: false` et ne declare AUCUN `spec` — un siege ne peut donc pas porter de
  # capability, et un fichier qui essaierait ne validerait pas. `Image.publish!/0` LEVE sur un
  # profil invalide (« proven-good image at boot, or do not boot »), donc un tel siege n'entre meme
  # pas dans l'index.
  #
  # Le filtre ajoute cote image ne repare donc pas un bug OBSERVABLE : il rend l'accord des deux
  # branches LOCAL au lieu de l'emprunter a un schema voisin. Ces deux tests epinglent les deux
  # moities de ce raisonnement — l'accord, et l'invariant qui le rendait deja vrai.
  test "JG-025: les deux regimes rendent la MEME reponse sur un catalogue portant un siege", %{
    dir: dir
  } do
    write_role!(dir, "alpha", ["exception_judge"])

    File.write!(
      Path.join(dir, "seat.yaml"),
      "kind: ReservedSeat\nmetadata:\n  name: vulcan\n  role_index: 8\n"
    )

    # Regime DISQUE (le setup a depublie l'image).
    disque = Fleet.CapProfile.roles_with_capability(:exception_judge)
    assert {:ok, ["alpha"]} == disque

    # Regime IMAGE — le siege est INDEXE (pas de pourriture derriere l'exclusion), donc c'est bien
    # la branche qui le voit passer.
    Fleet.CapProfile.Image.publish!()
    on_exit(fn -> Fleet.CapProfile.Image.unpublish() end)

    assert %{index: index} = Fleet.CapProfile.Image.published()

    assert Map.has_key?(index, "vulcan"),
           "le siege doit etre dans l'index, sinon on ne teste rien"

    assert disque == Fleet.CapProfile.roles_with_capability(:exception_judge),
           "les deux branches de la meme fonction rendent deux reponses selon qu'une image est " <>
             "publiee ou non"
  end

  test "JG-025: L'INVARIANT QUI FERMAIT DEJA LA DIVERGENCE — un siege ne peut pas porter de spec",
       %{
         dir: dir
       } do
    # C'est CE refus qui rend la divergence inatteignable, et il vit dans un autre fichier que la
    # fiche ne cite pas. S'il tombe, le filtre ajoute cote image devient load-bearing.
    seat_with_spec = %{
      "kind" => "ReservedSeat",
      "metadata" => %{"name" => "vulcan", "role_index" => 8},
      "spec" => %{"capabilities" => ["exception_judge"]}
    }

    assert {:error, :invalid_schema} =
             Fleet.CapProfile.Schema.validate(seat_with_spec, :reserved_seat)

    _ = dir
  end

  test "une capability legitimement multiple n'est PAS une erreur", %{dir: dir} do
    # L'unicite est une propriete du concept APPELANT (le role structurel), pas du catalogue.
    # `onboarder` n'a pas d'appelant qui resout : c'est un PREDICAT sur un pod (`require_onboarder`
    # repond oui/non a celui qui frappe), jamais une recherche « qui est l'onboarder ». Rien n'a
    # donc a departager deux porteurs. Ce test tenait auparavant sur un tout autre motif — « le
    # canon en porte deux » — qui n'est plus vrai depuis que l'architect a rendu la capacite, et
    # qui n'aurait de toute facon decrit qu'un inventaire.
    write_role!(dir, "alpha", ["onboarder"])
    write_role!(dir, "beta", ["onboarder"])

    assert {:ok, ["alpha", "beta"]} == Fleet.CapProfile.roles_with_capability(:onboarder)
  end

  test "le delegue per-projet est resolu par capability, exactement un", %{dir: dir} do
    # Les deux sites qui le nommaient — l'ensure de ProjectArchitect et le mandat d'escalade
    # d'ArchWake — lisent maintenant la meme source que la garde de Delegation (B-03), qui gatait
    # deja sur la capability et non sur `role == "architect"`.
    write_role!(dir, "arbitre", ["project_delegate"])
    assert "arbitre" == Roles.project_delegate_role()
  end

  test "deux delegues : ambiguite sur QUI arbitre, pas une specialisation", %{dir: dir} do
    # Contrairement au producteur, rien ne SELECTIONNE un delegue : il est ensure par repo, aucune
    # carte ne le nomme. Deux porteurs = personne ne sait a qui l'escalade s'adresse.
    write_role!(dir, "arch-hw", ["project_delegate"])
    write_role!(dir, "arch-sw", ["project_delegate"])

    assert_raise RuntimeError, ~r/unique BY DESIGN/, fn -> Roles.project_delegate_role() end
  end
end

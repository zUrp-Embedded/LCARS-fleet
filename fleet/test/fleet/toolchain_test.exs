defmodule Fleet.ToolchainTest do
  @moduledoc """
  Le document qu'un humain SIGNE, et ce qui le rend signable.

  Ces cas ne testent pas un rendu joli : ils épinglent qu'un diff dit la vérité. Un manifeste dont
  l'ordre bouge tout seul fait apparaître un changement là où il n'y en a pas, et un relecteur qui
  apprend qu'un diff ment cesse de le lire — après quoi la garde humaine ne garde plus rien.
  """
  use ExUnit.Case, async: true

  alias Fleet.Toolchain

  defp apt(pkgs),
    do: %{"ecosystem" => "python", "evidence" => "boom", "apt" => %{"packages" => pkgs}}

  describe "validate_form/1 — exactement une forme, et un refus plutôt qu'une réparation" do
    test "une forme : accepté" do
      assert :ok = Toolchain.validate_form(apt(["python3-venv"]))
    end

    test "aucune forme : refusé, et le message nomme les trois" do
      assert {:error, {:toolchain_form, msg}} =
               Toolchain.validate_form(%{"ecosystem" => "python", "evidence" => "x"})

      assert msg =~ "aucune forme"
      assert msg =~ "apt" and msg =~ "installer" and msg =~ "sysroot"
    end

    test "deux formes : refusé — on n'en choisit PAS une pour le pod" do
      req =
        apt(["a"])
        |> Map.put("sysroot", %{"arch" => "arm64", "sources" => [], "packages" => []})

      # Réparer en silence ferait approuver, au nom de l'humain, une forme qu'il n'a pas choisie.
      assert {:error, {:toolchain_form, msg}} = Toolchain.validate_form(req)
      assert msg =~ "2 formes"
    end
  end

  describe "render/2 — le diff doit dire la vérité" do
    test "l'ordre des clefs est STABLE d'un rendu à l'autre" do
      req = %{
        "ecosystem" => "python",
        "evidence" => "ModuleNotFoundError: No module named 'yaml'",
        "apt" => %{"packages" => ["python3-yaml", "python3-dev"]},
        "egress_hosts" => ["pypi.org", "files.pythonhosted.org"]
      }

      # LE CAS QUI COMPTE : une map itérée dans l'ordre du runtime ferait apparaître un
      # réordonnancement comme un changement, à chaque re-rendu, sur un document que quelqu'un
      # relit avant de signer.
      assert Toolchain.render(req) == Toolchain.render(req)
    end

    test "les listes gardent l'ordre reçu — ce n'est pas un ensemble" do
      out = Toolchain.render(apt(["b-pkg", "a-pkg"]))
      b = :binary.match(out, "b-pkg") |> elem(0)
      a = :binary.match(out, "a-pkg") |> elem(0)
      assert b < a
    end

    test "`evidence` est rendu EN DERNIER et en bloc littéral" do
      out =
        Toolchain.render(Map.put(apt(["x"]), "evidence", "erreur: pas de wheel\n  ligne deux"))

      assert out =~ "evidence: |-"

      # Un bloc littéral n'est pas ré-échappé : une erreur porte des guillemets, des deux-points et
      # des antislashs, et un mauvais échappement transformerait un diagnostic en erreur de parse.
      assert out =~ "  erreur: pas de wheel"
      assert String.trim_trailing(out) |> String.ends_with?("  ligne deux")
    end

    test "les scalaires ambigus sont cités, les autres non" do
      req = %{
        "ecosystem" => "rust",
        "evidence" => "x",
        "installer" => %{
          "name" => "rustup",
          "url" => "https://sh.rustup.rs",
          "version" => "1.27",
          "sha256" => String.duplicate("a", 64)
        }
      }

      out = Toolchain.render(req)
      # `1.27` est un flottant pour YAML et une version pour tout le monde : sans guillemets, le
      # convergeur lirait 1.27 et poserait autre chose que ce qui est écrit.
      assert out =~ ~s(version: "1.27")
      assert out =~ "name: rustup"
    end

    test "une source apt avec `: ` est citée — sinon elle ouvre un mapping" do
      req = %{
        "ecosystem" => "cross-arm64",
        "evidence" => "x",
        "sysroot" => %{
          "arch" => "arm64",
          "sources" => ["deb http://deb.debian.org/debian bookworm main"],
          "packages" => ["libssl-dev"]
        }
      }

      assert Toolchain.render(req) =~ ~s(- "deb http://deb.debian.org/debian bookworm main")
    end

    test "l'en-tête dit ce que le merge engage" do
      out = Toolchain.render(apt(["x"]))
      assert out =~ "NE PAS ÉDITER"
      assert out =~ "au SHA de ce merge"
    end

    test "`requested_by` porte la traçabilité quand elle est fournie, et rien sinon" do
      with_meta = Toolchain.render(apt(["x"]), issue: 412, role: "engineer", work_item_id: "wi-1")
      assert with_meta =~ "requested_by:"
      assert with_meta =~ "issue: 412"

      refute Toolchain.render(apt(["x"])) =~ "requested_by:"
    end

    test "pas d'hôtes déclarés : pas de bloc vide dans le document" do
      refute Toolchain.render(apt(["x"])) =~ "egress_hosts"
    end
  end

  describe "les clefs de corrélation" do
    test "la branche est STABLE pour un work-item — un retry ne rouvre pas une seconde PR" do
      assert Toolchain.branch_for("wi-42") == Toolchain.branch_for("wi-42")
      assert Toolchain.branch_for("wi-42") =~ "lcars/toolchain-"
    end

    test "un work-item au nom exotique donne quand même un nom de branche valide" do
      assert Toolchain.branch_for("wi/42 étrange") == "lcars/toolchain-wi-42-trange"
    end

    test "UN fichier par écosystème, pas un par demande" do
      # Deux pods qui demandent python doivent converger sur le MÊME document : le second édite ce
      # que le premier a déclaré, et le diff montre à un humain ce qui change réellement.
      assert Toolchain.manifest_path("python") == Toolchain.manifest_path("python")
      assert Toolchain.manifest_path("python") == "ops/toolchains.d/python.yaml"
      refute Toolchain.manifest_path("node") == Toolchain.manifest_path("python")
    end

    test "le marqueur est un commentaire HTML — invisible rendu, exact dans le corps" do
      assert Toolchain.marker(412) == "<!-- lcars-toolchain:412 -->"
    end

    test "le verrou d'attente est celui de Fleet.Labels, pas une chaîne recopiée" do
      assert Toolchain.waiting_label() == Fleet.Labels.awaits_toolchain()
      refute Toolchain.waiting_label() == Fleet.Labels.awaits_arch()
    end

    test "le dépôt est celui du domaine sysadmin, la branche n'est PAS `ops`" do
      # `ops` porte le registre d'incidents, que le runtime ECRIT : la protéger casserait ces
      # écritures. Même dépôt, branche différente, protections opposées.
      assert Toolchain.ops_repo() == "fleet/lcars"
      assert Toolchain.branch() == "sysadmin"
      refute Toolchain.branch() == "ops"
    end
  end

  describe "LE ROUND-TRIP écrivain↔lecteur — le témoin que la classe de panne exige" do
    # La panne d'origine (B3) : le render émettait à 4 espaces, `list_under` du convergeur n'en
    # lisait que 2 — apply_apt voyait ZÉRO paquet sur un manifeste réel, et CHAQUE CÔTÉ était vert
    # avec ses propres fixtures. Les deux bats « GRAMMAIRE » épinglent la grammaire du lecteur sur
    # une fixture À LA MAIN : si le render change d'indentation, ils restent verts (audit). CE
    # témoin-ci ferme la classe : la sortie RÉELLE de `render/2` traverse le VRAI `list_under` du
    # script — l'un des deux bouge sans l'autre, il casse.
    test "render/2 → list_under du convergeur : les paquets ressortent identiques" do
      manifest =
        Toolchain.render(
          %{
            "ecosystem" => "python",
            "evidence" => "boom",
            "apt" => %{"packages" => ["python3-yaml", "python3-venv"]}
          },
          issue: "issue-7",
          role: "engineer",
          work_item_id: "wi-1"
        )

      script = Path.expand("deploy/docker/toolchain-converger.sh")

      extracted =
        {"""
         set -euo pipefail
         eval "$(sed -n '/^block_under()/,/^}/p' #{script})"
         eval "$(sed -n '/^list_under()/,/^}/p' #{script})"
         list_under "$(block_under "$(cat)" apt)" "  packages"
         """, manifest}

      {shell, stdin} = extracted
      tmp = Path.join(System.tmp_dir!(), "roundtrip-#{System.unique_integer([:positive])}")
      File.write!(tmp <> ".sh", shell)
      File.write!(tmp <> ".yaml", stdin)

      on_exit(fn ->
        File.rm(tmp <> ".sh")
        File.rm(tmp <> ".yaml")
      end)

      {out, 0} = System.cmd("bash", ["-c", "bash #{tmp}.sh < #{tmp}.yaml"])
      assert String.split(out, "\n", trim: true) == ["python3-yaml", "python3-venv"]
    end
  end
end

defmodule Fleet.ToolchainTest do
  @moduledoc """
  Stable manifests for human review, correlation keys and the renderer/converger round-trip.
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
      # A numeric version must remain a string in YAML.
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
      assert Toolchain.ops_repo() == "lcars/_ops"
      assert Toolchain.branch() == "tool_request"
      refute Toolchain.branch() == "ops"
    end
  end

  describe "LE ROUND-TRIP écrivain↔lecteur — le témoin que la classe de panne exige" do
    # Feed actual render output to the real script parser: isolated fixtures missed a 4-space
    # writer / 2-space reader mismatch that silently produced an empty package list.
    @tag :requires_toolchain_script
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

      script = Path.expand("bin/lcars-toolchain-converge")

      # test_helper excludes :requires_toolchain_script when the script is unavailable in the
      # build context. Do not replace that with an empty successful body or an opaque shell exit 127.
      shell = """
      set -euo pipefail
      eval "$(sed -n '/^block_under()/,/^}/p' #{script})"
      eval "$(sed -n '/^list_under()/,/^}/p' #{script})"
      list_under "$(block_under "$(cat)" apt)" "  packages"
      """

      tmp = Fleet.TestEnv.tmp_path("roundtrip")
      File.write!(tmp <> ".sh", shell)
      File.write!(tmp <> ".yaml", manifest)

      on_exit(fn ->
        File.rm(tmp <> ".sh")
        File.rm(tmp <> ".yaml")
      end)

      {out, 0} = System.cmd("bash", ["-c", "bash #{tmp}.sh < #{tmp}.yaml"])
      assert String.split(out, "\n", trim: true) == ["python3-yaml", "python3-venv"]
    end
  end
end

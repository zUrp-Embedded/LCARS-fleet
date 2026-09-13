defmodule Mix.Tasks.Lcars.CatalogueRolesTest do
  @moduledoc """
  Tests the Mix command's name, arguments, output and failure handling.

  The installer captures stdout as names or *.auto.tfvars.json. These tests
  decode the payload and inspect Logger configuration; CaptureIO alone cannot
  observe logger_std_h writes to the node's user process.

  Serial execution protects global Logger and Mix shell state. The setup restores
  the previous default handler and resets the shell to Mix.Shell.IO.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lcars.Catalogue.Roles

  @catalogue Application.app_dir(:lcars_fleet, "priv/catalogue")

  setup do
    {:ok, cfg} = :logger.get_handler_config(:default)

    on_exit(fn ->
      :ok = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, cfg.module, cfg)
    end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  # This drains the mailbox; bind its result once per assertion group.
  defp mix_said do
    Enum.map_join(drain(), "\n", fn {_kind, msg} -> msg end)
  end

  defp drain(acc \\ []) do
    receive do
      {:mix_shell, kind, [msg]} -> drain([{kind, msg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "le NOM de la commande" do
    test "`mix lcars.catalogue.roles` resout vers CE module" do
      # Resolving the command catches naming errors that a direct run/1 call misses.
      assert Mix.Task.get("lcars.catalogue.roles") == Roles
    end

    test "le nom que l'installeur ecrit est bien celui-la, caractere pour caractere" do
      # Pins the installer's expected command spelling, without reading the script.
      assert Mix.Task.task_name(Roles) == "lcars.catalogue.roles"
    end
  end

  describe "l'usage — un mauvais appel refuse fort, et dit quoi taper" do
    test "aucun argument → Mix.raise avec l'usage" do
      assert_raise Mix.Error, ~r/usage: mix lcars\.catalogue\.roles/, fn -> Roles.run([]) end
    end

    test "deux racines → Mix.raise, jamais « je prends la premiere »" do
      assert_raise Mix.Error, ~r/usage/, fn -> Roles.run(["a", "b"]) end
    end
  end

  describe "le contrat de flux — RIEN QUE la charge utile sur stdout" do
    test "les noms sortent sur stdout, un par ligne, et rien d'autre" do
      sortie = ExUnit.CaptureIO.capture_io(fn -> Roles.run([@catalogue]) end)

      lignes = String.split(sortie, "\n", trim: true)
      assert "engineer" in lignes
      assert "architect" in lignes

      assert Enum.all?(lignes, &Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1)),
             "stdout doit ne porter QUE des noms de role : #{inspect(lignes)}"
    end

    test "--tfvars sort du JSON, et il PARSE" do
      sortie = ExUnit.CaptureIO.capture_io(fn -> Roles.run([@catalogue, "--tfvars"]) end)

      assert {:ok, vars} = Jason.decode(sortie)
      assert is_list(vars["roles"]) and vars["roles"] != []
      assert is_list(vars["writers"])
      assert is_list(vars["judges"])
      assert is_list(vars["externals"])
    end

    test "⚠ LA TACHE DEPLACE LE HANDLER LOGGER — sans quoi un log casserait le JSON" do
      # CaptureIO replaces the test's group leader; Logger's user-process output escapes it.
      # Inspect the handler destination and decode the separately captured payload.
      {:ok, avant} = :logger.get_handler_config(:default)
      assert avant.config.type == :standard_io, "premisse : le handler part bien sur stdout"

      sortie = ExUnit.CaptureIO.capture_io(fn -> Roles.run([@catalogue, "--tfvars"]) end)

      {:ok, apres} = :logger.get_handler_config(:default)
      assert apres.config.type == :standard_error

      assert {:ok, _} = Jason.decode(sortie)
    end
  end

  describe "l'echec — code de sortie non nul, diagnostic hors du flux de donnees" do
    @tag :tmp_dir
    test "⚠ UNE RACINE QUI N'EST PAS UN CATALOGUE NE REND PAS TROIS ROLES SYSTEME", %{
      tmp_dir: tmp
    } do
      # An absent root must not succeed just because the system catalogue supplies roles.
      absente = Path.join(tmp, "pas-de-catalogue-ici")

      sortie =
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(Roles.run([absente])) == {:shutdown, 1}
        end)

      assert sortie == "",
             "stdout doit etre VIDE : l'appelant jette stderr, et ce qu'il capture devient des " <>
               "comptes de forge"

      dit = mix_said()
      assert dit =~ "roster unreadable"
      assert dit =~ absente
    end

    @tag :tmp_dir
    test "catalogue LISIBLE mais sans role METIER → exit 1 : rien a enroller n'est pas un succes",
         %{tmp_dir: tmp} do
      # Exercise empty business roles through tfvars; list/1 also includes system roles.
      vide = Path.join(tmp, "vide")
      File.mkdir_p!(Path.join(vide, "cap_profile/cap-profiles"))

      File.write!(
        Path.join(vide, "catalogue.yaml"),
        "api_version: 1\nname: vide\ndefault_card: aucune\n"
      )

      sortie =
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(Roles.run([vide, "--tfvars"])) == {:shutdown, 1}
        end)

      assert sortie == ""

      dit = mix_said()
      assert dit =~ vide
      assert dit =~ "nothing to enroll"
    end
  end
end

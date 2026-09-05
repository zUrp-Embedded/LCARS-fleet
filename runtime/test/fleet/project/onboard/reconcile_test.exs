defmodule Fleet.Project.Onboard.ReconcileTest do
  @moduledoc """
  `reconcile/2` — la forge dit quels projets existent, le disque suit.

  Ce que ces temoins tiennent, et pourquoi chacun coute quelque chose :

    * LE FILTRE. Une org de catalogue porte des depots qui ne sont PAS des projets — a commencer
      par le `catalogue` qui la signe, et ensuite tout ce qu'un humain depose chez lui. Les
      importer poserait trois faces autour d'un depot qu'aucun humain n'a ouvert. Le discriminant
      est `.lcars.json` sur `main`, mesure du 2026-08-17 : le projet rend 200, les autres 404.
      Le stub en tient DEUX qui n'en sont pas, et pas un seul : un filtre qui ne saute qu'un depot
      passe aussi bien quand il ne sait exclure que celui-la.
    * LA DIFFERENCE ENTRE 404 ET MUET. Un `not_found` est une reponse (« pas un projet ») ; toute
      autre erreur est une ABSENCE de reponse, et la traiter comme un 404 ferait disparaitre un
      projet bien reel de l'inventaire sur un simple timeout.
    * L'ORG ILLISIBLE. Elle rend un ECHEC nomme, jamais une liste vide — vide se lirait « rien a
      importer », qui est le mot d'un conteneur converge.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard.Migration, as: ProjectOnboard

  @moduletag :tmp_dir

  # `installed_names()` rend `["fleet"]` sous le catalogue livre : les stubs repondent pour cette
  # org, et la question posee au stub est epinglee (une org derivee d'ailleurs se verrait ici).
  defmodule Repo do
    def list_org_repos("fleet", _fc),
      do: {:ok, ["fleet/notes-perso", "fleet/vitrine", "fleet/catalogue"]}
  end

  defmodule MuteRepo do
    def list_org_repos("fleet", _fc), do: {:error, {:http, 503, "nope"}}
  end

  defmodule Files do
    # Seul `vitrine` DECLARE. Les deux autres depots existent et ne sont pas des projets.
    def get_file("fleet/vitrine", ".lcars.json", fc) do
      send(self(), {:declaration_read, "fleet/vitrine", Keyword.get(fc, :ref)})
      {:ok, %{content: ~s({"schema":"declaration"}), sha: "deadbeef"}}
    end

    def get_file(_repo, ".lcars.json", _fc), do: {:error, :not_found}

    # Aucun de ces depots n'est un catalogue : `import/2` le demande desormais avant d'agir.
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defmodule MuteFiles do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
    def get_file(_repo, ".lcars.json", _fc), do: {:error, {:http, 502, "gateway"}}
  end

  defp roots(dir) do
    [
      code_root: Path.join(dir, "code"),
      ops_root: Path.join(dir, "ops"),
      workshop_root: Path.join(dir, "workshop"),
      forge_repo: Repo,
      forge_files: Files
    ]
  end

  defp lay_faces(opts, name) do
    for key <- [:code_root, :ops_root, :workshop_root],
        do: File.mkdir_p!(Path.join(Keyword.fetch!(opts, key), name))
  end

  describe "check — lecture seule" do
    test "un projet absent du disque est MANQUE, et les non-projets ne sont pas listes", %{
      tmp_dir: dir
    } do
      assert [%{repo: "fleet/vitrine", status: :missing}] =
               ProjectOnboard.reconcile(:check, roots(dir))

      # La declaration est lue SUR `main`, pas sur la branche par defaut du client HTTP : une org
      # dont le depot vit sur une autre branche par defaut est deja refusee a l'import, et lire
      # ailleurs ferait entrer dans l'inventaire un projet que l'import refusera.
      assert_received {:declaration_read, "fleet/vitrine", "main"}
    end

    test "les trois faces posees rendent DEJA", %{tmp_dir: dir} do
      opts = roots(dir)
      lay_faces(opts, "vitrine")

      assert [%{repo: "fleet/vitrine", status: :present}] = ProjectOnboard.reconcile(:check, opts)
    end

    # ⚠ CE N'EST PAS UN DETAIL DE PRUDENCE. Une face manquante sur trois = un architecte qui monte
    # un chemin absent. `check` ne tranche pas plus finement : il dit qu'il y a a faire, et `apply`
    # dira quoi, avec le refus exact d'`import/2` sur un etat a moitie pose.
    test "une face sur trois ne suffit pas", %{tmp_dir: dir} do
      opts = roots(dir)
      File.mkdir_p!(Path.join(Keyword.fetch!(opts, :code_root), "vitrine"))

      assert [%{repo: "fleet/vitrine", status: :missing}] = ProjectOnboard.reconcile(:check, opts)
    end
  end

  describe "ce qui ne repond pas ne conclut rien" do
    test "une org illisible rend UN echec nomme, pas une liste vide", %{tmp_dir: dir} do
      opts = Keyword.put(roots(dir), :forge_repo, MuteRepo)

      assert [%{repo: "fleet/*", status: :failed, reason: {:org_unreadable, _}}] =
               ProjectOnboard.reconcile(:check, opts)
    end

    test "une declaration illisible garde le projet dans l'inventaire, en echec", %{tmp_dir: dir} do
      opts = Keyword.put(roots(dir), :forge_files, MuteFiles)

      entries = ProjectOnboard.reconcile(:check, opts)

      assert length(entries) == 3

      assert Enum.all?(entries, fn e ->
               e.status == :failed and
                 match?({:declaration_unreadable, ".lcars.json", _}, e.reason)
             end)
    end
  end

  describe "apply — le rail est `import/2`, pas un second verbe" do
    # Le temoin ne monte pas un git complet : il prouve que `apply` DESCEND dans `import/2` en
    # epinglant le refus que seul `import/2` produit — `admit/3` sur un nom hors kebab-case. Un
    # `apply` qui se contenterait de regarder le disque rendrait `:imported` ici.
    defmodule BadNameRepo do
      def list_org_repos("fleet", _fc), do: {:ok, ["fleet/Vitrine_2"]}
    end

    defmodule BadNameFiles do
      def get_file("fleet/Vitrine_2", ".lcars.json", _fc),
        do: {:ok, %{content: "{}", sha: "cafe"}}

      def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
    end

    # ⚠ CE QUI N'EST PAS EPINGLE ICI, ET OU IL L'EST. `apply` pose un assureur d'architecte DIFFERE
    # (`Keyword.put_new`) parce qu'un `eval` n'a pas de superviseur de spawn — mesure du 2026-08-17
    # au banc : l'import posait ses trois faces puis mourait sur
    # `GenServer.call(Fleet.Spawner.Supervisor, …) ** (EXIT) no process`, sans compensation. Aucun
    # temoin d'ici ne peut le voir : ces stubs ne montent pas de forge, donc l'import s'arrete
    # AVANT la derniere jambe. Ce qui est epingle en unite est l'issue `:deferred` elle-meme
    # (`OnboardCompensationTest`, sur une vraie forge `file://`) ; le CABLAGE, lui, se mesure au
    # banc, et c'est le banc qui l'a trouve.

    test "un depot que l'import refuse remonte en ECHEC avec la raison de l'import", %{
      tmp_dir: dir
    } do
      opts =
        roots(dir)
        |> Keyword.put(:forge_repo, BadNameRepo)
        |> Keyword.put(:forge_files, BadNameFiles)

      assert [%{repo: "fleet/Vitrine_2", status: :failed, reason: {:invalid_name, _}}] =
               ProjectOnboard.reconcile(:apply, opts)
    end
  end
end

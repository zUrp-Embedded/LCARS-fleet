defmodule Mix.Tasks.Lcars.Contracts.EvalDoorsStdoutCheckTest do
  @moduledoc """
  Le mur `runtime.eval_doors_claim_stdout`, prouvé contre des arbres FABRIQUÉS.

  Une porte `eval` a un flux de sortie CONTRACTUEL : `catalogue-source` rend `<dépôt> <branche>
  <sha>` que l'appelant donne à `git clone`, `roles-tfvars` rend du JSON redirigé dans un fichier
  que tofu lit. Le handler Logger par défaut écrit sur le MÊME flux, et
  `Fleet.ReleaseDoor.claim_stdout!/0` est le seul geste qui les sépare.

  ⚖ Mesure du 2026-08-23 sur un poste : `lcars catalogue install web-demo` a rendu
  `fatal: repository 'http://127.0.0.1:21000/.git/' not found`. La porte avait imprimé une ligne
  vide, un `Logger.info`, puis sa réponse ; `read -r repo branch sha` a lu la première.

  ## Pourquoi ces témoins-ci, et pas la porte

  La porte tourne sur l'arbre RÉEL, qui est propre depuis le correctif : elle ne peut prouver ni que
  `IO.puts(:stderr, …)` est correctement ignoré, ni que la capture `&IO.puts/1` est vue, ni qu'un
  instrument aveugle se dénonce. Un comportement qu'aucun témoin ne rougit est un comportement que
  le prochain lecteur supprimera en croyant simplifier.

  Le témoin de la forme `when` est le plus important du fichier : la première écriture de la sonde
  ne dépliait pas le `:when`, donc elle ne scannait AUCUN corps et rendait un vert parfait sur un
  arbre qui portait trois portes nues.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Runtime

  # Trois planchers d'instrument, et chacun garde une absence differente : 15 portes au total, au
  # moins UNE ecriture sur stdout (une population muette ne se distingue pas d'un scanner casse), et
  # au moins 6 taches Mix (sans quoi la seconde famille disparait du scan en silence). Les portes de
  # remplissage sont donc CONFORMES, et l'appelant ajoute celle dont il veut parler.
  @eval_fillers 14
  @task_fillers 6

  defp filler(:conformes) do
    Enum.map_join(1..@eval_fillers, "\n", fn i ->
      "  def eval_filler#{i}(x) do\n    Fleet.ReleaseDoor.claim_stdout!()\n" <>
        "    IO.puts(x)\n  end\n"
    end)
  end

  # Le meme plancher, mais sans aucune ecriture sur stdout — pour exercer le garde d'instrument.
  defp filler(:muettes) do
    Enum.map_join(1..@eval_fillers, "\n", fn i ->
      "  def eval_filler#{i}(x) do\n    IO.puts(:stderr, x)\n  end\n"
    end)
  end

  # Des taches Mix qui n'ecrivent PAS sur stdout : elles comblent le plancher de la seconde famille
  # sans peser sur le compte des ecrivantes, donc sans masquer ce que l'appelant veut mesurer.
  defp write_task_fillers(root, n) do
    File.mkdir_p!(Path.join(root, "lib/mix/tasks"))

    for i <- 1..n do
      File.write!(
        Path.join(root, "lib/mix/tasks/filler#{i}.ex"),
        "defmodule Mix.Tasks.Filler#{i} do\n  use Mix.Task\n" <>
          "  def run(_), do: Mix.shell().info(\"rien sur stdout\")\nend\n"
      )
    end
  end

  defp tree(extra, kind, opts) do
    root = Fleet.TestEnv.tmp_path("eval_doors")
    File.mkdir_p!(Path.join(root, "lib/fleet"))

    File.write!(
      Path.join(root, "lib/fleet/doors.ex"),
      "defmodule Doors do\n#{filler(kind)}\n#{extra}\nend\n"
    )

    write_task_fillers(root, Keyword.get(opts, :tasks, @task_fillers))

    case Keyword.get(opts, :task_source) do
      nil -> :ok
      src -> File.write!(Path.join(root, "lib/mix/tasks/lcars.sujet.ex"), src)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(extra, kind \\ :conformes, opts \\ []),
    do: Runtime.check_eval_doors_claim_stdout(tree(extra, kind, opts))

  describe "l'instrument repond de lui-meme d'abord" do
    test "trop peu de portes : INSTRUMENT BROKEN" do
      root = Fleet.TestEnv.tmp_path("eval_few")
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def eval_one, do: IO.puts(\"x\")\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      assert %{status: :fail, evidence: [ev]} = Runtime.check_eval_doors_claim_stdout(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "AUCUNE porte n'ecrit sur stdout : INSTRUMENT BROKEN, jamais un vert propre" do
      # ⚠ C'EST LE CAS QU'A PRODUIT LA PREMIERE ECRITURE DE LA SONDE. Elle ne depliait pas le
      # `:when`, donc elle ne voyait aucun `IO.puts` — et rendait exactement le meme vert qu'un
      # arbre conforme, sur un arbre qui portait trois portes nues.
      assert %{status: :fail, evidence: [ev]} = check("", :muettes)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "no door writes to stdout"
    end

    test "les taches Mix disparaissent du scan : INSTRUMENT BROKEN" do
      # ⚠ LA GARDE DE LA SECONDE FAMILLE, ET ELLE A SERVI LE JOUR DE SA POSE. Si `mix_task?/1`
      # cesse de reconnaitre une tache, la moitie que ce mur vient d'apprendre a voir redevient
      # invisible — et une absence rend exactement le meme vert qu'une conformite.
      #
      # On garde assez de portes `eval*` pour passer le premier plancher : c'est bien la SECONDE
      # famille qui manque, pas la population entiere.
      assert %{status: :fail, evidence: [ev]} =
               check("", :conformes, tasks: 1)

      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "Mix task(s) matched"
    end
  end

  # ── LA SECONDE FAMILLE : LA TACHE MIX ──────────────────────────────────────────────────────────
  #
  # Une porte `eval*` est atteinte par `bin/lcars_fleet eval`, une tache Mix par `mix <tache>` :
  # deux contextes, un depot avec `mix` et une image livree sans, et UN SEUL contrat de flux.
  # `lcars.catalogue.roles` s'annonce elle-meme « twin of the release doors », et c'est le jumeau
  # image qui etait garde — pas elle, alors que c'est ELLE qu'`enroll-catalogue.sh` appelle avec un
  # `2>/dev/null` qui n'attrape rien puisque le bruit sort sur le flux de la charge utile.
  describe "la seconde famille — une tache Mix est une porte, et sa portee est le MODULE" do
    defp task(body) do
      "defmodule Mix.Tasks.Lcars.Sujet do\n  use Mix.Task\n#{body}end\n"
    end

    test "une tache qui ecrit sans reclamer est NOMMEE" do
      assert %{status: :fail, evidence: [ev]} =
               check("", :conformes,
                 task_source: task("  def run(_), do: IO.puts(\"charge utile\")\n")
               )

      assert ev =~ "lcars.sujet.ex"
    end

    test "⚠ L'ECRITURE DANS UN `defp` COMPTE — c'est le cas qui a motive ce mur" do
      # Les deux `IO.puts/1` de `lcars.catalogue.roles` vivent dans `report_names/2` et
      # `report_tfvars/2`, jamais dans `run/1`. Un mur de portee FONCTION aurait rendu un vert
      # parfait sur la porte meme qui l'a fait etendre. La portee d'une tache est son MODULE : elle
      # n'a qu'un point d'entree, et decouper son travail en `defp` ne change pas de quel flux sort
      # la charge utile.
      assert %{status: :fail, evidence: [ev]} =
               check("", :conformes,
                 task_source:
                   task(
                     "  def run(_), do: rapport(\"x\")\n" <>
                       "  defp rapport(x), do: IO.puts(x)\n"
                   )
               )

      assert ev =~ "lcars.sujet.ex"
    end

    test "reclamer dans `run/1` couvre l'ecriture faite dans un `defp`" do
      # La contrepartie de la portee module, et elle est voulue : le geste se pose une fois, en
      # tete du point d'entree, pour tout ce que la tache imprimera ensuite.
      assert %{status: :pass} =
               check("", :conformes,
                 task_source:
                   task(
                     "  def run(_) do\n    Fleet.ReleaseDoor.claim_stdout!()\n" <>
                       "    rapport(\"x\")\n  end\n" <>
                       "  defp rapport(x), do: IO.puts(x)\n"
                   )
               )
    end

    test "une tache qui n'ecrit que par `Mix.shell()` n'est pas une ecrivante" do
      # C'est le cas des six autres taches `lcars.*` : ce qui s'adresse a un humain passe par le
      # shell de Mix. Exiger le geste d'une tache qui n'ecrit jamais le flux protege ferait du mur
      # une formalite, et une formalite se contourne par un appel decoratif.
      assert %{status: :pass} =
               check("", :conformes,
                 task_source: task("  def run(_), do: Mix.shell().info(\"bonjour\")\n")
               )
    end

    test "⚠ UN MODULE `Mix.Tasks.*` SANS `use Mix.Task` N'EST PAS UNE TACHE" do
      # Mesure du 2026-09-08 : sous `lib/mix/tasks/` vivent 18 modules nommes `Mix.Tasks.*`, dont
      # 10 ne sont pas atteignables par `mix` — les familles de murs portent ce namespace sans etre
      # des commandes. Un predicat sur le NOM les comptait toutes, et le plancher d'instrument pose
      # sur ce compte gonfle aurait cache la disparition des vraies taches.
      #
      # Ici : un module de support qui ecrit sur stdout sans reclamer. Il ne doit rien declencher.
      assert %{status: :pass} =
               check("", :conformes,
                 task_source:
                   "defmodule Mix.Tasks.Lcars.Sujet.Support do\n" <>
                     "  def rendu(x), do: IO.puts(x)\nend\n"
               )
    end
  end

  describe "ce que le mur ATTRAPE" do
    test "une porte qui ecrit sans reclamer est NOMMEE" do
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_source(n) do\n    IO.puts(n)\n  end\n")

      assert ev =~ "eval_source"
      assert ev =~ "doors.ex"
    end

    test "la forme `when` est scannee — c'est celle de la porte qui a casse" do
      # ⚠ LE TEMOIN CENTRAL. `def f(x) when g` enveloppe sa tete dans un `:when` ; sans depliage, le
      # corps n'est jamais atteint. La porte reelle (`eval_source(name) when is_binary(name)`) porte
      # exactement cette forme, et c'est elle qui a laisse passer une ligne de log dans une URL.
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_source(n) when is_binary(n) do\n    IO.puts(n)\n  end\n")

      assert ev =~ "eval_source"
    end

    test "la CAPTURE `&IO.puts/1` compte comme une ecriture" do
      # `Enum.each(lines, &IO.puts/1)` est la forme de `eval_main/0` : un appel n'apparait nulle
      # part dans l'AST, seule la capture le trahit.
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_main do\n    Enum.each([1], &IO.puts/1)\n  end\n")

      assert ev =~ "eval_main"
    end
  end

  describe "ce que le mur laisse passer, et c'est voulu" do
    test "`IO.puts(:stderr, x)` n'est pas une ecriture sur stdout" do
      # Les refus d'une porte partent sur stderr par contrat — les compter ferait exiger le geste
      # d'une porte qui n'ecrit jamais le flux qu'il protege.
      assert %{status: :pass} =
               check("  def eval_source(n) do\n    IO.puts(:stderr, n)\n  end\n")
    end

    test "une porte qui ecrit ET reclame passe" do
      assert %{status: :pass} =
               check(
                 "  def eval_source(n) when is_binary(n) do\n" <>
                   "    Fleet.ReleaseDoor.claim_stdout!()\n    IO.puts(n)\n  end\n"
               )
    end

    test "une fonction qui ne s'appelle pas `eval*` n'est pas une porte" do
      assert %{status: :pass} = check("  def render(n) do\n    IO.puts(n)\n  end\n")
    end
  end
end

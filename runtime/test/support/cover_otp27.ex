defmodule Fleet.Test.CoverOtp27 do
  @moduledoc """
  L'outil de couverture de `mix test --cover` sur ce depot, tant que le parc est en OTP 27.

  ⚠ POURQUOI CE MODULE EXISTE. Sous OTP 27, `cover` fait CRASHER le cover-compile de douze modules
  de `lib/` (erlang/otp#11524 : le passe `sys_coverage` nomme ses variables temporaires `_1`,
  `_2`… — des noms VALIDES en Erlang, qui entrent en collision avec les temporaires que le
  compilateur Elixir genere pour `expr in liste`). Le correctif — `cov1`, `cov2`…, des noms qu'une
  source ne peut pas porter — est sur `master` et n'est pas retroporte a `maint-27`. Elixir n'y est
  pour rien : 1.20 REVELE le bug parce qu'il expanse `in` autrement que 1.18.

  Mesure du 2026-09-12 : `Mix.Tasks.Test.Coverage` compile tout le repertoire en UN appel, le
  premier crash arrete tout, aucun test ne tourne. `ignore_modules` n'y peut rien (applique au
  RAPPORT, apres la compilation). Reecrire les sites ne tient pas : la collision porte sur le
  compteur de temporaires de la fonction entiere, pas sur une forme locale — sortir le `in` de sa
  chaine `and` fait crasher la ligne suivante.

  CE QUE FAIT CET OUTIL. Il sonde chaque module dans un VM SEPARE (un crash de cover vide l'etat
  du serveur et, cumule, tue le process mix — mesure), CONFRONTE les refuses a la liste declaree
  dans `mix.exs` (`:otp27_refused`), et compile ici tout sauf eux, sur un serveur propre. Le
  rapport est celui de Mix (`generate_cover_results/1`), seuil compris.

  ⚠ LA LISTE DECLAREE EST UN CLIQUET, PAS UNE EXEMPTION. Un module qui se met a crasher n'est pas
  exclu en silence : l'outil ROUGIT et le nomme. Un module qui cesse de crasher rougit aussi — c'est
  le signal que le parc a change d'OTP et que cet outil doit disparaitre : retirer `tool:` et
  `otp27_refused:` de `mix.exs`, supprimer ce fichier et son temoin. `Mix.Tasks.Test.Coverage`
  reprend la main, sans trou.

  ⚠ CE QUI N'EST PAS MESURE EST DIT. Les douze modules refuses sont imprimes a chaque run, sous le
  total. Sept d'entre eux GARDENT quelque chose (confinement, allowlist des opts de spawn,
  vocabulaire des verdicts, champs proteges de la forge) : le total ne les contient pas, et le
  lecteur doit le savoir. « Non mesure » et « couvert » ne sont pas la meme ligne.

  Les doublures de `test/support/` sont retirees du rapport par leur SOURCE, pas par une liste de
  noms : `cover` les compte parce que `elixirc_paths(:test)` les compile, et un seuil qui mesure la
  couverture des doublures par les tests bouge a chaque doublure ajoutee (`47-MESURE-couverture-E6`).
  """

  use Boundary, deps: [], exports: []

  # `:cover` vit dans l'application `tools`, absente du chemin a la COMPILATION : sans cette ligne,
  # `compile --warnings-as-errors` rougit sur des appels que `Mix.ensure_application!/1` rend
  # valides a l'execution.
  @compile {:no_warn_undefined, :cover}

  # Le script joue dans l'autre VM : un module par appel, le crash attrape, le nom sur stdout.
  # `REFUSED ` est le seul prefixe lu ; le bruit du logger et du compilateur passe a cote.
  @probe ~S"""
  for beam <- Path.wildcard(Path.join(System.fetch_env!("EBIN"), "*.beam")) do
    try do
      {:ok, _} = :cover.compile_beam(String.to_charlist(Path.rootname(beam)))
    catch
      :exit, _ -> IO.puts("REFUSED " <> Path.basename(beam, ".beam"))
    end
  end
  """

  @doc """
  Les modules d'`ebin` que `cover` refuse de compiler sous l'OTP courant, sondes dans un VM separe.
  """
  @spec probe(Path.t()) :: [module()]
  def probe(ebin) do
    # ⚠ ZERO BEAM N'EST PAS « ZERO REFUS ». Un chemin faux rendrait une liste vide, la confrontation
    # dirait que les douze declares ne crashent plus, et la suite mesurerait rien en le disant a
    # l'envers. Un ebin vide est une panne d'instrument.
    if Path.wildcard(Path.join(ebin, "*.beam")) == [] do
      Mix.raise(
        "CoverOtp27: aucun beam sous #{inspect(ebin)} — couverture INCONNUE, pas « vide »"
      )
    end

    elixir =
      System.find_executable("elixir") ||
        Mix.raise("CoverOtp27: `elixir` introuvable sur le PATH")

    {out, status} =
      System.cmd(elixir, ["-e", @probe], env: [{"EBIN", ebin}], stderr_to_stdout: true)

    if status != 0 do
      Mix.raise(
        "CoverOtp27: la sonde a rendu #{status} — couverture INCONNUE, pas « vide »\n#{out}"
      )
    end

    for "REFUSED " <> name <- String.split(out, "\n"), do: String.to_atom(String.trim(name))
  end

  @doc """
  Rougit si les modules sondes ne sont pas EXACTEMENT ceux declares, dans les deux sens.
  """
  @spec confront!([module()], [module()]) :: :ok
  def confront!(probed, declared) do
    probed = MapSet.new(probed)
    declared = MapSet.new(declared)
    new = probed |> MapSet.difference(declared) |> Enum.sort()
    gone = declared |> MapSet.difference(probed) |> Enum.sort()

    if new != [] or gone != [] do
      Mix.raise(
        "CoverOtp27: la liste `otp27_refused` de mix.exs ne correspond plus a ce que cover refuse.\n" <>
          "  refuses par cover mais NON declares (ils sortiraient de la mesure en silence) : #{inspect(new)}\n" <>
          "  declares mais que cover ACCEPTE maintenant (OTP a change ? retirer cet outil) : #{inspect(gone)}"
      )
    end

    :ok
  end

  @doc """
  Ce qui sera cover-compile : les beams d'`ebin` MOINS les declares — apres que la sonde a
  confirme que les declares sont exactement ce que cover refuse. Rougit sinon.

  Separee de `start/2` pour etre temoignee sans toucher au serveur `cover` de ce VM (la suite qui
  joue le temoin tourne elle-meme sous `--cover` : un `:cover.stop/0` ici effacerait sa mesure).
  """
  @spec plan(Path.t(), [module()]) :: [Path.t()]
  def plan(ebin, declared) do
    :ok = confront!(probe(ebin), declared)

    for beam <- Path.wildcard(Path.join(ebin, "*.beam")),
        module_of(beam) not in declared,
        do: beam
  end

  @doc false
  @spec start(Path.t(), keyword()) :: (-> :ok)
  def start(compile_path, opts) do
    Mix.shell().info("Cover compiling modules (OTP 27: probing in a separate VM first) ...")
    Mix.ensure_application!(:tools)

    declared = Keyword.fetch!(opts, :otp27_refused)
    beams = plan(compile_path, declared)

    _ = :cover.stop()
    {:ok, _pid} = :cover.start()
    if Keyword.get(opts, :local_only, true), do: :cover.local_only()

    for beam <- beams do
      {:ok, _} = :cover.compile_beam(String.to_charlist(Path.rootname(beam)))
    end

    support = for beam <- beams, support_source?(beam), do: module_of(beam)

    fn ->
      Mix.shell().info("\nGenerating cover results ...\n")

      opts
      |> Keyword.update(:ignore_modules, support, &(support ++ &1))
      |> Mix.Tasks.Test.Coverage.generate_cover_results()

      Mix.shell().info(
        "\n#{length(:cover.modules()) - length(support)} module(s) measured " <>
          "(#{length(support)} test/support double(s) compiled but left out of the total).\n" <>
          "#{length(declared)} module(s) NOT MEASURED — cover refuses them under OTP 27 (erlang/otp#11524):\n" <>
          Enum.map_join(Enum.sort(declared), "\n", &"  - #{inspect(&1)}")
      )
    end
  end

  defp module_of(beam), do: beam |> Path.basename(".beam") |> String.to_atom()

  # La source d'un beam, lue dans son chunk `compile_info` : c'est le seul fait qui dit « doublure »
  # sans tenir une liste de noms (elles vivent sous cinq prefixes differents).
  defp support_source?(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:compile_info]) do
      {:ok, {_mod, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> String.contains?("/test/support/")

      _ ->
        false
    end
  end
end

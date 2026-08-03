defmodule Mix.Tasks.Lcars.SlugWitness do
  # Classified with the domain that owns the mirrored algorithm.
  use Boundary, classify_to: Fleet.Spawner
  use Mix.Task

  @shortdoc "Confronte le miroir `SeedStore.slugify` a ce que le vendor a REELLEMENT ecrit sur disque"

  @moduledoc """
  La seconde moitie du contrat vendor (BL-6-44), celle que la sonde des drapeaux ne couvre pas.

  `Fleet.Spawner.SeedStore.slugify/1` reproduit BIT POUR BIT l'algorithme de slugification de
  Claude Code, gele contre la v2.1.183. C'est lui qui permet de retrouver
  `~/.claude/projects/<slug>/<uuid>.jsonl` au resume. Si le vendor change son algorithme, RIEN NE
  CASSE VISIBLEMENT : le resume pointe vers un repertoire vide, donc un pod repart sans sa memoire
  au lieu d'echouer. C'est la moitie qui fait le plus mal, exactement parce qu'elle est muette.

  ## Pourquoi un TEMOIN et pas un test

  Un test unitaire de `slugify/1` verifie que la fonction fait ce qu'on a ECRIT — il re-affirme
  notre lecture de l'algo vendor, il ne la CONFRONTE a rien. Le seul juge est ce que le binaire a
  reellement pose sur le disque. Cette tache va le lire : pour chaque pod dont on connait le `cwd`,
  le repertoire `<pod>/.claude/projects/<X>` existant EST la reponse du vendor, et `slugify(cwd)`
  est notre prediction. Deux sources, une confrontation.

      mix lcars.slug_witness                 # sous le home de l'humain courant
      mix lcars.slug_witness --root /home    # ailleurs (une boite, un banc)

  ## Ce qu'un vert signifie EXACTEMENT

  « Aucun temoin trouve ne contredit le miroir », et rien de plus. Les `cwd` d'une fleet reelle
  sont des chemins sages (`/home/tetris`, `/home/projects`) qui n'exercent ni `_`, ni `.`, ni deux
  `-` consecutifs — precisement les cas ou l'algo gele se distingue d'une slugification naive. Un
  vert ici ne dit donc pas « l'algo est identique », il dit « il ne diverge pas sur ce qu'on a vu
  tourner ». La tache le compte et le dit ; c'est la difference entre une preuve et un sondage, et
  la taire ferait de ce vert la meme promesse creuse que la sonde des drapeaux a failli devenir.

  **Last revised**: 2026-08-03
  """

  @impl Mix.Task
  def run(args) do
    root = parse_root(args)

    witnesses =
      [root]
      |> Enum.flat_map(&Path.wildcard(Path.join([&1, "**", ".claude", "projects", "*"])))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.uniq()

    {agreed, disputed} = Enum.split_with(witnesses, &consistent?/1)

    Enum.each(disputed, fn slug ->
      Mix.shell().error(
        "TEMOIN EN DESACCORD : #{slug} — le vendor a ecrit un nom que `SeedStore.slugify/1` ne " <>
          "peut pas produire (caracteres hors [A-Za-z0-9-]). Le resume pointera a cote."
      )
    end)

    exercising = Enum.count(agreed, &discriminating?/1)

    Mix.shell().info(
      "slug_witness: #{length(agreed)} temoin(s) d'accord, #{length(disputed)} en desaccord " <>
        "— dont #{exercising} exercant un cas DISCRIMINANT (`_`, `.`, ou `-` consecutifs)"
    )

    if exercising == 0 and disputed == [] do
      Mix.shell().info(
        "slug_witness: aucun temoin ne DISTINGUE l'algo gele d'une slugification naive. " <>
          "Vert = « rien ne contredit », jamais « l'algo est confirme »."
      )
    end

    if disputed != [], do: exit({:shutdown, 1})
  end

  # Le seul verdict qu'un nom de repertoire seul permet : il ne doit contenir QUE le charset que
  # `slugify/1` peut produire. On ne peut pas inverser un slug pour retrouver le `cwd` (la
  # projection est destructive — `/a_b` et `/a-b` donnent le meme resultat), donc on verifie
  # l'IMAGE de la fonction plutot que son application. Un nom hors charset prouve un algo different
  # sans qu'aucune inversion soit necessaire.
  defp consistent?(slug), do: slug == Fleet.Spawner.SeedStore.slugify(slug)

  # Un temoin ne DISCRIMINE que s'il porte une trace des cas ou l'algo gele se distingue : pas de
  # collapsing des `-`, et tout caractere hors charset devient un `-`. Un `-home-tetris` est
  # compatible avec a peu pres n'importe quelle slugification.
  defp discriminating?(slug), do: String.contains?(slug, "--")

  defp parse_root(args) do
    case OptionParser.parse(args, strict: [root: :string]) do
      {[root: root], _, _} -> root
      _ -> System.user_home!()
    end
  end
end

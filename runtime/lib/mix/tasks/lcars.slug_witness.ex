defmodule Mix.Tasks.Lcars.SlugWitness do
  use Boundary, classify_to: Fleet.Spawner
  use Mix.Task

  @shortdoc "Checks observed session directory names against the slug mirror's output charset"

  @moduledoc """
  Checks directory basenames under **/.claude/projects/ against SeedStore.slugify/1.

    mix lcars.slug_witness
    mix lcars.slug_witness --root /home

  A changed slug algorithm can make resume miss stored sessions. This check only
  tests whether each observed basename is a fixed point of the mirror: it cannot
  recover the original cwd or establish who created the directory. It does not
  compare slugify(cwd) with a vendor result.

  Basenames are deduplicated; the discriminating count only counts names with
  consecutive hyphens. Disputed names exit 1. No witnesses emits a diagnostic
  but still succeeds; neither success case proves algorithm equivalence.
  """

  @impl Mix.Task
  def run(args) do
    root = parse_root(args)

    witnesses =
      [root]
      # Traverse hidden .claude directories; the default wildcard would skip them.
      |> Enum.flat_map(
        &Path.wildcard(Path.join([&1, "**", ".claude", "projects", "*"]), match_dot: true)
      )
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

    cond do
      agreed == [] and disputed == [] ->
        Mix.shell().error(
          "slug_witness: AUCUN TEMOIN sous #{root} — cette execution ne mesure RIEN. Le miroir " <>
            "n'est ni confirme ni contredit. Pointe --root sur un arbre ou des pods ont tourne " <>
            "(le home d'un humain de fleet, ou les pod_dir rapatries d'un conteneur)."
        )

      exercising == 0 and disputed == [] ->
        Mix.shell().info(
          "slug_witness: aucun temoin ne DISTINGUE l'algo gele d'une slugification naive. " <>
            "Vert = « rien ne contredit », jamais « l'algo est confirme »."
        )

      true ->
        :ok
    end

    if disputed != [], do: exit({:shutdown, 1})
  end

  # Slugs cannot be inverted to a unique cwd; this only tests the mirror's image.
  defp consistent?(slug), do: slug == Fleet.Spawner.SeedStore.slugify(slug)

  defp discriminating?(slug), do: String.contains?(slug, "--")

  defp parse_root(args) do
    case OptionParser.parse(args, strict: [root: :string]) do
      {[root: root], _, _} -> root
      _ -> System.user_home!()
    end
  end
end

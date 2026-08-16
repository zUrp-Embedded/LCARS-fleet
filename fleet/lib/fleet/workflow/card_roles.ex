defmodule Fleet.Workflow.CardRoles do
  @moduledoc """
  Does every role a catalogue's cards NAME actually exist in that catalogue?

  ## The edge nobody was checking

  Two boot-time freezes already refuse a broken catalogue, each on its own tree:
  `CapProfile.Image` on the profiles, `SPBuilder.Image` on "a catalogue that DECLARES a role owes
  its prompt". Both are sound and both are blind to the same thing — the edge BETWEEN them.

  Measured 2026-08-16: nothing resolves `steps[].role` or `jury[]` against the cap-profiles. A
  catalogue whose card says `dev` while its profiles declare `developer` passes both freezes (each
  tree is internally fine), boots, and dies at the FIRST dispatch — a role token that was never
  minted, a spawn that refuses a name nobody declared. Far from the cause, and on a message that
  accuses the runtime.

  ## Why it is checked HERE and not at load

  `Loader.load!/2` reads ONE card, on demand, for a project that already exists. By then the
  catalogue is installed, the org is provisioned, and a refusal is a work item that cannot move —
  the operator learns of the hole through a stuck ticket. The question "is this catalogue coherent"
  belongs to the two moments where the answer can still change something: the boot that freezes the
  images, and the install that has not touched the forge yet.

  ## The two places a role may live, and the one it may not

  A role resolves in the catalogue's own profiles, or in `catalogue-system` — the mechanism layer
  (`starfleet`, `chief`, `gatekeeper`, `architect`), inalienable and irreplaceable by design.

  It does NOT resolve in another business catalogue, `fleet` included. ⚖ user, 2026-08-16: `fleet`
  is undeletable to guarantee ONE valid catalogue always exists — availability, not authority. It
  is a peer. `Loader` already says the same thing for the cards themselves: *"a card names roles,
  and a role belongs to the catalogue that declares it — a card from one catalogue over the roles of
  another describes a fleet nobody assembled."* This module is that sentence, enforced.
  """

  alias Fleet.Catalogue

  @doc """
  Every unresolved `card -> role` reference of a catalogue root, as `{card, role}` pairs.

  `{:ok, []}` is a coherent catalogue. `{:error, {:cards_unreadable, …}}` when the tree exists but
  cannot be parsed — distinct from "no cards", which is `{:ok, []}` and a legitimate state for a
  catalogue that carries only profiles.
  """
  @spec unresolved(Path.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def unresolved(root) when is_binary(root) do
    dir = Path.join(root, Catalogue.rel(:workflow_maps))

    if File.dir?(dir) do
      with {:ok, known} <- known_roles(root) do
        dir
        |> Path.join("*.yaml")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
          case roles_of(path) do
            {:ok, roles} ->
              card = Path.basename(path, ".yaml")
              missing = roles |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.map(&{card, &1})
              {:cont, {:ok, acc ++ missing}}

            {:error, reason} ->
              {:halt, {:error, {:cards_unreadable, path, reason}}}
          end
        end)
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Raises unless every card of `root` names roles that resolve. Used at boot and at install — ONE
  check, two moments, so an installed catalogue cannot be coherent at one and broken at the other.
  """
  @spec verify!(Path.t()) :: :ok
  def verify!(root) when is_binary(root) do
    case unresolved(root) do
      {:ok, []} ->
        :ok

      {:ok, missing} ->
        detail = Enum.map_join(missing, ", ", fn {card, role} -> "#{card} -> #{role}" end)

        raise "Workflow.CardRoles: #{root} — #{detail}. A card names a role and the role must be " <>
                "declared by THIS catalogue or by the system layer; a peer catalogue is not a " <>
                "fallback. Unresolved, the ticket dies at dispatch instead of here."

      {:error, reason} ->
        raise "Workflow.CardRoles: #{root} — cards unreadable (#{inspect(reason)}). A catalogue " <>
                "whose cards cannot be parsed cannot be served, and guessing which roles they name " <>
                "would be worse than refusing."
    end
  end

  # The union of what the catalogue declares and what the mechanism layer carries. `index_of/1`
  # answers `{:error, :enoent}` on a missing directory, which is NOT an error here: a catalogue with
  # no profiles of its own is legal as long as its cards only name system roles.
  defp known_roles(root) do
    [
      Path.join(root, Catalogue.rel(:cap_profiles)),
      Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))
    ]
    |> Enum.reduce_while({:ok, MapSet.new()}, fn dir, {:ok, acc} ->
      # La FACADE, pas le sous-module : `Fleet.CapProfile.Catalog` n'est pas exporte par sa
      # frontiere, et l'atteindre elargirait l'API d'un domaine pour un appelant. `index_of/1` est
      # deja la porte, celle que `SPBuilder.Image` emprunte.
      case Fleet.CapProfile.index_of(dir) do
        {:ok, index} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(Map.keys(index)))}}
        {:error, :enoent} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:profiles_unreadable, dir, reason}}}
      end
    end)
  end

  # ⚠ `spec.steps` EST UNE MAP, cle = le nom de l'etape — pas une liste. Ma premiere lecture faisait
  # `List.wrap` dessus, ce qui rend `[la map entiere]`, et `s["role"]` valait donc `nil` : le
  # controle passait sur TOUTES les cartes reelles en n'en lisant aucun role. Mesure du 2026-08-16
  # sur les onze cartes des deux catalogues livres — toutes en map, aucune en liste.
  #
  # Le `jury` existe a la RACINE du spec et par ETAPE. Les onze cartes le portent a la racine
  # aujourd'hui, mais la forme par-etape est lue par le runtime : ne lire que la premiere ferait
  # passer en silence une carte dont le jury d'etape est casse.
  defp roles_of(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = yaml} ->
        spec = Map.get(yaml, "spec", yaml)
        steps = Map.get(spec, "steps", %{})

        per_step =
          case steps do
            %{} = m -> Map.values(m)
            l when is_list(l) -> l
            _ -> []
          end

        roles =
          [jury(spec)] ++ Enum.map(per_step, fn s -> [role_of(s)] ++ jury(s) end)

        {:ok, roles |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()}

      {:ok, other} ->
        {:error, {:not_a_map, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp role_of(%{} = step), do: Map.get(step, "role")
  defp role_of(_), do: nil

  defp jury(%{} = m), do: m |> Map.get("jury", []) |> List.wrap()
  defp jury(_), do: []
end

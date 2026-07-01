defmodule Fleet.Slug do
  @moduledoc """
  Smart-constructor d'un nom CONFINÉ-PAR-CONSTRUCTION utilisé comme composant
  de chemin FS ou segment d'URL borné.

  ## Le problème qu'il ferme

  Un nom fourni par un client / un payload / un catalogue (nom de checkpoint
  `rc_name`, nom de modop, nom de workflow_map/pipeline, nom de repo/branche forge…)
  finit souvent interpolé dans un `Path.join` (feuille FS) ou un segment
  d'URL. S'il porte `..`, `/`, un octet NUL ou un caractère de contrôle, il
  TRAVERSE hors de la racine attendue ou casse/injecte l'URL. Vérifier après
  coup est fragile ; on rend l'état interdit IRREPRÉSENTABLE : on caste le nom
  AU PLUS TÔT, fail-closed, et un nom malformé n'atteint JAMAIS un `Path.join`.

  ## Le contrat du slug

  Un slug valide matche `^[a-z0-9][a-z0-9_-]*$` :

    * minuscules / chiffres / `_` / `-` uniquement ;
    * commence par `[a-z0-9]` (donc PAS de `-`/`_` en tête — pas de slug qui
      ressemble à un flag `-rf`, pas de nom « caché ») ;
    * non-vide ;
    * pas de `/` (un seul composant de chemin), pas de `.` (donc ni `.` ni
      `..` — pas de remontée de répertoire), pas d'octet NUL ni de caractère
      de contrôle (interdits par le charset), pas d'unicode trompeur
      (homoglyphes hors `[a-z0-9_-]` refusés).

  C'est le MÊME charset que les regexes path-safe historiquement recopiées
  (rôle, role_token…) — désormais centralisées ici, une seule source.

  ## Confinement à la feuille FS

  Caster le segment ne suffit pas si la RACINE elle-même est calculée : on
  ajoute `under_root?/2` (le chemin résolu reste `== root` ou sous `root <>
  "/"`) et `confined_join/2` (caste + joint + confine d'un coup). `Path.expand`
  est LEXICAL (résout `..`, pas les symlinks) — le slug a déjà tué le `..`, le
  confinement est la ceinture en plus des bretelles.

  ## Quand NE PAS utiliser le slug (cas URL multi-segment)

  Un `path` forge légitime peut contenir des `/` (`docs/sub/file.md`) : ce
  n'est pas un slug, il faut l'ENCODER (`URI.encode`/`URI.encode_www_form`)
  segment par segment, pas le refuser. Le slug est pour les noms qui DOIVENT
  être atomiques (repo, branche bornée, nom de modop/workflow_map/checkpoint).

  ## NE PAS confondre avec deux autres "slug" (domaines distincts, ne pas fusionner)

  Deux fonctions ressemblent a un slug mais N'EN sont PAS et ne doivent PAS etre rabattues ici :
    * `Fleet.Pilot.PodId.component/1` — TRANSFORME vers le charset pod_id `[A-Za-z0-9._-]` (casse + `.`
      preserves, contrat `valid_pod_id?`) ; `Fleet.Slug` VALIDE/rejette, minuscules strict, sans `.`.
    * `Fleet.Spawner.SeedStore.slugify/1` — reproduit BIT POUR BIT l'algo de Claude Code (compat vendor) ;
      le remplacer par `Fleet.Slug` casserait le resume. Voir le commentaire la-bas.
  """

  # Charset path-safe canon : minuscule/chiffre/`_`/`-`, première position sans `-`/`_`.
  # `\A..\z` (pas `^..$`) → ancrage STRICT début/fin de chaîne entière : `^/$` matchent aussi
  # une frontière de ligne, donc un nom multi-ligne `"ok\n../evil"` passerait `^[a-z0-9...]$`.
  @slug_rx ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @type t :: String.t()

  @doc """
  Caste un nom en slug confiné. `{:ok, slug}` si le nom matche le contrat,
  sinon `{:error, {:invalid_slug, raw}}` (fail-closed — le nom malformé ne
  ressort jamais comme un slug utilisable).
  """
  @spec cast(term()) :: {:ok, t()} | {:error, {:invalid_slug, term()}}
  def cast(name) when is_binary(name) do
    if Regex.match?(@slug_rx, name), do: {:ok, name}, else: {:error, {:invalid_slug, name}}
  end

  def cast(name), do: {:error, {:invalid_slug, name}}

  @doc """
  Variante fail-loud de `cast/1` pour les sites où un slug invalide est un bug
  de programmation (jamais une entrée client) : raise `ArgumentError`.
  """
  @spec cast!(term()) :: t()
  def cast!(name) do
    case cast(name) do
      {:ok, slug} -> slug
      {:error, {:invalid_slug, raw}} -> raise ArgumentError, "slug invalide: #{inspect(raw)}"
    end
  end

  @doc "Prédicat : `name` est-il un slug valide ?"
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name), do: Regex.match?(@slug_rx, name)
  def valid?(_), do: false

  @doc """
  Garde de confinement : le chemin `dest` résolu reste-t-il SOUS `root`
  (`== root` ou commence par `root <> "/"`) ? `Path.expand` résout les `..`
  lexicalement → un `dest` qui remonte au-dessus de la racine est rejeté.
  Les deux côtés sont expandés (un `root` relatif ne fausse pas la comparaison).
  """
  @spec under_root?(Path.t(), Path.t()) :: boolean()
  def under_root?(dest, root) when is_binary(dest) and is_binary(root) do
    expanded_root = Path.expand(root)
    expanded_dest = Path.expand(dest)
    expanded_dest == expanded_root or String.starts_with?(expanded_dest, expanded_root <> "/")
  end

  @doc """
  Joint un `name` casté-en-slug SOUS `root` et VÉRIFIE le confinement. C'est le
  geste complet attendu à une feuille FS dont le composant vient d'une entrée :
  `{:ok, abs}` (slug valide ET chemin confiné sous la racine), sinon
  `{:error, {:invalid_slug, name}}` (nom malformé) ou
  `{:error, {:path_escape, abs}}` (le confinement échoue — garde en
  ceinture+bretelles : avec un slug le `..` est déjà impossible, mais si la
  racine elle-même est suspecte on refuse plutôt que d'écrire hors-zone).
  """
  @spec confined_join(Path.t(), term()) ::
          {:ok, Path.t()} | {:error, {:invalid_slug, term()} | {:path_escape, Path.t()}}
  def confined_join(root, name) when is_binary(root) do
    with {:ok, slug} <- cast(name) do
      abs = Path.expand(Path.join(root, slug))
      if under_root?(abs, root), do: {:ok, abs}, else: {:error, {:path_escape, abs}}
    end
  end
end

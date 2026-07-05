defmodule Fleet.CapProfile.CanonicalJson do
  @moduledoc """
  Encodage JSON CANONIQUE (déterministe) + hash sha256 — le concern
  « déterminisme de composition » du cap-profile, ORTHOGONAL au reste de
  l'app : il ne touche ni le loader (`load`/`compose`/`validate`), ni les
  accesseurs du struct, ni le catalogue FS. Extrait de `Fleet.CapProfile`
  pour cette raison (éclatement C4 2026-07-05).

  ## Pourquoi un encodeur canon (et pas `Jason.encode!` direct)

  Deux maps ÉGALES (mêmes paires clé/valeur) peuvent s'itérer dans des ordres
  différents selon leur historique de construction — `Jason.encode!` produirait
  alors deux strings différentes, donc deux sha256 différents pour LA MÊME
  composition. L'encodeur canon rend le hash indépendant de l'ordre d'itération :
  clés converties en string puis triées RÉCURSIVEMENT avant encodage. C'est ce
  qui porte l'assertion « même composition ⇒ même hash » que les appelants de
  `Fleet.CapProfile.sha256/1` vérifient.

  ## Format FIGÉ (le hash en dépend)

  L'encodage est un format de HACHAGE stable : `{"k":v,...}` trié, listes dans
  l'ordre, scalaires via `Jason.encode!`. Le changer invalide tous les sha256
  déjà constatés (assertions de déterminisme, comparaisons de composition).
  Volontairement PAS un protocole `Jason.Encoder` custom : hors du chemin Jason
  standard, aucune option d'encodage globale ne peut faire dériver les hashes.
  """

  @doc """
  Encode `value` en JSON canonique : clés de map stringifiées puis triées
  récursivement, listes encodées dans l'ordre, scalaires via l'encodeur JSON
  standard. Les structs ne sont PAS acceptées en position map (pas de clause :
  l'appelant les aplatit d'abord en map plate — cf. `Fleet.CapProfile.sha256/1`) —
  encoder une struct par ses champs internes silencieusement produirait un hash
  dépendant de la forme du struct, pas de la donnée.
  """
  @spec encode(term()) :: String.t()
  def encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_string(k), encode(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> v end)
      |> Enum.join(",")

    "{" <> pairs <> "}"
  end

  def encode(list) when is_list(list) do
    inner = list |> Enum.map(&encode/1) |> Enum.join(",")
    "[" <> inner <> "]"
  end

  def encode(other), do: Jason.encode!(other)

  @doc """
  sha256 (hex minuscules) de l'encodage canonique de `map`. L'ordre d'itération
  interne de la map est sans effet — même contenu ⇒ même hash.
  """
  @spec sha256(map()) :: String.t()
  def sha256(map) when is_map(map) and not is_struct(map) do
    map
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

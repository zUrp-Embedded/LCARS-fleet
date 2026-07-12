defmodule Fleet.CapProfile.CanonicalJsonPropertyTest do
  @moduledoc """
  Preuve property-based de l'encodeur canonique. Les 3 properties déjà en place
  (`cap_profile_test.exs`) prouvent la STABILITÉ du hash — même contenu ⇒ même sha256, quel
  que soit l'ordre d'insertion. Aucune ne prouve la FIDÉLITÉ : un encodeur qui PERDRAIT une
  entrée (ou en écraserait une) les passerait TOUTES LES TROIS, puisqu'il perdrait la même
  entrée de façon déterministe.

  Ce fichier ferme ce trou. Le sha256 d'un cap-profile est son IDENTITÉ (comparaison de
  compositions, assertions de déterminisme) : un hash stable posé sur un encodage amputé,
  ce sont deux profils DIFFÉRENTS qui portent la même identité — exactement l'ambiguïté que
  la garde anti-collision du module refuse déjà de mint, mais par l'autre bout.

  (La fidélité `decode ∘ encode == id` implique l'INJECTIVITÉ de l'encodeur : deux contenus
  distincts ne peuvent pas hasher pareil. C'est ce que « stable » seul ne dit pas.)
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.CapProfile.CanonicalJson

  # ── générateurs ──

  defp json_scalar do
    one_of([
      string(:printable, max_length: 8),
      integer(),
      float(),
      boolean(),
      constant(nil)
    ])
  end

  defp json_key, do: string(:alphanumeric, min_length: 1, max_length: 6)

  # Valeur JSON récursive (maps/listes imbriquées) — la forme réelle d'un cap-profile composé
  # (`permissions`, `knowledge`, `modop_set`… sont des sous-arbres).
  defp json_value do
    tree(json_scalar(), fn child ->
      one_of([list_of(child, max_length: 3), map_of(json_key(), child, max_length: 3)])
    end)
  end

  defp json_map, do: map_of(json_key(), json_value(), max_length: 5)

  # Charset volontairement ÉTROIT : les clés des properties de collision passent par
  # `String.to_atom/1` — l'atom table ne doit pas enfler (≤ 155 atomes possibles ici).
  defp small_key, do: string([?a..?e], min_length: 1, max_length: 3)

  # ── P1 — FIDÉLITÉ ──

  # INVARIANT : l'encodage canonique est du JSON VALIDE qui redonne EXACTEMENT la map d'origine
  # (`Jason.decode!(encode(m)) == m`) — rien de perdu, rien d'ajouté, rien d'écrasé, à toute
  # profondeur.
  # POURQUOI : les 3 properties existantes ne testent que `sha256(m) == sha256(m)`. Un encodeur
  # qui laisserait tomber la dernière clé, ou qui aplatirait une map imbriquée, serait
  # parfaitement STABLE — donc parfaitement vert — tout en faisant collider deux compositions
  # distinctes sur un même sha256. La fidélité est ce qui fait du hash une IDENTITÉ et pas
  # seulement une empreinte reproductible.
  property "P1 FIDÉLITÉ — Jason.decode!(encode(m)) == m (la canonisation ne perd RIEN)" do
    check all(m <- json_map(), max_runs: 300) do
      assert Jason.decode!(CanonicalJson.encode(m)) == m
    end
  end

  # Corollaire direct et load-bearing : l'encodeur est INJECTIF → deux contenus DIFFÉRENTS ne
  # peuvent pas produire le même sha256. « Même contenu ⇒ même hash » (déjà prouvé) sans
  # « contenu différent ⇒ hash différent » serait satisfait par un encodeur constant.
  property "P1b INJECTIVITÉ — deux maps différentes ⇒ deux sha256 différents" do
    check all(m1 <- json_map(), m2 <- json_map(), max_runs: 200) do
      if m1 != m2 do
        assert CanonicalJson.sha256(m1) != CanonicalJson.sha256(m2)
      end
    end
  end

  # INVARIANT : une clé atome est encodée comme sa forme string (`to_string/1`), valeur intacte.
  # POURQUOI : `Fleet.CapProfile.sha256/1` aplatit un struct en map — les clés y arrivent en
  # ATOMES. Si la stringification perdait ou renommait une clé, le hash d'un profil chargé
  # (atomes) différerait de celui du même profil relu depuis le JSON (strings) : deux identités
  # pour un seul contenu, de part et d'autre de la frontière struct/JSON.
  property "P1c — clé atome ⇒ clé string homonyme, valeur intacte, MÊME hash" do
    check all(m <- map_of(small_key(), json_scalar(), max_length: 5)) do
      atom_map = Map.new(m, fn {k, v} -> {String.to_atom(k), v} end)

      assert Jason.decode!(CanonicalJson.encode(atom_map)) == m
      assert CanonicalJson.sha256(atom_map) == CanonicalJson.sha256(m)
    end
  end

  # ── P2 — GARDE COLLISION ──

  # INVARIANT : toute map portant à la fois `:k` et `"k"` fait LEVER `encode/1` (ArgumentError),
  # quels que soient les autres contenus et l'ordre d'insertion.
  # POURQUOI : après stringification les deux clés deviennent `"k"` → `{"k":v1,"k":v2}`, un JSON
  # à clés dupliquées dont l'ordre dépend de l'itération de la map. Le hash cesserait d'être une
  # FONCTION du contenu : le même cap-profile pourrait hasher différemment d'un run à l'autre.
  # Le module choisit fail-loud plutôt qu'une identité silencieusement instable — la property
  # verrouille le « TOUJOURS », qu'un exemple câblé ne peut pas donner.
  property "P2 GARDE COLLISION — clé atome :k + clé string \"k\" ⇒ encode/1 lève TOUJOURS" do
    check all(
            k <- small_key(),
            v1 <- json_scalar(),
            v2 <- json_scalar(),
            noise <- json_map()
          ) do
      colliding =
        noise
        |> Map.delete(k)
        |> Map.put(k, v1)
        |> Map.put(String.to_atom(k), v2)

      assert_raise ArgumentError, fn -> CanonicalJson.encode(colliding) end
      assert_raise ArgumentError, fn -> CanonicalJson.sha256(colliding) end
    end
  end

  # La garde tient en PROFONDEUR (encode/1 est récursif, la garde aussi). Un encodeur qui ne
  # garderait que le 1er niveau laisserait passer l'identité instable là où elle est le plus
  # dure à voir : un sous-arbre (`permissions`, `knowledge`) d'un cap-profile composé.
  property "P2b — la garde collision tient dans une map IMBRIQUÉE" do
    check all(k <- small_key(), outer <- small_key(), v1 <- json_scalar(), v2 <- json_scalar()) do
      nested = %{outer => %{k => v1, String.to_atom(k) => v2}}

      assert_raise ArgumentError, fn -> CanonicalJson.encode(nested) end
    end
  end
end

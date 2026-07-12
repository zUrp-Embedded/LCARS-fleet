defmodule Fleet.SlugPropertyTest do
  @moduledoc """
  Preuve property-based du CONFINEMENT (`confined_join/2`). `slug_test.exs` prouve déjà le
  smart-constructor `cast/1` (charset, refus des traversées) et ses deux properties portent sur
  le NOM. Ici on attaque l'autre moitié du geste — la RACINE.

  `cast/1` ne suffit pas si la root elle-même est calculée : c'est exactement ce que dit le
  moduledoc (« la ceinture par-dessus les bretelles »). La property bombarde donc des roots
  TORDUES (relatives, `..`, `.`, `//`, slash final, vide) et exige, pour chaque sortie possible,
  que le résultat ne soit JAMAIS un chemin absolu HORS de la root — ni une exception.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Slug

  # ── générateurs ──

  defp seg, do: string([?a..?z], min_length: 1, max_length: 5)

  # Grammaire du slug : `[a-z0-9][a-z0-9_-]*`.
  defp valid_slug do
    gen all(
          head <- string([?a..?z, ?0..?9], length: 1),
          tail <- string([?a..?z, ?0..?9, ?_, ?-], max_length: 12)
        ) do
      head <> tail
    end
  end

  # Roots tordues : toutes les formes qu'un chemin CALCULÉ peut prendre quand il vient d'une
  # config, d'un env var ou d'une concaténation — y compris celles qui remontent.
  defp root_gen do
    gen all(
          segs <- list_of(seg(), max_length: 3),
          shape <-
            member_of([:abs, :rel, :dot, :dotdot, :climb, :double_slash, :trailing, :empty, :root])
        ) do
      base = Enum.join(segs, "/")

      case shape do
        :abs -> "/srv/" <> base
        :rel -> base
        :dot -> "./" <> base
        :dotdot -> "/srv/" <> base <> "/.."
        :climb -> "/srv/" <> base <> "/../../../.."
        :double_slash -> "//srv//" <> base
        :trailing -> "/srv/" <> base <> "/"
        :empty -> ""
        :root -> "/"
      end
    end
  end

  # Noms : slugs valides ET tout ce qu'un payload/catalogue peut envoyer à leur place.
  defp name_gen do
    one_of([
      valid_slug(),
      string(:printable, max_length: 12),
      member_of([
        "..",
        "../evil",
        "../../etc/passwd",
        "a/b",
        "/abs",
        ".",
        "",
        "-rf",
        "_hidden",
        "ok\nevil",
        "ok\0evil",
        "a b",
        "Ok",
        "été"
      ])
    ])
  end

  # ── P1 — CONFINEMENT ──

  # INVARIANT : pour TOUTE root (même tordue) et TOUT nom, `confined_join/2` rend
  #   • soit `{:ok, abs}` avec `abs` ABSOLU et SOUS `Path.expand(root)` (== root, ou préfixé
  #     par `root <> "/"`), sans `..` résiduel ;
  #   • soit une erreur TYPÉE (`{:invalid_slug, name}` | `{:path_escape, abs}`).
  # Jamais d'exception. Jamais un chemin hors root.
  # POURQUOI : c'est le dernier rempart avant un `File.write`/`File.rm_rf` sur un chemin dont un
  # segment vient d'un input. Un seul `{:ok, abs}` hors root, et on écrit (ou on efface) hors
  # zone. Une exception non typée, elle, casse l'appelant qui attend un `{:error, _}` fail-closed.
  property "P1 CONFINEMENT — {:ok, abs} toujours sous la root, sinon erreur typée, jamais de raise" do
    check all(root <- root_gen(), name <- name_gen(), max_runs: 400) do
      expanded_root = Path.expand(root)

      case Slug.confined_join(root, name) do
        {:ok, abs} ->
          assert Path.type(abs) == :absolute, "chemin non absolu : #{inspect(abs)}"

          # Oracle du confinement, indépendant de l'implémentation : `abs` est la root elle-même,
          # ou l'un de ses descendants — comparaison par COMPOSANTS (Path.split), pas par préfixe
          # de chaîne. Le préfixe naïf `expanded_root <> "/"` est exactement le bug corrigé côté
          # code (root `/` → préfixe `//` que rien ne porte) : un oracle qui recopie le bug du
          # code ne peut pas le trouver.
          root_parts = Path.split(expanded_root)
          abs_parts = Path.split(abs)

          assert Enum.take(abs_parts, length(root_parts)) == root_parts,
                 "ÉVASION : #{inspect(abs)} hors de #{inspect(expanded_root)} " <>
                   "(root=#{inspect(root)}, name=#{inspect(name)})"

          assert Slug.under_root?(abs, root)
          refute String.contains?(abs, "/../"), "`..` résiduel non résolu dans #{inspect(abs)}"
          # Le nom accepté est un slug valide, donc un composant de chemin UNIQUE.
          assert Slug.valid?(name)
          assert Path.basename(abs) == name

        {:error, {:invalid_slug, raw}} ->
          assert raw == name
          refute Slug.valid?(name), "rejeté comme invalid_slug alors que le slug est valide"

        {:error, {:path_escape, abs}} ->
          # Sortie fail-closed : on refuse plutôt que d'écrire hors zone. Le chemin est rendu
          # pour le diagnostic, il n'est PAS utilisable.
          assert is_binary(abs)

          # ⚠ VERROU (défaut trouvé PAR cette property) : avec un slug VALIDE, `..` est déjà
          # impossible par construction → `:path_escape` ne doit JAMAIS tirer. Il tirait pourtant
          # sur la root `/` : `under_root?` comparait au préfixe `root <> "/"`, soit `"//"` pour
          # la racine — qu'aucun chemin étendu ne porte. Fail-closed, donc pas une évasion, mais
          # un garde qui refuse le cas LÉGAL est un garde inutilisable (et son contrat, un
          # mensonge). Sans ce refute, la property restait verte sur le bug : les deux issues
          # étaient acceptées.
          refute Slug.valid?(name),
                 "path_escape sur un slug VALIDE (root=#{inspect(root)}, name=#{inspect(name)}) " <>
                   "— un slug ne peut pas s'évader : c'est la root qui est mal comparée"
      end
    end
  end

  # RÉGRESSION du même défaut, en toutes lettres (la root `/` est un cas limite légal : un
  # store monté à la racine, un test qui joint sous `/`).
  test "RÉGRESSION — root `/` : confined_join joint, under_root? reconnaît (plus de faux-rejet)" do
    assert {:ok, "/proj"} = Slug.confined_join("/", "proj")
    assert Slug.under_root?("/x", "/")
    assert Slug.under_root?("/", "/")
    # Les roots qui S'ÉTENDENT en `/` sont couvertes par le même chemin.
    assert {:ok, "/proj"} = Slug.confined_join("//", "proj")
    assert {:ok, "/proj"} = Slug.confined_join("/a/../..", "proj")
  end

  # ── P2 — IDEMPOTENCE / feuille exacte ──

  # INVARIANT : pour tout `s` engendré par la grammaire du slug, `cast(s) == {:ok, s}` (le
  # smart-constructor ne TRANSFORME rien, il valide) et, sous une root propre, `confined_join`
  # rend exactement la feuille `Path.expand(root) <> "/" <> s`.
  # POURQUOI : si `cast/1` normalisait le nom en douce (lowercase, trim, substitution), le
  # chemin écrit ne serait plus celui que l'appelant croit avoir demandé — deux pods pourraient
  # se retrouver dans le MÊME pod_dir après collision de normalisation. Le contrat est
  # « valide ou refuse », jamais « répare ».
  property "P2 IDEMPOTENCE — cast(s) == {:ok, s} et la feuille jointe est exactement root/s" do
    check all(s <- valid_slug(), segs <- list_of(seg(), min_length: 1, max_length: 3)) do
      assert {:ok, ^s} = Slug.cast(s)
      assert Slug.valid?(s)

      root = "/" <> Enum.join(segs, "/")
      assert {:ok, abs} = Slug.confined_join(root, s)
      assert abs == root <> "/" <> s
    end
  end

  # ── NOTE D'AUDIT (lot 8) — défaut RAPPORTÉ, non corrigé ──
  #
  # `under_root?/2` est FAUX pour `root == "/"` : il teste `dest == root or dest starts_with
  # root <> "/"`, or pour root `"/"` la concaténation donne `"//"` — et `"/x"` ne commence pas
  # par `"//"`.
  #     Slug.under_root?("/x", "/")        == false   (attendu : true — "/x" EST sous "/")
  #     Slug.confined_join("/", "proj")    == {:error, {:path_escape, "/proj"}}
  # Conséquence : une root `"/"` (ou toute root qui `Path.expand` vers `"/"`, ex. `"//"`) rend
  # `confined_join/2` INUTILISABLE — il refuse systématiquement. Le sens du défaut est FAIL-CLOSED
  # (faux-rejet, pas faux-accept) : aucune évasion, d'où la property P1 qui reste verte en
  # classant ce cas dans la branche `{:path_escape, _}`. Ce n'est donc pas un trou de sécurité,
  # mais un faux-rejet dans une garde dont le contrat annoncé est « == root ou sous root ».
end

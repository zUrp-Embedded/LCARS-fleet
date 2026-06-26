defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  Encodeur PUR du `session_id` claude DÉTERMINISTE (hexspeak) d'un pod fleet. Il transforme un
  triplet `(role_index, protected, repo[, pool])` — fourni par l'APPELANT — en UUID hexspeak stable,
  sans suffixe timestamp. Il ne CATALOGUE plus les rôles : la source du QUOI (l'index de rôle, le tier
  protégé, le caractère fleet-level) est le cap-profile du rôle (`metadata.role_index` / `protected` /
  `fleet_level`, lus via `Fleet.CapProfile`). Ici on ne fait que l'arithmétique de la string.

  Format : `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`

    - `<T>`            tier : `0` = protégé (`0badcafe`) · `1` = worker (`1badcafe`). Le bit vient de
                      l'argument `protected` (= `metadata.protected` du cap-profile). `badcafe` =
                      marqueur-kill universel → `pkill -f 1badcafe` nuke les workers et ÉPARGNE les
                      protégés (arch terminal user) ; `pkill -f badcafe` = tout.
    - `feed-4dad-babe` filler hexspeak fixe (`4` de `4dad` = nibble version UUID ; `b` de `babe` =
                      nibble variant RFC4122 valide → la string EST un UUID légal, accepté `--session-id`).
    - `<REPO4>`       id forge du repo, en **DÉCIMAL** 4 chiffres (la forge crée l'id en décimal → `grep
                      <id>dec0de` direct, zéro conversion). `0000` = fleet-level (permanents). Les chiffres
                      `0-9` ⊂ hex → l'UUID reste légal. **DETTE ASSUMÉE** : cap 9999 ; l'appelant passe un
                      repo dans `0..9999` (le repo 10000 collisionnerait le repo 0, etc. — accepté : on ne
                      rouvrira pas un vieux projet au moment d'en créer 10000).
    - `dec0de`        filler.
    - `<P><R>`        pool (nibble haut, `0` = séquentiel) + index de rôle (nibble bas) — **HEX** (R=0-F).
                      `R` = l'argument `role_index` (= `metadata.role_index` du cap-profile), PAS un
                      catalogue local : le mapping rôle → slot vit côté cap-profile.

  Le QUOI (rôle/tier/projet) est DÉCLARÉ par le cap-profile ; le QUI vit sur l'axe OS (UID hérité — le
  pod tourne sous l'UID de l'humain) — jamais dupliqués (UID-dans-UUID rejeté). Module PUR (zéro
  process, zéro IO, zéro catalogue) : un encodeur TOTAL sur des entrées valides — aucun refus de rôle
  (starfleet, rôle inconnu : ces décisions vivent au niveau spawn, pas ici), aucun `{:error, _}`. Une
  entrée hors-borne = bug appelant → function-clause/raise.
  """
  import Bitwise

  @doc """
  Encode le triplet `(role_index, protected, repo[, pool])` en UUID hexspeak déterministe.

  `role_index` (0..15) et `protected` (tier épargné par le kill des workers) viennent du cap-profile
  (`metadata.role_index` / `protected`). `repo` = id forge DÉCIMAL (0..9999 ; `0` = fleet-level, pas de
  dimension projet). `pool` = nibble haut de `<P><R>` (0 = séquentiel, défaut).

  Total sur entrées valides : aucun `{:error, _}` — une entrée hors-borne déclenche un function-clause
  (bug appelant), pas un retour d'erreur.
  """
  @spec encode(0..15, boolean(), 0..9999, 0..0xF) :: String.t()
  def encode(role_index, protected, repo, pool \\ 0)
      when is_integer(role_index) and role_index in 0..15 and is_boolean(protected) and
             repo in 0..9999 and pool in 0..0xF do
    t = if protected, do: 0, else: 1
    xx = bsl(pool, 4) ||| role_index

    # repo = DÉCIMAL (la forge le crée en décimal → grep direct) ; tier + XX = HEX (compteur natif).
    "#{hex(t, 1)}badcafe-feed-4dad-babe-#{dec(repo, 4)}dec0de#{hex(xx, 2)}"
  end

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # DÉCIMAL zéro-paddé (id forge tel que la forge le crée → grep direct). Chiffres `0-9` ⊂ hex.
  defp dec(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end

defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  Builder du `session_id` claude DÉTERMINISTE (hexspeak) d'un pod fleet : keyé sur
  (repo, rôle), stable, sans suffixe timestamp.

  Format : `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`

    - `<T>`            tier : `0` = protégé (arch, starfleet → `0badcafe`) · `1` = worker (`1badcafe`).
                      `badcafe` = marqueur-kill universel → `pkill -f 1badcafe` nuke les workers et
                      ÉPARGNE l'arch (terminal user) ; `pkill -f badcafe` = tout.
    - `feed-4dad-babe` filler hexspeak fixe (`4` de `4dad` = nibble version UUID ; `b` de `babe` =
                      nibble variant RFC4122 valide → la string EST un UUID légal, accepté `--session-id`).
    - `<REPO4>`       id forge du repo, en **DÉCIMAL** 4 chiffres (la forge crée l'id en décimal → `grep
                      <id>dec0de` direct, zéro conversion). `0000` = fleet-level (permanents). Les chiffres
                      `0-9` ⊂ hex → l'UUID reste légal. **DETTE ASSUMÉE** : cap 9999 ; `rem(id, 10000)` →
                      le repo 10000 collisionne le repo 0, 10001↔1, etc. Accepté (on ne rouvrira pas un
                      vieux projet au moment d'en créer 10000) — la seule dette qu'on s'accorde ici.
    - `dec0de`        filler.
    - `<P><R>`        pool (nibble haut, `0` = séquentiel) + rôle (nibble bas, catalogue) — **HEX** (R=0-F,
                      notre compteur natif ; grep-hex assumé).

  Catalogue rôle → R (16 slots ; l'ordre est interne — personne n'inspecte les UUID à l'œil) :

      R  rôle                      tier
      0  starfleet                 0badcafe   ← hors-fleet, l'opérateur bootstrap ; PAS de pod (build REFUSE)
      1  architect                 0badcafe
      2  gatekeeper                1badcafe
      3  engineer                  1badcafe
      4  qualifier                 1badcafe
      5  reviewer                  1badcafe
      6  consultant                1badcafe
      7..F  réservés (placeholders, rôles non encore écrits)

  Le QUOI (rôle/tier/projet) vit ici ; le QUI vit sur l'axe OS (UID hérité — le pod tourne sous
  l'UID de l'humain) — jamais dupliqués (UID-dans-UUID rejeté). Module PUR (zéro process, zéro IO).
  """
  import Bitwise

  @role_index %{
    "starfleet" => 0x0,
    "architect" => 0x1,
    "gatekeeper" => 0x2,
    "engineer" => 0x3,
    "qualifier" => 0x4,
    "reviewer" => 0x5,
    "consultant" => 0x6
    # 0x7..0xF : réservés (placeholders) — un rôle futur prend le prochain nibble libre.
  }

  # Tier protégé `0badcafe` (épargné par `pkill -f 1badcafe`). Le reste = worker `1badcafe`.
  @protected MapSet.new(["starfleet", "architect"])

  # Rôles FLEET-LEVEL : une seule instance, repo toujours `0000` (pas de dimension projet). Les rôles
  # project-bound (eng, juges) portent le repo dans l'UUID → ne JAMAIS les minter sans repo (collision
  # inter-projet/rework). Axe orthogonal au tier : le gatekeeper est worker (`1badcafe`) ET fleet-level.
  @fleet_level MapSet.new(["architect", "gatekeeper"])

  @doc """
  `{:ok, session_id}` pour un rôle catalogué, sinon `{:error, reason}`.

  `starfleet` est REFUSÉ (`:starfleet_hors_fleet`) : c'est l'opérateur bootstrap, hors-fleet, sans pod —
  il ne reçoit JAMAIS un session_id fleet (axe OS, vu comme un humain par le runtime). Son slot `R=0`
  est réservé pour qu'aucun autre rôle ne le prenne, mais il n'est pas mintable.
  """
  @spec build(String.t(), 0..9999, 0..0xF) :: {:ok, String.t()} | {:error, atom()}
  def build(role, repo \\ 0x0000, pool \\ 0)

  def build("starfleet", _repo, _pool), do: {:error, :starfleet_hors_fleet}

  def build(role, repo, pool)
      when is_binary(role) and repo in 0..9999 and pool in 0..0xF do
    case @role_index do
      %{^role => r} ->
        t = if MapSet.member?(@protected, role), do: 0, else: 1
        xx = bsl(pool, 4) ||| r

        # repo = DÉCIMAL (la forge le crée en décimal → grep direct) ; tier + XX = HEX (compteur natif).
        {:ok, "#{hex(t, 1)}badcafe-feed-4dad-babe-#{dec(repo, 4)}dec0de#{hex(xx, 2)}"}

      _ ->
        {:error, :unknown_role}
    end
  end

  @doc """
  Variante qui raise sur rôle inconnu/refusé — pour les call-sites qui SAVENT le rôle valide.
  """
  @spec build!(String.t(), 0..9999, 0..0xF) :: String.t()
  def build!(role, repo \\ 0x0000, pool \\ 0) do
    case build(role, repo, pool) do
      {:ok, id} ->
        id

      {:error, reason} ->
        raise ArgumentError, "SessionId.build!(#{inspect(role)}) → #{inspect(reason)}"
    end
  end

  @doc """
  Le rôle a-t-il un session_id déterministe (→ on câble le builder ; sinon random `UUID.uuid4()`) ?
  `starfleet` exclu (hors-fleet).
  """
  @spec deterministic?(String.t()) :: boolean()
  def deterministic?(role) when is_binary(role),
    do: role != "starfleet" and Map.has_key?(@role_index, role)

  @doc """
  Rôle FLEET-LEVEL (une instance, repo `0000`) ? Les project-bound (eng, juges) exigent le repo —
  on ne les minte qu'avec un `repo_id` connu (sinon collision inter-projet).
  """
  @spec fleet_level?(String.t()) :: boolean()
  def fleet_level?(role) when is_binary(role), do: MapSet.member?(@fleet_level, role)

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # DÉCIMAL zéro-paddé (id forge tel que la forge le crée → grep direct). Chiffres `0-9` ⊂ hex.
  defp dec(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end

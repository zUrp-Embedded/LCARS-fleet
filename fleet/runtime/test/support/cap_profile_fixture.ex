defmodule Fleet.Support.CapProfileFixture do
  @moduledoc """
  Builder de fixtures `%Fleet.CapProfile{}` adossé au constructeur validé `Fleet.CapProfile.from_map!/1`
  (BND-001) : une fixture NOMINALE franchit la MÊME frontière schema que la prod, au lieu de forger un
  `%CapProfile{spec: …}` partiel qui court-circuite le schema (l'état invalide redevenu représentable).

  `build/2` part d'un profil CANON réel (le YAML de `priv/cap_profile/canon/cap-profiles/` lu DIRECTEMENT
  — source unique = le canon, pas une 2e copie du schema en dur ; lecture par chemin priv, indépendante du
  `:root_dir` global que d'autres tests mutent), deep-merge les `overrides` (clés stringifiées), et
  RE-VALIDE le tout. Un override qui casse le schema fait raise à la construction : la fixture est fausse,
  pas le code.

  À NE PAS utiliser pour tester DÉLIBÉRÉMENT un profil schema-bypassé (p.ex. le fail-loud d'un accesseur
  sur un champ absent) : ces cas restent `%CapProfile{}` hand-built, dans un test explicitement nommé
  « schema bypass » — le builder ne les remplace pas.
  """
  use Boundary, deps: [Fleet.CapProfile], exports: []

  alias Fleet.CapProfile

  @canon_rel Path.join(["cap_profile", "canon", "cap-profiles"])

  @doc """
  Profil canon `base_role` (défaut `"engineer"`) deep-mergé avec `overrides` (clés stringifiées) puis
  RE-VALIDÉ via `Fleet.CapProfile.from_map!/1`. Rend un `%CapProfile{}` schema-conforme, ou raise.
  """
  @spec build(map(), String.t()) :: CapProfile.t()
  def build(overrides \\ %{}, base_role \\ "engineer") do
    CapProfile.from_map!(deep_merge(canon_base(base_role), stringify(overrides)))
  end

  # Lit le YAML canon DIRECTEMENT (chemin priv figé) — pas via le loader, dont le `:root_dir` est un
  # global qu'un autre test peut avoir repointé vers un catalogue tmp sans ce rôle.
  defp canon_base(role) do
    path = Path.join([:code.priv_dir(:lcars_fleet), @canon_rel, "#{role}.yaml"])
    {:ok, raw} = YamlElixir.read_from_file(path)
    raw
  end

  defp deep_merge(l, r) when is_map(l) and is_map(r),
    do: Map.merge(l, r, fn _k, lv, rv -> deep_merge(lv, rv) end)

  defp deep_merge(_l, r), do: r

  defp stringify(m) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end

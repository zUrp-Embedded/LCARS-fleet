defmodule Fleet.CapProfile.Invariants do
  @moduledoc """
  Invariants métier G24 **purs** d'un `%Fleet.CapProfile{}` composé
  (canon cap-profile v2.5 + gate containment).

  Cluster de validation PUR extrait de `Fleet.CapProfile` : une fonction par
  check, agrégées par `violations/1`. Fonction pure — aucune lecture de
  process ni de FS (même struct ⇒ même verdict), zéro I/O.
  `Fleet.CapProfile.validate/1` DÉLÈGUE ici : il enveloppe `violations/1` dans
  son contrat de retour (`:ok | {:error, [atom()]}`) et porte le `@doc`
  détaillé (invariants implémentés, invariants exclus parce qu'impurs).

  Le vocabulaire d'atomes d'erreur (`:g24_1`, `:g24_3`, … `:g24_14`) est
  **FIGÉ** : les tests ET `mix lcars.contracts.check` matchent ces codes
  précis — ne pas les renommer.

  Sens de dépendance UNIQUE (pas de cycle) : ce module dépend du struct
  `%Fleet.CapProfile{}` (compile-dep) ; `Fleet.CapProfile.validate/1` appelle
  `violations/1` (runtime-dep).
  """

  alias Fleet.CapProfile

  @kind_pinned "CapabilityProfile"

  # g24_9 — refuser les server-tools natifs Anthropic : ils tournent côté serveur, PAS dans le pod → le sandbox bwrap ne les contient pas par construction.
  # Entrées strict = égalité, entrées prefix = `String.starts_with?/2`.
  @disallowed_minimum_strict ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution)
  @disallowed_minimum_prefix ~w(tool_search_)

  @containment_enum ~w(bwrap none)
  @lifetime_scope_enum ~w(one-shot pipe run forever)

  @doc """
  Liste des codes d'invariants G24 VIOLÉS par le profil composé (`[]` = tous
  passent). Ordre stable = ordre de déclaration du registre ci-dessous.
  Pure : même struct ⇒ même liste.

  `Fleet.CapProfile.validate/1` est l'unique consommateur ; il traduit `[]`
  en `:ok` et une liste non-vide en `{:error, list}`.
  """
  @spec violations(CapProfile.t()) :: [atom()]
  def violations(%CapProfile{} = profile) do
    # Pas de check apiVersion (l'ancien g24_2) : le champ apiVersion n'existe pas.
    [
      {:g24_1, &check_containment/1},
      {:g24_3, &check_kind/1},
      {:g24_4, &check_lifetime_scope/1},
      {:g24_6, &check_modop_incompatible/1},
      {:g24_8, &check_metadata_name/1},
      {:g24_9_strict, &check_disallowed_strict/1},
      {:g24_9_prefix, &check_disallowed_prefix/1},
      {:g24_10, &check_boot_at_start_forever/1},
      {:g24_11, &check_subagent_template_one_shot/1},
      {:g24_12, &check_host_native_containment/1},
      {:g24_14, &check_monk_registry_pairing/1}
    ]
    |> Enum.reject(fn {_code, fun} -> fun.(profile) == :ok end)
    |> Enum.map(fn {code, _fun} -> code end)
  end

  # ============================================================
  # G24 invariants (one function per check)
  # ============================================================

  defp check_containment(%CapProfile{metadata: meta}) do
    if Map.get(meta, "containment") in @containment_enum, do: :ok, else: :error
  end

  defp check_kind(%CapProfile{kind: k}) do
    if k == @kind_pinned, do: :ok, else: :error
  end

  defp check_lifetime_scope(%CapProfile{spec: spec}) do
    # Canon : lifetime_scope est nesté sous `spec.invocation` (schema
    # cap-profile-v2.5.json + cap-profiles canon), pas au niveau de `spec` —
    # lire `spec.lifetime_scope` directement raterait la valeur.
    if get_in(spec, ["invocation", "lifetime_scope"]) in @lifetime_scope_enum,
      do: :ok,
      else: :error
  end

  # Pas de check `git_ops_denied` (l'ancien g24_5) : les workers PEUVENT
  # push si le cap-profile l'autorise via `allowedTools` claude CLI.
  # L'invariant qui exigeait `"push"` dans `git_ops_denied` serait donc
  # obsolète. Le mécanisme générique catalogue → disallowedTools claude CLI
  # (via `with_resolved_disallowed_tools/1` + baseline `_baseline-git-denied.yaml`)
  # est le successeur : il interdit universellement les patterns destructeurs
  # (`push --force`, `reset --hard`, `--no-verify`, etc.) sans interdire
  # `push` en bloc.

  defp check_modop_incompatible(%CapProfile{spec: spec}) do
    # `modop_set` est une MAP (schéma v2.5 : default/optional/incompatible),
    # pas une liste. Les paires incompatibles sont sous `spec.modop_set.incompatible` ;
    # les modops ACTIFS = `default` ++ `optional`. Ne PAS lire `spec.modop_incompatible`
    # (clé inexistante → toujours []) ni traiter `spec.modop_set` comme une liste,
    # sinon l'invariant ne tire jamais.
    modop_set = Map.get(spec, "modop_set", %{})

    # modop_set canon = MAP (default/optional/incompatible). Un profil legacy/vide peut le porter
    # en LISTE (`[]`) → `Map.get` crasherait (BadMapError). On traite la forme non-map comme « aucune
    # paire incompatible déclarée » → pas de conflit, pas de crash au boundary spawn (le mauvais
    # type est rendu inoffensif, pas rattrapé par un rescue).
    {pairs, active} =
      if is_map(modop_set) do
        {Map.get(modop_set, "incompatible", []),
         MapSet.new(Map.get(modop_set, "default", []) ++ Map.get(modop_set, "optional", []))}
      else
        {[], MapSet.new()}
      end

    conflict? =
      Enum.any?(pairs, fn pair ->
        case pair do
          [a, b] -> MapSet.member?(active, a) and MapSet.member?(active, b)
          _ -> false
        end
      end)

    if conflict?, do: :error, else: :ok
  end

  # Pas de check budget (l'ancien g24_7) : pas d'API = pas de budget. Le
  # timeout de réponse (jadis mal nommé budget.maxDurationSec) est désormais
  # un default codé par lifetime_scope dans
  # `Fleet.Spawner.Pod.monitor_timeout_ms/1` ; un override par cap-profile
  # (e.g. `spec.timeouts.response_sec`) est accepté optionnel mais
  # non-requis.

  defp check_metadata_name(%CapProfile{metadata: meta}) do
    case Map.get(meta, "name") do
      name when is_binary(name) and byte_size(name) > 0 -> :ok
      _ -> :error
    end
  end

  defp check_disallowed_strict(%CapProfile{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []
    if Enum.all?(@disallowed_minimum_strict, &(&1 in disallowed)), do: :ok, else: :error
  end

  defp check_disallowed_prefix(%CapProfile{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []

    prefix_ok =
      Enum.all?(@disallowed_minimum_prefix, fn prefix ->
        Enum.any?(disallowed, &String.starts_with?(&1, prefix))
      end)

    if prefix_ok, do: :ok, else: :error
  end

  # ------------------------------------------------------------
  # G24-10..14 — extensions v2.5
  #
  # Clés/valeurs STRING : le struct est stringifié en profondeur
  # (`to_struct`). Les valeurs comparées sont donc des strings, pas des
  # atomes (`"forever"`, `"one-shot"` avec tiret, `"none"`) — comparer à un
  # atome `:forever` raterait toujours.
  # ------------------------------------------------------------

  # G24-10 : boot_at_start: true ⟹ lifetime_scope: forever.
  # Doublonne l'`allOf` JSON-schema (belt-and-suspenders, atome d'erreur verbeux).
  defp check_boot_at_start_forever(%CapProfile{spec: spec}) do
    if get_in(spec, ["invocation", "boot_at_start"]) == true and
         get_in(spec, ["invocation", "lifetime_scope"]) != "forever" do
      :error
    else
      :ok
    end
  end

  # G24-11 : subagent_template non-vide ⟹ lifetime_scope: one-shot.
  # `subagent_template` (invocation) implique un dispatch one-shot ; distinct
  # de `knowledge.sp_template` (template SP d'un pod permanent monk/archivist)
  # qui n'est PAS contraint ici. nil ou "" = pas de template → pas de contrainte
  # (cohérent `minLength: 1` du schéma).
  defp check_subagent_template_one_shot(%CapProfile{spec: spec}) do
    template = get_in(spec, ["invocation", "subagent_template"])
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    if is_binary(template) and template != "" and scope != "one-shot" do
      :error
    else
      :ok
    end
  end

  # G24-12 : host_native: true ⟹ metadata.containment: none.
  # `containment` vit dans `metadata` (pas `spec`). Pas de clause `system_user` :
  # ce champ n'existe pas au schéma v2.5. Aligné sur l'`allOf` JSON
  # (containment seul).
  defp check_host_native_containment(%CapProfile{spec: spec, metadata: meta}) do
    if get_in(spec, ["invocation", "host_native"]) == true and
         Map.get(meta, "containment") != "none" do
      :error
    else
      :ok
    end
  end

  # G24-14 : pairing monk_registry ⟺ monk_instance (both-or-neither).
  # Part PURE et structurelle (non portée par le JSON-schema, qui déclare
  # les deux indépendamment nullable). L'existence FS du registry + le
  # lookup de l'instance sont I/O ⟹ load-time (`compose/2`), pas ici.
  defp check_monk_registry_pairing(%CapProfile{spec: spec}) do
    registry = get_in(spec, ["knowledge", "monk_registry"])
    instance = get_in(spec, ["knowledge", "monk_instance"])

    case {is_nil(registry), is_nil(instance)} do
      {true, true} -> :ok
      {false, false} -> :ok
      _ -> :error
    end
  end
end

defmodule Mix.Tasks.Lcars.Contracts.Check.Catalogue do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Catalogue checks and a shared reader for provisioning and tool-scope checks.

  The reader scans top-level YAML profiles in both business and system trees.
  It excludes underscore basenames and silently drops undecodable/non-map YAML;
  it does not perform schema validation or collapse catalogue overrides.
  Missing metadata names fall back to filenames; forge_identity defaults to true.

  Checks comparing shell/Terraform defaults inspect source patterns, not a running
  deployment. Some checks are explicitly skipped when the sibling deploy tree
  is absent; a passing result must be read with its coverage note.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc false
  @spec scan_catalogue_roles(String.t()) :: [map()]
  def scan_catalogue_roles(root) do
    [
      "priv/catalogue/cap_profile/cap-profiles/*.yaml",
      "priv/catalogue-system/cap_profile/cap-profiles/*.yaml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} ->
          [
            %{
              name: get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml"),
              kind: Map.get(raw, "kind"),
              forge_identity: get_in(raw, ["metadata", "forge_identity"]) != false,
              role_index: get_in(raw, ["metadata", "role_index"]),
              capabilities: get_in(raw, ["spec", "capabilities"]) || [],
              allowed_tools: get_in(raw, ["spec", "scope", "allowedTools"]) || [],
              modop_default: get_in(raw, ["spec", "modop_set", "default"]) || [],
              modop_incompatible: get_in(raw, ["spec", "modop_set", "incompatible"]) || []
            }
          ]

        _ ->
          []
      end
    end)
  end

  # Require the error tuple's source shape, beyond a mention of :skills_missing.
  @doc false
  @spec check_skills_declared_present(String.t()) :: Support.result()
  def check_skills_declared_present(root) do
    presence_check(root, %{
      id: "skills.declared_present",
      remediation:
        "make filter_skills fail-loud {:error, {:skills_missing, _}} on a missing plain skill",
      file: "lib/fleet/sp_builder.ex",
      pattern: ~r/:skills_missing/,
      confirm: [~r/:skills_missing/, ~r/\{:error, \{:skills_missing,/],
      missing:
        "filter_skills silently filters out missing skills (no executable {:error, {:skills_missing,} fail-loud)",
      note: "filter_skills must fail-loud {:error, {:skills_missing, _}} on a missing plain skill"
    })
  end

  # Compare forge-identity logins in both directions, including ReservedSeats.
  # PROV_ROLES is the floor the workstation installer hands the token minter (LCARS_ROLES).
  @doc false
  @spec check_roles_provisioning_locked(String.t()) :: Support.result()
  def check_roles_provisioning_locked(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    catalogue = scan_catalogue_roles(root)

    # A name declared in the system tree keeps its system_ login even with a business override.
    canon =
      catalogue
      |> Enum.filter(& &1.forge_identity)
      |> Enum.map(&role_login(root, &1.name))
      |> Enum.sort()

    sh_path = Path.join(root, "services/provision-role-tokens.sh")

    tf_path = Path.expand("services/forge-recipe/forge.tf", root)
    constants_path = Path.expand("../deploy/installer-constants.env", root)

    # Absence of deploy skips both Terraform and deploy lists, even though forge.tf is in-tree.
    # A present tree with unreadable anchors fails; the token-minter list is always required.
    lists =
      [
        {"provision-role-tokens.sh ROLES", :required,
         read_list(sh_path, ~r/^ROLES="([^"]*)"/m, :plain),
         "add/remove the role in ROLES=\"…\" (token mint default)"},
        # Compare the named variable defaults, joining business roles with system_roles.
        {"forge.tf var.roles + var.system_roles defaults",
         tree_scope(Path.expand("../deploy", root)),
         merge_lists(
           read_list(tf_path, ~r/variable\s+"roles"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s, :quoted),
           read_list(
             tf_path,
             ~r/variable\s+"system_roles"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s,
             :quoted
           )
         ),
         "add/remove the role in the `roles` variable default (forge account) — the canon is the " <>
           "source: a role only in forge.tf needs its cap-profile or a ReservedSeat, or loses " <>
           "its account"},
        {"installer-constants.env PROV_ROLES", tree_scope(Path.expand("../deploy", root)),
         read_list(constants_path, ~r/^PROV_ROLES=(.*)$/m, :plain),
         "add/remove the role in PROV_ROLES of deploy/installer-constants.env (the floor the " <>
           "workstation installer hands the token minter as LCARS_ROLES; the minter adds the " <>
           "release roster and the installed catalogues' rosters, and the container passes no " <>
           "floor)"}
      ]

    {lists, skipped} = split_out_of_scope(lists)

    {evidence, remediations} =
      Enum.reduce(lists, {[], []}, fn entree, {ev, rem} ->
        {ev2, rem2} = compare_provisioning_list(entree, canon)
        {ev ++ ev2, rem ++ rem2}
      end)

    # Compare placement defaults with Fleet.Roster.tfvars, without reimplementing its rules.
    {placement, placement_note} = check_placement_defaults(root, tf_path)
    evidence = evidence ++ placement

    measured_verdict("roles.provisioning_locked", %{
      remediation:
        if(remediations == [], do: "—", else: Enum.join(Enum.uniq(remediations), " ; ")),
      broken: if(canon == [], do: "canon catalogue empty/not found — fail-closed"),
      findings: evidence,
      note:
        "four-list STRICT equality (BL-6-45)" <>
          placement_note <>
          ": canon{forge_identity} PROJECTED into " <>
          "`<catalogue>_<role>` logins (#{length(canon)} roles, seats included) == forge.tf == " <>
          "ROLES == PROV_ROLES — any delta is a defect, named" <>
          skipped_note(skipped)
    })
  end

  # Require the bundle in each CapabilityProfile's defaults, never incompatible.
  # ReservedSeats are excluded; only file presence is checked for the bundle's prose.
  @adresser_bundle "adresser-un-agent"
  @doc false
  @spec check_sp_adresser_un_agent(String.t()) :: Support.result()
  def check_sp_adresser_un_agent(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    profiles =
      root
      |> scan_catalogue_roles()
      |> Enum.filter(&(&1.kind == "CapabilityProfile"))

    missing =
      profiles
      |> Enum.reject(&(@adresser_bundle in &1.modop_default))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    # Reject both incompatible pairs and malformed flat entries naming the bundle.
    excluded =
      profiles
      |> Enum.filter(fn p ->
        Enum.any?(p.modop_incompatible, fn entry ->
          (is_list(entry) and @adresser_bundle in entry) or entry == @adresser_bundle
        end)
      end)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    bundle =
      Path.join(
        root,
        "priv/catalogue-system/cap_profile/modop-bundles/#{@adresser_bundle}/sp.md"
      )

    cond do
      not File.regular?(bundle) ->
        %{
          id: "sp.adresser_un_agent",
          status: :fail,
          remediation:
            "le bundle #{@adresser_bundle} est nomme par les cartes et sa prose est ABSENTE — " <>
              "les pods recevraient un nom qui ne compose rien",
          evidence: ["source introuvable : #{Path.relative_to(bundle, root)}"],
          note: "la source unique de prose du bundle"
        }

      measured_nothing?(profiles) ->
        broken_result("sp.adresser_un_agent", "CapabilityProfile in the catalogues")

      true ->
        %{
          id: "sp.adresser_un_agent",
          status: if(missing == [] and excluded == [], do: :pass, else: :fail),
          remediation:
            "ajouter `#{@adresser_bundle}` a `spec.modop_set.default` de la carte (jamais " <>
              "`optional` : aucun appelant de production ne l'activerait ; jamais dans un " <>
              "`incompatible:` : ce n'est pas un mode commutable)",
          evidence:
            Enum.map(missing, &"#{&1} : absent de modop_set.default") ++
              Enum.map(excluded, &"#{&1} : nomme dans un incompatible: — retire au role"),
          note:
            "une seule source de prose (le bundle), un nom par carte, ce mur contre le nom " <>
              "manquant (#{length(profiles)} profil(s) mesure(s) ; les ReservedSeat sont hors perimetre)"
        }
    end
  end

  @doc false
  # Shared UUID slots can collide in pod kill patterns. Check integer entries, seats included;
  # missing indices and their allowed range remain schema concerns.
  @spec check_roles_role_index_unique(String.t()) :: Support.result()
  def check_roles_role_index_unique(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    indexed =
      scan_catalogue_roles(root)
      |> Enum.filter(&is_integer(&1.role_index))

    duplicates =
      indexed
      |> Enum.group_by(& &1.role_index, & &1.name)
      |> Enum.filter(fn {_idx, names} -> length(names) > 1 end)

    if measured_nothing?(indexed) do
      broken_result("roles.role_index_unique", "catalogue role carrying a role_index")
    else
      %{
        id: "roles.role_index_unique",
        remediation:
          "two catalogue entries claim the same role_index slot — reassign one (0..15, " <>
            "see each file's metadata comment for the taken slots)",
        status: if(duplicates == [], do: :pass, else: :fail),
        evidence:
          Enum.map(duplicates, fn {idx, names} ->
            "role_index #{idx} claimed by: #{Enum.join(Enum.sort(names), ", ")}"
          end),
        note: "role_index (hexspeak UUID slot) unique across the canon catalogue, seats included"
      }
    end
  end

  # Face zones need privileged creation before runtime onboarding.
  # Check container init and native provisioning mirrors, and the mode and owner the manifest gives
  # the native mirror (25-directories lists paths only); no deploy tree skips the whole check.
  @doc false
  @spec check_face_roots_provisioned(String.t()) :: Support.result()
  def check_face_roots_provisioned(root) do
    case tree_scope(Path.expand("../deploy", root)) do
      :out_of_scope ->
        %{
          id: "layout.face_roots_provisioned",
          remediation: "—",
          status: :pass,
          evidence: [],
          note: "NOT CHECKED here (deploy/ absent from this artifact — runtime-only context)"
        }

      :required ->
        face_roots_measured(root)
    end
  end

  @face_root_mode "2775"
  @face_root_owner "root:fleet"

  defp face_roots_measured(root) do
    entrypoint = Path.expand("services/container/init.sh", root)
    module = Path.expand("../deploy/modules.d/25-directories.sh", root)
    manifest = Path.expand("../deploy/system.manifest", root)

    remediation =
      "add the face root to the `install -d` line of runtime/services/container/init.sh, to the " <>
        "directory list of deploy/modules.d/25-directories.sh, and declare it `dir <root> " <>
        "#{@face_root_mode} #{@face_root_owner}` in deploy/system.manifest — a face declared in " <>
        "Fleet.Layout with no zone on the machine makes the container look healthy and kills the " <>
        "first onboard that needs it (the runtime runs as the human; /home belongs to root)"

    readings = [
      {read_face_roots(Path.expand("lib/fleet/layout.ex", root)), "lib/fleet/layout.ex",
       "face_root/1 unreadable in Fleet.Layout — guard fail-closed, nothing measured"},
      {read_install_zone_paths(entrypoint), Path.relative_to(entrypoint, root),
       "the `install -d -m 2775 -g fleet` anchor is unreadable — guard fail-closed"},
      {read_provision_zone_paths(module), Path.relative_to(module, root),
       "the provision module's directory list is unreadable — guard fail-closed " <>
         "(25-directories is the creator on every substrate; container/init.sh only " <>
         "covers the container volumes)"},
      {read_manifest_dirs(manifest), Path.relative_to(manifest, root),
       "deploy/system.manifest has no readable `dir` row — guard fail-closed (the mode and " <>
         "owner of the native mirror live there)"}
    ]

    case Enum.find(readings, fn {value, _, _} -> is_nil(value) end) do
      {nil, unreadable, note} ->
        %{
          id: "layout.face_roots_provisioned",
          remediation: remediation,
          status: :fail,
          evidence: [unreadable],
          note: note
        }

      nil ->
        [expected, at_boot, on_every_substrate, declared] =
          Enum.map(readings, fn {value, _, _} -> value end)

        missing =
          Enum.map(expected -- at_boot, &"#{&1}: absent de container/init.sh (conteneur)") ++
            Enum.map(
              expected -- on_every_substrate,
              &"#{&1}: absent du module provision (donc absent sur wsl et linux)"
            ) ++ Enum.flat_map(expected, &manifest_mismatch(&1, Map.get(declared, &1)))

        %{
          id: "layout.face_roots_provisioned",
          remediation: remediation,
          status: if(missing == [], do: :pass, else: :fail),
          evidence: missing,
          note:
            "les #{length(expected)} racines de face de Fleet.Layout sont créées par les DEUX " <>
              "miroirs — le module 25-directories (tout substrat) et container/init.sh (les " <>
              "volumes du conteneur, au boot) — et déclarées #{@face_root_mode} " <>
              "#{@face_root_owner} dans deploy/system.manifest : #{Enum.join(expected, ", ")}"
        }
    end
  end

  defp manifest_mismatch(_face_root, {@face_root_mode, @face_root_owner}), do: []

  defp manifest_mismatch(face_root, nil),
    do: ["#{face_root}: aucune ligne dir dans deploy/system.manifest"]

  defp manifest_mismatch(face_root, {mode, owner}),
    do: [
      "#{face_root}: #{mode} #{owner} dans deploy/system.manifest, attendu " <>
        "#{@face_root_mode} #{@face_root_owner}"
    ]

  # A `dir` row (trait included) names a path, its mode and its owner; nil when no row reads.
  defp read_manifest_dirs(path) do
    with {:ok, content} <- File.read(path),
         [_ | _] = rows <- Regex.scan(~r/^dir(?::\S+)?\s+(\/\S+)\s+(\S+)\s+(\S+)/m, content) do
      Map.new(rows, fn [_, dir, mode, owner] -> {dir, {mode, owner}} end)
    else
      _ -> nil
    end
  end

  # Read literal or attribute bodies of the matched single-line face_root clauses.
  # Unknown matched bodies fail; clauses outside the regex shape are invisible.
  defp read_face_roots(layout_path) do
    with {:ok, src} <- File.read(layout_path),
         [_ | _] = clauses <- Regex.scan(~r/^\s*def face_root\("([a-z]+)"\), do: (.+)$/m, src) do
      attrs =
        ~r/^\s*@([a-z_]+)\s+"(\/[^"]+)"$/m
        |> Regex.scan(src)
        |> Map.new(fn [_, name, value] -> {name, value} end)

      roots = Enum.map(clauses, fn [_, _face, body] -> resolve_face_root(body, attrs) end)
      if Enum.any?(roots, &is_nil/1), do: nil, else: Enum.sort(roots)
    else
      _ -> nil
    end
  end

  defp resolve_face_root(body, attrs) do
    case String.trim(body) do
      "@" <> attr -> Map.get(attrs, attr)
      ~s(") <> _ = literal -> literal |> String.trim(~s(")) |> nonempty_abs_path()
      _ -> nil
    end
  end

  defp nonempty_abs_path("/" <> _ = p), do: p
  defp nonempty_abs_path(_), do: nil

  # The anchor requires mode 2775 and group fleet; only absolute tail tokens count as paths.
  defp read_install_zone_paths(path) do
    with {:ok, content} <- File.read(path),
         [_, tail] <- Regex.run(~r/^\s*install\s+-d\s+-m\s+2775\s+-g\s+fleet\s+(.+)$/m, content) do
      tail |> String.split() |> Enum.filter(&String.starts_with?(&1, "/"))
    else
      _ -> nil
    end
  end

  # Container init needs zones before provisioning runs; native provisioning carries its own list.
  # The module lists the directories it poses in the body of `prov_dirs()`, modes live in
  # deploy/system.manifest. A row names its system path through `$(prov_decor <path>)`; the
  # canonical path is its argument.
  defp read_provision_zone_paths(path) do
    with {:ok, content} <- File.read(path),
         [_, body] <- Regex.run(~r/^prov_dirs\(\) \{\n(.*?)^\}/ms, content),
         [_ | _] = rows <-
           Regex.scan(~r/^\s*"\$\(prov_decor\s+'?"?(\/[^"'\s)]+)'?"?\)/m, body) do
      rows |> Enum.map(fn [_, p] -> p end) |> Enum.sort()
    else
      _ -> nil
    end
  end

  # nil means unreadable file/anchor, distinct from a readable empty list.
  defp read_list(path, regex, format) do
    with {:ok, content} <- File.read(path),
         [_, inner] <- Regex.run(regex, content) do
      split_list(inner, format)
    else
      _ -> nil
    end
  end

  defp split_list(inner, :plain), do: inner |> String.split() |> Enum.sort()

  defp split_list(inner, :quoted),
    do: ~r/"([^"]+)"/ |> Regex.scan(inner) |> Enum.map(fn [_, s] -> s end) |> Enum.sort()

  defp compare_provisioning_list({label, nil, remediation}, _canon),
    do: {["#{label}: list not readable — fail-closed (partial checkout?)"], [remediation]}

  defp compare_provisioning_list({label, list, remediation}, canon) do
    missing = canon -- list
    extra = list -- canon

    ev =
      if(missing != [], do: ["#{label}: MISSING #{inspect(missing)}"], else: []) ++
        if(extra != [], do: ["#{label}: EXTRA #{inspect(extra)}"], else: [])

    {ev, if(ev == [], do: [], else: [remediation])}
  end

  defp placement_gap(key, tf_path, derived) do
    rx = ~r/variable\s+"#{key}"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s
    hard = read_list(tf_path, rx, :quoted)
    want = Enum.sort(Map.get(derived, key, []))

    cond do
      hard == nil ->
        ["forge.tf var.#{key} default: not readable — fail-closed"]

      Enum.sort(hard) == want ->
        []

      true ->
        ["forge.tf var.#{key} default #{inspect(Enum.sort(hard))} != derivation #{inspect(want)}"]
    end
  end

  defp merge_lists(nil, _), do: nil
  defp merge_lists(_, nil), do: nil
  defp merge_lists(a, b), do: Enum.sort(a ++ b)

  @placement_checked " + the THREE placement defaults against the derivation"

  defp check_placement_defaults(root, tf_path) do
    catalogue = Path.join(root, "priv/catalogue")

    # Runtime-only build artifacts can omit deploy; scope is checked at tree level.
    if File.dir?(Path.expand("../deploy", root)) and File.dir?(catalogue) do
      case Fleet.Roster.tfvars(catalogue) do
        {:ok, derived} ->
          ev = Enum.flat_map(~w(writers judges externals), &placement_gap(&1, tf_path, derived))

          {ev, @placement_checked}

        {:error, reason} ->
          {["placement derivation unreadable (#{inspect(reason)}) — fail-closed"],
           @placement_checked}
      end
    else
      {[], " (placement defaults SKIPPED: no `deploy` tree)"}
    end
  end

  defp role_login(root, role) do
    prefix =
      if MapSet.member?(system_role_names(root), role), do: "system", else: bundled_name(root)

    "#{prefix}_#{role}"
  end

  defp system_role_names(root) do
    root
    |> Path.join("priv/catalogue-system/cap_profile/cap-profiles/*.yaml")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} -> [get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml")]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp bundled_name(root) do
    case YamlElixir.read_from_file(Path.join(root, "priv/catalogue/catalogue.yaml")) do
      {:ok, %{"name" => n}} when is_binary(n) -> n
      _ -> "fleet"
    end
  end

  # Compare Layout literals with CLI shell defaults and the installer constant, excluding env
  # overrides. No deploy tree skips its mirror; a present tree with a missing anchor fails.
  @doc false
  @spec check_catalogue_paths_locked(String.t()) :: Support.result()
  def check_catalogue_paths_locked(root) do
    layout = "lib/fleet/layout.ex"
    cli = "bin/lcars"
    constants = "../deploy/installer-constants.env"
    layout_src = read_or_empty(root, layout)
    cli_src = read_or_empty(root, cli)
    constants_src = read_or_empty(root, constants)

    # Read declared path literals so this comparison does not depend on loaded runtime values.
    attrs =
      Map.new(
        ~w(platform_root catalogues_dirname installed_catalogues_root),
        &{&1, module_attribute(layout_src, &1)}
      )

    expected =
      if Enum.any?(attrs, fn {_k, v} -> is_nil(v) end) do
        nil
      else
        %{
          "LCARS_CATALOGUES_DIR" => attrs["installed_catalogues_root"],
          "LCARS_CATALOGUES_SHIPPED" => "#{attrs["platform_root"]}/#{attrs["catalogues_dirname"]}"
        }
      end

    deploy? = File.dir?(Path.expand("../deploy", root))

    sources =
      [{cli, &shell_default(cli_src, &1), expected || %{}}] ++
        if deploy?,
          do: [{constants, &installer_constant(constants_src, &1), constants_expected(expected)}],
          else: []

    mismatches =
      for {file, read, wanted} <- sources,
          {var, want} <- wanted,
          got = read.(var),
          got != want,
          do: "#{var}: #{file} says #{inspect(got)}, #{layout} says #{inspect(want)}"

    missing =
      for {file, read, wanted} <- sources,
          {var, _} <- wanted,
          is_nil(read.(var)),
          do: "#{var} (#{file})"

    measured_verdict("catalogue.install_paths_locked", %{
      remediation:
        "make bin/lcars and deploy/installer-constants.env agree with Fleet.Layout (@platform_root, " <>
          "@catalogues_dirname, @installed_catalogues_root) — provisioning that converges a " <>
          "directory the runtime does not read reports every catalogue installed and serves none",
      broken:
        if(is_nil(expected),
          do: "#{layout}: a catalogue path attribute is gone or renamed"
        ),
      findings:
        if(missing == [],
          do: Enum.sort(mismatches),
          else: [
            "no declaration for #{inspect(Enum.sort(missing))} — that half stopped carrying " <>
              "the path"
          ]
        ),
      note:
        "3 catalogue paths, one fact each, agreed between #{layout} and #{cli}" <>
          if(deploy?,
            do: " and #{constants}",
            else:
              " · #{constants} NOT CHECKED here (tree absent from this artifact — runtime-only context)"
          )
    })
  end

  # Provisioning writes the installed cache, not the image's seed catalogue.
  defp constants_expected(nil), do: %{}
  defp constants_expected(exp), do: %{"PROV_CATALOGUES_DIR" => exp["LCARS_CATALOGUES_DIR"]}

  defp read_or_empty(root, rel) do
    path = Path.join(root, rel)
    if File.regular?(path), do: File.read!(path), else: ""
  end

  defp module_attribute(source, name) do
    case Regex.run(~r/^\s*@#{name}\s+"([^"]*)"/m, source) do
      [_, value] -> value
      nil -> nil
    end
  end

  # Shell assignment (:=) and fallback (:-) carry the same default value.
  defp shell_default(source, var) do
    case Regex.run(~r/\$\{#{var}:[-=]([^}]*)\}/, source) do
      [_, default] -> default
      nil -> nil
    end
  end

  # La lib lit ce fichier comme une donnée : la valeur se compare telle qu'écrite, sans expansion.
  defp installer_constant(source, var) do
    case Regex.run(~r/^#{var}=(.*)$/m, source) do
      [_, value] -> value
      nil -> nil
    end
  end
end

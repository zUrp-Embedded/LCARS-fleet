defmodule Mix.Tasks.Lcars.Contracts.Check.SingleSource do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Checks selected cross-language copies of branch names, paths and identities,
  plus Elixir config defaults and forge payload access forms.

  Mirror lists are explicit and must grow when another reader is added. Scope
  is determined per mirror tree; skipped trees are named in result notes.
  These are source-shape checks, not proof of provisioning or runtime agreement
  under environment overrides. Corpus scans have their own path and text filters.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc """
  Compares four named shell/Python mirrors with Fleet.Toolchain.branch/0.

  The executor and converger must agree on the branch whose head they request
  and accept. This check does not verify signatures, branch protection or head
  validation. It requires a double-quoted literal in each raw source and rejects
  selected BRANCH environment forms plus LCARS_SYSADMIN_BRANCH.

  Only listed mirrors are checked, including their comments. Other expansion
  forms or variable names can escape the patterns.
  """
  @spec check_toolchain_branch_single_source(String.t()) :: Support.result()
  def check_toolchain_branch_single_source(root) do
    mirrors = [
      # ⚠ `services/forge.d/ops-repo.sh` N'EST PLUS UN MIROIR, et c'est un progres, pas un oubli :
      # depuis la phase 7 il n'ecrit plus ce nom, il DEMANDE la mesure au release, qui lit
      # `Fleet.Toolchain.branch/0`. Une ecriture de moins ne se remplace pas par une ligne ici.
      # The recipe lays the branch and its protection; the gesture only verifies.
      "services/forge-recipe/ops.tf",
      "services/admiral/skills/system-issues/list.sh",
      # The converger's accepted branch and the executor's requested branch must agree.
      "bin/lcars-toolchain-converge",
      "services/privileged-executor.py"
    ]

    # Scope each mirror separately; an absent deploy tree must not skip in-tree services.
    {checked, skipped} =
      Enum.split_with(mirrors, fn rel ->
        mirror_scope(rel, root) == :required
      end)

    id = "toolchain.branch_single_source"

    remediation =
      "copy the literal from `Fleet.Toolchain.branch/0` into the copy, and never reintroduce " <>
        "`LCARS_SYSADMIN_BRANCH` — a name half of the rail can retune is a rail that splits in " <>
        "silence"

    expected =
      source_literal(root, "lib/fleet/toolchain.ex", ~r/def\s+branch,\s*do:\s*"([^"]+)"\s*$/m)

    cond do
      checked == [] ->
        out_of_scope(id, "no mirror tree present", skipped)

      is_nil(expected) ->
        unreadable_authority(
          id,
          remediation,
          "lib/fleet/toolchain.ex",
          "Fleet.Toolchain.branch/0"
        )

      true ->
        branch_verdict(id, remediation, expected, checked, skipped, root)
    end
  end

  defp branch_verdict(id, remediation, expected, checked, skipped, root) do
    bad = Enum.flat_map(checked, &branch_freeze_gap(&1, root, expected))

    if bad == [] do
      %{
        id: id,
        remediation: "—",
        status: :pass,
        evidence: checked,
        note:
          "#{inspect(expected)} declared by Fleet.Toolchain.branch/0 and copied by the " <>
            "#{length(checked)} readers that carry it; no tunable left" <> skipped_note(skipped)
      }
    else
      %{
        id: id,
        remediation: remediation,
        status: :fail,
        evidence: Enum.map(bad, &elem(&1, 0)),
        note:
          "authority says #{inspect(expected)} — " <>
            Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <> skipped_note(skipped)
      }
    end
  end

  # Forbidden mirrors check absence, ordinary mirrors check presence.
  defp mirror_or_absence_gap({rel, rx, what, :forbidden}, root) do
    case File.read(Path.expand(rel, root)) do
      {:ok, body} -> if Regex.match?(rx, code_of(body)), do: [{rel, what}], else: []
      _ -> [{rel, "unreadable"}]
    end
  end

  defp mirror_or_absence_gap({rel, rx, what}, root), do: mirror_gap({rel, rx, what}, root)

  # Skip NUL-bearing files, strip hash tails and trim trailing dots/hyphens from matched roots.
  defp collect_face_roots(path, acc) do
    case File.read(path) do
      {:ok, body} ->
        if String.contains?(body, <<0>>) do
          acc
        else
          body
          |> String.split("\n")
          |> Enum.map(&Regex.replace(~r/#.*/, &1, ""))
          |> Enum.flat_map(&Regex.scan(~r|/home/projects[A-Za-z0-9_.-]*|, &1))
          |> Enum.map(&hd/1)
          |> Enum.map(&Regex.replace(~r/[.\-]+$/, &1, ""))
          |> MapSet.new()
          |> MapSet.union(acc)
        end

      _ ->
        acc
    end
  end

  defp branch_freeze_gap(rel, root, expected) do
    case File.read(Path.expand(rel, root)) do
      {:ok, body} -> branch_freeze_verdict(rel, body, expected)
      _ -> [{rel, "unreadable"}]
    end
  end

  defp branch_freeze_verdict(rel, body, expected) do
    cond do
      Regex.match?(~r/\$\{[A-Za-z_]*BRANCH[A-Za-z_]*[\}:]/, body) ->
        [{rel, "derives the branch from an expansion — the name is frozen, not tunable"}]

      Regex.match?(
        ~r/os\.(?:environ\.get|getenv)\(\s*["\'][^"\']*BRANCH|os\.environ\[\s*["\'][^"\']*BRANCH/,
        body
      ) ->
        [{rel, "reads the branch from the environment — the name is frozen, not tunable"}]

      String.contains?(body, "LCARS_SYSADMIN_BRANCH") ->
        [{rel, "carries LCARS_SYSADMIN_BRANCH — the name is frozen, not tunable"}]

      not String.contains?(body, "\"#{expected}\"") ->
        [{rel, "does not carry the literal #{inspect(expected)}"}]

      true ->
        []
    end
  end

  defp mirror_gap({rel, rx, what}, root) do
    case File.read(Path.expand(rel, root)) do
      {:ok, body} -> if Regex.match?(rx, code_of(body)), do: [], else: [{rel, what}]
      _ -> [{rel, "unreadable"}]
    end
  end

  @doc """
  Compares Layout's shipped and installed catalogue roots with six named source
  patterns in CLI, forge gestures, manifest and installer constants.

  Shipped seeds and the installed cache serve different purposes; both creators
  and readers must agree. Scope is decided per mirror. This checks expected source
  forms, not image contents, actual directory creation or environment overrides.
  """
  @spec check_catalogue_roots_single_source(String.t()) :: Support.result()
  def check_catalogue_roots_single_source(root) do
    id = "layout.catalogue_roots_single_source"

    remediation =
      "copy the value from `Fleet.Layout.catalogues_shipped_dir/0` / `catalogues_installed_dir/0` " <>
        "into the shell copy — the BEAM and the shell cannot call each other, so the agreement is " <>
        "what makes the single source true"

    src =
      case File.read(Path.expand("lib/fleet/layout.ex", root)) do
        {:ok, s} -> s
        _ -> nil
      end

    attr = fn name ->
      with true <- is_binary(src),
           # Anchor the literal at line end so concatenation cannot be mistaken for a complete value.
           [_, v] <- Regex.run(~r/@#{name}\s+"([^"]+)"\s*$/m, src) do
        v
      else
        _ -> nil
      end
    end

    platform = attr.("platform_root")
    dirname = attr.("catalogues_dirname")
    installed = attr.("installed_catalogues_root")

    if is_nil(platform) or is_nil(dirname) or is_nil(installed) do
      %{
        id: id,
        remediation: remediation,
        status: :fail,
        evidence: ["lib/fleet/layout.ex"],
        note:
          "Fleet.Layout no longer reads as three frozen literals (@platform_root, " <>
            "@catalogues_dirname, @installed_catalogues_root) — nothing was compared"
      }
    else
      shipped = Path.join(platform, dirname)

      # ⚖ Decision 3: the shell has ONE declaration of these two roots, `etc/facts.env`, and every
      # script reads it (`services/lib/facts.sh`). The mirrors that used to sit in `bin/lcars` and
      # `forge-gestures.sh` are gone — checking them here would pin a literal that no longer exists.
      mirrors = [
        {"etc/facts.env", ~r/^LCARS_CATALOGUES_SHIPPED=#{Regex.escape(shipped)}$/m,
         "the machine fact the shell and the Python read (shipped)"},
        {"etc/facts.env", ~r/^LCARS_CATALOGUES_DIR=#{Regex.escape(installed)}$/m,
         "the machine fact the shell and the Python read (installed)"},
        # A DERIVATION of the fact, not a copy of it: the gesture names the sub-tree, never the root.
        {"services/forge-gestures.sh", ~r/\$\{LCARS_DEMO_CATALOGUE:-\$LCARS_CATALOGUES_SHIPPED\//,
         "the demo catalogue the forge gesture publishes"},
        # Le createur de l'arbre livre est unique depuis le 2026-09-11 : `62-runtime-helpers`
        # embarque `catalogues/` du kit sous la racine, sur un poste comme dans l'image. Le `COPY`
        # de l'image d'avant etait un jumeau ; il n'y a plus de second createur a tenir d'accord.
        {"../deploy/system.manifest", ~r/^dir\s+#{Regex.escape(installed)}\s/m,
         "the manifest row that creates the installed tree"},
        {"../deploy/installer-constants.env",
         ~r/^PROV_CATALOGUES_DIR=#{Regex.escape(installed)}$/m, "the installer constant"}
      ]

      {checked, skipped} =
        Enum.split_with(mirrors, fn {rel, _rx, _what} ->
          mirror_scope(rel, root) == :required
        end)

      bad = Enum.flat_map(checked, &mirror_gap(&1, root))

      skipped_labels = skipped |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      if bad == [] do
        %{
          id: id,
          remediation: "—",
          status: :pass,
          evidence: checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          note:
            "shipped=#{inspect(shipped)} installed=#{inspect(installed)} declared by Fleet.Layout " <>
              "and carried by the #{length(checked)} checked copies" <>
              skipped_note(skipped_labels)
        }
      else
        %{
          id: id,
          remediation: remediation,
          status: :fail,
          evidence: Enum.map(bad, &elem(&1, 0)),
          note:
            "authority says shipped=#{inspect(shipped)} installed=#{inspect(installed)} — " <>
              Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
              skipped_note(skipped_labels)
        }
      end
    end
  end

  @doc """
  Compares secrets-directory declarations without designating an authority.
  The manifest confirms the agreed path through a dir row when deploy is present;
  it does not define the directory's semantic name.

  Three holders are listed, each read as a literal. Missing/unreadable files are dropped
  from the comparison, while readable files lacking their anchor fail. Fewer than
  two readable declarations and no broken anchors returns an explicit skip.

  Agreement and a manifest row do not prove directory creation, ownership or mode.
  """
  @spec check_private_dir_single_source(String.t()) :: Support.result()
  def check_private_dir_single_source(root) do
    {values, broken, skipped} = private_dir_declarations(root)
    private_dir_verdict(root, values, broken, skipped)
  end

  @private_dir_remediation "make every declaration of the secrets directory name the same path, " <>
                             "and the manifest create exactly that path — no authority is " <>
                             "designated, so agreement IS the invariant"

  # Match declared defaults; container paths derive from the module-protocol default.
  defp private_dir_holders do
    [
      {"lib/fleet/credentials/role_token.ex", ~r/@default_dir\s+"([^"]+)"\s*$/m,
       "the BEAM's role-token directory"},
      {"../deploy/installer-constants.env", ~r/^PROV_TOKENS_DIR=(.+)$/m,
       "the installer constant"},
      # ⚖ Decision 3: the shell declares it ONCE, as a machine fact. `services/lib/facts.sh` is the
      # only reader; the module protocol sources it and no longer writes a default of its own.
      {"etc/facts.env", ~r/^LCARS_PRIVATE_DIR=(.+)$/m, "the machine fact the product reads"}
    ]
  end

  defp private_dir_declarations(root) do
    {in_scope, out} =
      Enum.split_with(private_dir_holders(), fn {rel, _, _} ->
        mirror_scope(rel, root) == :required
      end)

    results = Enum.map(in_scope, &read_private_dir_holder(&1, root))

    {for({:ok, rel, what, v} <- results, do: {rel, what, v}),
     for({:unreadable, rel, what} <- results, do: {rel, "#{what}: declaration not readable"}),
     out |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}
  end

  defp read_private_dir_holder({rel, rx, what}, root) do
    with {:ok, body} <- File.read(Path.expand(rel, root)),
         [_, v] <- Regex.run(rx, code_of(body)) do
      {:ok, rel, what, v}
    else
      {:error, _} -> {:absent, rel, what}
      _ -> {:unreadable, rel, what}
    end
  end

  defp private_dir_verdict(_root, values, broken, skipped)
       when length(values) < 2 and broken == [],
       do:
         out_of_scope(
           "layout.private_dir_single_source",
           "fewer than two declarations present",
           skipped
         )

  defp private_dir_verdict(_root, _values, [_ | _] = broken, skipped) do
    %{
      id: "layout.private_dir_single_source",
      remediation: @private_dir_remediation,
      status: :fail,
      evidence: Enum.map(broken, &elem(&1, 0)),
      note:
        "a declaration no longer reads as a frozen literal — " <>
          Enum.map_join(broken, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
          skipped_note(skipped)
    }
  end

  defp private_dir_verdict(root, values, _broken, skipped) do
    distinct = values |> Enum.map(fn {_, _, v} -> v end) |> Enum.uniq()
    [expected | _] = distinct

    if length(distinct) > 1 do
      %{
        id: "layout.private_dir_single_source",
        remediation: @private_dir_remediation,
        status: :fail,
        evidence: Enum.map(values, fn {rel, _, _} -> rel end),
        note:
          "#{length(distinct)} different paths declared for one directory — " <>
            Enum.map_join(values, " · ", fn {f, what, v} -> "#{f} (#{what}): #{v}" end) <>
            skipped_note(skipped)
      }
    else
      manifest_verdict(root, values, expected, skipped)
    end
  end

  # The manifest must name the agreed directory when its tree is present.
  defp manifest_verdict(root, values, expected, skipped) do
    rel = "../deploy/system.manifest"
    scoped? = tree_scope(Path.expand("../deploy", root)) == :required

    ok? =
      not scoped? or
        (match?({:ok, m} when is_binary(m), File.read(Path.expand(rel, root))) and
           Regex.match?(
             ~r/^dir\s+#{Regex.escape(expected)}\s/m,
             File.read!(Path.expand(rel, root))
           ))

    if ok? do
      %{
        id: "layout.private_dir_single_source",
        remediation: "—",
        status: :pass,
        evidence: values |> Enum.map(fn {rel, _, _} -> rel end) |> Enum.uniq(),
        note:
          "#{length(values)} declaration(s) agree on #{inspect(expected)}" <>
            if(scoped?, do: ", and the manifest creates it", else: "") <> skipped_note(skipped)
      }
    else
      %{
        id: "layout.private_dir_single_source",
        remediation: @private_dir_remediation,
        status: :fail,
        evidence: [rel],
        note:
          "every declaration says #{inspect(expected)} but the manifest creates no such " <>
            "directory — the container would come up without it" <> skipped_note(skipped)
      }
    end
  end

  @doc """
  Checks named copies of ForgeIdentity's @system_name, the designated authority
  for the system forge identity and its derived email/signature.

  The Terraform recipe must receive system_account from roles.auto.tfvars.json,
  so its mirror rejects a default rather than requiring a literal copy. That
  negative pattern does not require the variable declaration itself to exist.
  Other mirrors compare source defaults; this does not verify the deployed account,
  permissions or the value actually passed to Terraform.
  """
  @spec check_system_account_single_source(String.t()) :: Support.result()
  def check_system_account_single_source(root) do
    id = "forge.system_account_single_source"

    remediation =
      "copy the literal from `Fleet.Credentials.ForgeIdentity` `@system_name` — it is the " <>
        "designated authority (user, 2026-08-27): the account's email, its signature and the " <>
        "commit-identity gate all derive from it"

    expected =
      case File.read(Path.expand("lib/fleet/credentials/forge_identity.ex", root)) do
        {:ok, src} ->
          case Regex.run(~r/@system_name\s+"([^"]+)"\s*$/m, src) do
            [_, name] -> name
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(expected) do
      unreadable_authority(
        id,
        remediation,
        "lib/fleet/credentials/forge_identity.ex",
        "@system_name"
      )
    else
      e = Regex.escape(expected)

      # Match each expected source form through code_of; this is not a cross-language parser.
      mirrors = [
        # Terraform receives the identity; a default would introduce an independent declaration.
        {"services/forge-recipe/forge.tf",
         ~r/variable\s+"system_account"\s*\{(?:(?!\}).)*?default\s*=/s,
         "carries a `default =` again — the name must arrive from roles.auto.tfvars.json, not from the recipe",
         :forbidden},
        # The INSTANCE module is a root module: nobody passes it the account, so it keeps a default
        # — and that default is a second literal the `forge.tf` rule above never looked at. Held as
        # a MIRROR rather than forbidden: it must EQUAL the authority, and say so when it stops.
        {"services/forge-recipe/instance/accounts.tf",
         ~r/variable\s+"system_account"\s*\{(?:(?!\}).)*?default\s*=\s*"#{e}"/s,
         "the instance module's default"},
        {"../deploy/installer-constants.env", ~r/^PROV_SYSTEM_ACCOUNT=#{e}$/m,
         "the installer constant"},
        {"services/forge-recipe/provision-forge-charte.sh", ~r/"#{e}:[A-Za-z0-9_.-]+"/,
         "the avatar map key"},
        # ⚖ Decision 3: SIX shell fallbacks used to be listed here — the converger, the forge
        # gesture, the token minter, the admiral skill, the CLI and the publish rewrite. They read
        # the machine fact now, so there is ONE declaration to hold instead of six to keep equal.
        {"etc/facts.env", ~r/^LCARS_SYSTEM_ACCOUNT=#{e}$/m,
         "the machine fact the shell, the Python and the Elixir read"}
      ]

      {checked, skipped} =
        Enum.split_with(mirrors, fn m ->
          rel = elem(m, 0)
          mirror_scope(rel, root) == :required
        end)

      bad =
        Enum.flat_map(checked, &mirror_or_absence_gap(&1, root))

      skipped_labels = skipped |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      cond do
        checked == [] ->
          out_of_scope(id, "no copy present", skipped_labels)

        bad == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
            note:
              "#{inspect(expected)} declared by ForgeIdentity @system_name; #{length(checked)} " <>
                "sites checked (the recipe RECEIVES it; only the instance root module " <>
                "defaults it, and that default is compared here)" <>
                skipped_note(skipped_labels)
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: Enum.map(bad, &elem(&1, 0)),
            note:
              "authority says #{inspect(expected)} — " <>
                Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
                skipped_note(skipped_labels)
          }
      end
    end
  end

  defp scan_corpus_roots(root, motif, tronque \\ nil) do
    Enum.reduce(corpus_files(root), {MapSet.new(), 0}, fn path, acc ->
      corpus_root_step(File.read(path), acc, motif, tronque)
    end)
  end

  # Count only files with matched roots; unreadable files contribute nothing.
  defp corpus_root_step({:ok, body}, {acc, n}, motif, tronque) do
    vus =
      body
      |> String.split("\n")
      |> Enum.map(&Regex.replace(~r/#.*/, &1, ""))
      |> Enum.flat_map(&Regex.scan(motif, &1))
      |> Enum.map(&hd/1)
      |> then(fn l -> if tronque, do: Enum.map(l, tronque), else: l end)
      |> MapSet.new()

    {MapSet.union(acc, vus), if(MapSet.size(vus) > 0, do: n + 1, else: n)}
  end

  defp corpus_root_step(_unreadable, acc, _motif, _tronque), do: acc

  # Callers anchor literals at line end to reject composed values rather than truncate them.
  defp source_literal(root, rel, motif) do
    with {:ok, src} <- File.read(Path.expand(rel, root)),
         [_, v] <- Regex.run(motif, src) do
      v
    else
      _ -> nil
    end
  end

  defp layout_source(root) do
    case File.read(Path.expand("lib/fleet/layout.ex", root)) do
      {:ok, src} -> src
      _ -> nil
    end
  end

  defp layout_literal(root, attr) do
    with src when is_binary(src) <- layout_source(root),
         [_, v] <- Regex.run(~r/@#{attr}\s+"([^"]+)"\s*$/m, src) do
      v
    else
      _ -> nil
    end
  end

  # Only attribute-bodied face_root spellings are recognised; unreadable attributes yield nil.
  defp declared_faces(root) do
    case layout_source(root) do
      nil ->
        []

      src ->
        ~r/def face_root\("([a-z]+)"\), do: @([a-z_]+)/
        |> Regex.scan(src)
        |> Enum.map(fn [_, face, attr] -> {face, layout_literal(root, attr)} end)
    end
  end

  defp roots_verdict(id, remediation, opts) do
    cond do
      not opts.autorite_vue? ->
        broken_result(id, opts.attendue)

      opts.intruses == [] ->
        %{id: id, remediation: "—", status: :pass, evidence: [], note: opts.note_ok}

      true ->
        %{
          id: id,
          remediation: remediation,
          status: :fail,
          evidence: opts.intruses,
          note: opts.note_ko
        }
    end
  end

  @doc """
  Scans runtime corpus paths under /opt for roots outside Layout's platform_root
  and the explicit foreign-root exemptions. Version-shaped tool roots are also
  excluded. This avoids maintaining a list of every path-bearing file.

  The scan strips hash tails textually and truncates roots; it does not evaluate
  path expressions. The authority itself can satisfy the occurrence guard, so a
  pass does not prove that another file uses it. Unknown roots outside the recognised
  shape are outside coverage.
  """
  @spec check_platform_root_single_source(String.t()) :: Support.result()
  def check_platform_root_single_source(root) do
    id = "layout.platform_root_single_source"

    remediation =
      "every `/opt/...` path of LCARS derives from `Fleet.Layout` `@platform_root` — a second " <>
        "root means half the container installs somewhere the other half never looks"

    etrangeres = [
      "/opt/claude_launch",
      "/opt/homebrew",
      "/opt/bin",
      "/opt/skills",
      "/opt/my",
      "/opt/token-saver",
      # Exact fixture exemptions test common-prefix confusion; do not broaden them to a prefix.
      "/opt/decor",
      "/opt/decor-autre"
    ]

    expected = layout_literal(root, "platform_root")

    if is_nil(expected) do
      unreadable_authority(id, remediation, "lib/fleet/layout.ex", "@platform_root")
    else
      # Versioned or expansion-truncated tool roots are exempted by shape after truncation.
      versionnee = ~r{^/opt/\.?[a-z]+-([0-9]|$)}
      pas_une_racine = ~r|^/opt/\.?[a-z0-9][a-z0-9_-]*$|

      # Corpus pruning must use relative paths; checkout ancestors named tmp/deps are irrelevant.
      {racines, fichiers} =
        scan_corpus_roots(
          root,
          ~r|/opt/\.?[A-Za-z0-9_.-]+|,
          &Regex.replace(~r|(/opt/\.?[A-Za-z0-9_-]+).*|, &1, "\\1")
        )

      inconnues =
        racines
        |> Enum.reject(fn r ->
          r == expected or r in etrangeres or Regex.match?(versionnee, r) or
            not Regex.match?(pas_une_racine, r)
        end)
        |> Enum.sort()

      roots_verdict(id, remediation, %{
        autorite_vue?: MapSet.member?(racines, expected),
        attendue: "occurrence of #{expected} in the corpus",
        intruses: inconnues,
        note_ok:
          "#{inspect(expected)} declared by Fleet.Layout @platform_root is the ONLY LCARS root " <>
            "under /opt (#{fichiers} files carry a /opt path; #{length(etrangeres)} foreign " <>
            "roots declared, versioned toolchains excluded by shape)",
        note_ko:
          "authority says #{inspect(expected)} — #{length(inconnues)} other root(s) under " <>
            "/opt are neither the authority nor declared foreign: " <> Enum.join(inconnues, ", ")
      })
    end
  end

  @doc """
  Checks recognised /run paths containing lcars against Layout's runtime_root.
  Accepted boundaries after the root are end, slash, hyphen and dot, covering
  socket trees and flat boot markers.

  The corpus scan stops at the next slash and does not inspect unrelated /run
  names or dynamically assembled paths. It neither resolves paths nor proves
  that sockets and directories are created at the intended locations.
  """
  @spec check_runtime_root_single_source(String.t()) :: Support.result()
  def check_runtime_root_single_source(root) do
    id = "layout.runtime_root_single_source"

    remediation =
      "every `/run` path of LCARS starts with `Fleet.Layout` `@runtime_root` — a second runtime " <>
        "root means a socket written where nobody listens, on a tmpfs that forgets between boots"

    expected = layout_literal(root, "runtime_root")

    if is_nil(expected) do
      unreadable_authority(id, remediation, "lib/fleet/layout.ex", "@runtime_root")
    else
      {vus, porteurs} =
        scan_corpus_roots(root, ~r|/run/[A-Za-z0-9_.-]*lcars[A-Za-z0-9_.-]*|)

      # Require a boundary after the prefix so a neighbouring name is not accepted as the same root.
      sous_la_racine? = fn v ->
        String.starts_with?(v, expected) and
          (byte_size(v) == byte_size(expected) or
             String.at(v, byte_size(expected)) in ["/", "-", "."])
      end

      orphelins = vus |> Enum.reject(sous_la_racine?) |> Enum.sort()

      roots_verdict(id, remediation, %{
        autorite_vue?: Enum.any?(vus, sous_la_racine?),
        attendue: "occurrence of #{expected} in the corpus",
        intruses: orphelins,
        note_ok:
          "every LCARS path under /run starts with #{inspect(expected)}, declared by " <>
            "Fleet.Layout @runtime_root (#{MapSet.size(vus)} distinct ROOTS — the scan stops " <>
            "at the first `/`, so `/run/lcars/authority/roles.sock` counts as `/run/lcars` — " <>
            "across #{porteurs} files)",
        note_ko:
          "authority says #{inspect(expected)} — #{length(orphelins)} LCARS path(s) under " <>
            "/run do not start with it: " <> Enum.join(orphelins, ", ")
      })
    end
  end

  @doc """
  Checks every per-human state directory in the corpus against Layout's `@state_dirname`.

  ⚖ Phase 5. `/run/lcars` — the MACHINE's socket root — has been held since the runtime_root check;
  its twin, the HUMAN's state directory, was held by nothing while the shell wrote it twenty-four
  times (`$HOME/.lcars/run/tmux-sock`, `~/.lcars/fleet.env`, `$HOME/.lcars/forge.d`…). A second
  name here means a launcher that writes a socket where the CLI does not look and the BEAM does
  not listen — for one human, on one machine, and only once the fleet is started another way.

  The scan reads `$HOME/<name>` and `~/<name>` and stops at the next slash, so
  `$HOME/.lcars/run/api.sock` counts as `.lcars`. It does not resolve paths, does not inspect
  dynamically assembled ones, and proves nothing about what a running machine creates.
  """
  @spec check_state_dir_single_source(String.t()) :: Support.result()
  def check_state_dir_single_source(root) do
    id = "layout.state_dir_single_source"

    remediation =
      "every per-human state path starts with `Fleet.Layout` `@state_dirname` — a second name is " <>
        "a socket written where nobody listens, and the two sides only meet on a machine"

    expected = layout_literal(root, "state_dirname")

    if is_nil(expected) do
      unreadable_authority(id, remediation, "lib/fleet/layout.ex", "@state_dirname")
    else
      # `$HOME/x` et `~/x` : les deux formes du meme chemin, tronquees au premier `/` suivant.
      {vus, porteurs} =
        scan_corpus_roots(
          root,
          ~r{(?:\$HOME/|~/)\.?[A-Za-z0-9_.-]+},
          &String.replace(&1, ~r{^(?:\$HOME/|~/)}, "")
        )

      # `.lcars` seul est tenu ici ; les autres noms sous $HOME appartiennent a leur proprietaire
      # (`.local`, `.claude`, `.config`…) et ce mur n'a rien a en dire.
      intruses =
        vus
        |> Enum.filter(&String.contains?(&1, "lcars"))
        |> Enum.reject(&(&1 == expected))
        |> Enum.sort()

      roots_verdict(id, remediation, %{
        autorite_vue?: Enum.member?(vus, expected),
        attendue: "occurrence of $HOME/#{expected} in the corpus",
        intruses: intruses,
        note_ok:
          "every per-human LCARS path starts with #{inspect(expected)}, declared by " <>
            "Fleet.Layout @state_dirname (#{MapSet.size(vus)} distinct name(s) under $HOME " <>
            "across #{porteurs} files)",
        note_ko:
          "authority says #{inspect(expected)} — #{length(intruses)} other LCARS name(s) under " <>
            "$HOME: " <> Enum.join(intruses, ", ")
      })
    end
  end

  @doc """
  Checks recognised /home/projects roots against Layout face_root attribute clauses,
  plus the explicitly exempt agents' work tree.

  This scans the parent repository corpus, excluding test/tests and .expert paths.
  At least three recognised clauses are required; inline or differently shaped
  clauses can be missed. Declared roots themselves can satisfy the occurrence guard.

  This checks names, while layout.face_roots_provisioned separately checks creation
  source patterns. Neither inspection verifies directories on a deployed machine.
  """
  @spec check_face_roots_single_source(String.t()) :: Support.result()
  def check_face_roots_single_source(root) do
    id = "layout.face_roots_single_source"

    remediation =
      "every `/home/projects*` root is a face declared by `Fleet.Layout.face_root/1` — a root the " <>
        "declaration does not know is a tree the runtime will never look at"

    faces = declared_faces(root)

    racines = faces |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    hors_face = ["/home/projects.work"]

    if length(faces) < 3 or Enum.any?(faces, fn {_, v} -> is_nil(v) end) do
      %{
        id: id,
        remediation: remediation,
        status: :fail,
        evidence: ["lib/fleet/layout.ex"],
        note:
          "the faces no longer read as frozen literals in Fleet.Layout " <>
            "(#{length(faces)} clause(s) found, #{length(racines)} with a readable root) — " <>
            "nothing was compared"
      }
    else
      # Face-root scanning starts at the repository parent, with filters relative to that base.
      base = Path.expand(Path.join(root, ".."))

      vues =
        corpus_files(base)
        |> Enum.reject(&String.match?("/" <> Path.relative_to(&1, base), ~r"/(\.expert|tests?)/"))
        |> Enum.reduce(MapSet.new(), &collect_face_roots/2)

      inconnues =
        vues
        |> Enum.reject(&(&1 in racines or &1 in hors_face))
        |> Enum.sort()

      cond do
        not Enum.all?(racines, &MapSet.member?(vues, &1)) ->
          broken_result(id, "occurrence of every declared face root in the corpus")

        inconnues == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: [],
            note:
              "the #{length(racines)} faces declared by Fleet.Layout.face_root/1 " <>
                "(#{Enum.join(racines, ", ")}) are the only /home/projects roots in the corpus, " <>
                "plus #{length(hors_face)} declared non-face tree"
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: inconnues,
            note:
              "Fleet.Layout declares #{Enum.join(racines, ", ")} — " <>
                "#{length(inconnues)} other /home/projects root(s) are neither a face nor " <>
                "declared: " <> Enum.join(inconnues, ", ")
          }
      end
    end
  end

  @doc """
  Compares the literal default in Toolchain.ops_repo/0 with two service fallbacks.
  Repository and branch are separate parts of the executor/converger address;
  the branch check does not cover this value.

  Only source defaults in the ops-repo gesture, the seat skill, the converger and the executor are checked,
  not effective environment values or the existence of the repository.
  """
  @spec check_ops_repo_single_source(String.t()) :: Support.result()
  def check_ops_repo_single_source(root) do
    id = "toolchain.ops_repo_single_source"

    remediation =
      "copy the literal from `Fleet.Toolchain.ops_repo/0` — the repository and its branch are two " <>
        "halves of one address, and the branch is already locked"

    expected =
      case File.read(Path.expand("lib/fleet/toolchain.ex", root)) do
        {:ok, src} ->
          case Regex.run(
                 ~r/def ops_repo, do: Application\.get_env\([^,]+,\s*[^,]+,\s*"([^"]+)"\)/,
                 src
               ) do
            [_, v] -> v
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(expected) do
      unreadable_authority(
        id,
        remediation,
        "lib/fleet/toolchain.ex",
        "Fleet.Toolchain.ops_repo/0",
        "default"
      )
    else
      # ⚖ Decision 3: NO copy freezes the whole address any more. Every mirror DERIVES the repo
      # from the org fact (an org the installer renamed takes its repository along); only the
      # repository half is a literal, and that half is a rule, not a fact.
      repo_half = expected |> String.split("/", parts: 2) |> List.last() |> Regex.escape()

      mirrors = [
        {"services/forge.d/ops-repo.sh",
         ~r/LCARS_OPS_REPO:=\$\{LCARS_FORGE_ORG\}\/#{repo_half}\}/,
         "the ops-repo gesture's fallback (derived from the org)"},
        # ⚖ Decision 3: these two derive from the org fact like the gesture does, instead of
        # freezing the whole address — the org half is a fact, the repository half a rule.
        {"services/admiral/skills/system-issues/list.sh",
         ~r/LCARS_OPS_REPO:-\$LCARS_FORGE_ORG\/#{repo_half}\}/,
         "the seat skill's fallback (derived from the org)"},
        {"bin/lcars-toolchain-converge", ~r/LCARS_OPS_REPO:-\$LCARS_FORGE_ORG\/#{repo_half}\}/,
         "the toolchain converger's fallback (derived from the org)"},
        {"services/privileged-executor.py",
         ~r/"LCARS_OPS_REPO",\s*"%s\/#{repo_half}"\s*%\s*lcars_facts\.get\("LCARS_FORGE_ORG"\)/s,
         "the root executor's ops-repo fallback (derived from the org fact)"}
      ]

      {checked, skipped} =
        Enum.split_with(mirrors, fn {rel, _, _} ->
          mirror_scope(rel, root) == :required
        end)

      bad = Enum.flat_map(checked, &mirror_gap(&1, root))
      labels = skipped |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      cond do
        checked == [] ->
          out_of_scope(id, "no copy present", labels)

        bad == [] ->
          %{
            id: id,
            remediation: "—",
            status: :pass,
            evidence: Enum.map(checked, &elem(&1, 0)),
            note:
              "#{inspect(expected)} declared by Fleet.Toolchain.ops_repo/0 and copied by the " <>
                "#{length(checked)} services that cannot call the BEAM" <> skipped_note(labels)
          }

        true ->
          %{
            id: id,
            remediation: remediation,
            status: :fail,
            evidence: Enum.map(bad, &elem(&1, 0)),
            note:
              "authority says #{inspect(expected)} — " <>
                Enum.map_join(bad, " · ", fn {f, why} -> "#{f}: #{why}" end) <>
                skipped_note(labels)
          }
      end
    end
  end

  # Compare Macro.to_string defaults for literal keys in direct Application get_env/compile_env calls.
  # Group by key only, ignoring application namespace; pipes and dynamic keys are not resolved.
  # Equal expressions may be repeated; differing expressions can evaluate to the same value.
  @doc false
  @spec check_config_single_default(String.t()) :: Support.result()
  def check_config_single_default(root) do
    lectures =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        path
        |> File.read!()
        |> Code.string_to_quoted!()
        |> collect(fn
          {{:., _, [{:__aliases__, _, [:Application]}, verbe]}, _, [_app, cle, defaut]}
          when verbe in [:get_env, :compile_env] and is_atom(cle) ->
            {cle, Macro.to_string(defaut), rel}

          _ ->
            nil
        end)
      end)

    divergentes =
      lectures
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.filter(fn {_cle, v} ->
        v |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1
      end)
      |> Enum.sort()

    if measured_nothing?(lectures) do
      broken_result("config.single_default", "Application.get_env/3 call under lib/")
    else
      %{
        id: "config.single_default",
        remediation:
          "une clef de configuration porte UN repli — que le module qui declare le contrat le " <>
            "porte, et que les autres l'appellent (cf. `Delegation.ForgeClient.resolved/0`). Deux " <>
            "replis pour une clef ne divergent qu'en l'absence de configuration, donc jamais en " <>
            "test et toujours en production",
        status: if(divergentes == [], do: :pass, else: :fail),
        evidence:
          Enum.map(divergentes, fn {cle, v} ->
            "#{inspect(cle)} : " <>
              (v
               |> Enum.map(fn {_c, d, rel} -> "#{rel} -> #{d}" end)
               |> Enum.uniq()
               |> Enum.join(" · "))
          end),
        note:
          "#{length(lectures)} lecture(s) avec repli sur " <>
            "#{lectures |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()} clef(s) distincte(s)"
      }
    end
  end

  @spec unreadable_authority(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          Support.result()
  defp unreadable_authority(id, remediation, source, autorite, forme \\ "literal") do
    %{
      id: id,
      remediation: remediation,
      status: :fail,
      evidence: [source],
      note:
        "`#{autorite}` no longer reads as a frozen #{forme} — the authority is unreadable, so " <>
          "nothing was compared"
    }
  end

  @spec out_of_scope(String.t(), String.t(), [String.t()]) :: Support.result()
  defp out_of_scope(id, sujet, absents) do
    %{
      id: id,
      remediation: "—",
      status: :pass,
      evidence: [],
      note:
        "NOT CHECKED here — #{sujet} in this artifact (runtime-only context)" <>
          if(absents == [], do: "", else: ": " <> Enum.join(absents, ", "))
    }
  end

  # Forge.Payload owns access to external response shapes.
  # Inspect selected literal-key Access/Map/get_in forms outside forge/ and checker sources.
  # Patterns, dynamic keys, pipes and renamed aliases are not fully resolved.
  # base, login and sha are excluded because they also name local data fields;
  # a head.sha access can still be detected through head.
  @forge_response_keys ~w(full_name html_url pull_request merged merged_at commit_id dismissed
                          head labels assignee assignees mergeable repository
                          default_branch draft updated_at created_at)a

  @doc false
  @spec check_forge_shape_contained(String.t()) :: Support.result()
  def check_forge_shape_contained(root) do
    fichiers =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(String.starts_with?(&1, "lib/fleet/forge/") or checker_source?(&1)))

    fautes = Enum.flat_map(fichiers, &forge_shape_reads(root, &1))

    if measured_nothing?(fichiers) do
      broken_result("forge.shape_contained", "source under lib/ outside the forge domain")
    else
      %{
        id: "forge.shape_contained",
        remediation:
          "lire la charge par `Fleet.Forge.Payload` — un chemin par fait, declare une fois et " <>
            "verifie contre une capture reelle. Un module hors du domaine forge qui connait la " <>
            "forme de l'API rend toute montee de version de la forge indetectable au gate",
        status: if(fautes == [], do: :pass, else: :fail),
        evidence: fautes,
        note:
          "#{length(fichiers)} source(s) hors du domaine forge — acces `x[\"k\"]`, `get_in/2` et `Map.get/2` " <>
            "sur l'AST ; les MOTIFS ne sont pas couverts, cf. le commentaire ci-dessus"
      }
    end
  end

  # Literal docs do not create access nodes; interpolated expressions can.
  defp forge_shape_reads(root, rel) do
    root
    |> quoted!(rel)
    |> collect(fn
      {{:., meta, [Access, :get]}, _, [_, clef]} when is_binary(clef) ->
        if String.to_atom(clef) in @forge_response_keys, do: {rel, meta[:line]}

      {:get_in, meta, [_, chemin]} when is_list(chemin) ->
        if Enum.any?(chemin, &(is_binary(&1) and String.to_atom(&1) in @forge_response_keys)),
          do: {rel, meta[:line]}

      {{:., meta, [{:__aliases__, _, [:Map]}, f]}, _, [_, clef | _]}
      when f in [:get, :fetch, :fetch!] and is_binary(clef) ->
        if String.to_atom(clef) in @forge_response_keys, do: {rel, meta[:line]}

      # Explicit Access calls use an alias AST unlike the atom generated by bracket access.
      {{:., meta, [{:__aliases__, _, [:Access]}, f]}, _, [_, clef | _]}
      when f in [:get, :fetch] and is_binary(clef) ->
        if String.to_atom(clef) in @forge_response_keys, do: {rel, meta[:line]}

      _ ->
        nil
    end)
    |> Enum.map(fn {f, l} -> "#{f}:#{l}" end)
  end

  # ⚠ LE MODE D'UNE FACE EST UN FAIT DE `Fleet.Layout`, PAS UN LITTERAL QU'ON RECOPIE. Trois chemins
  # batissent une face d'ecriture — creation, adoption, import — et deux d'entre eux ne posaient
  # aucun mode : le repertoire naissait sous l'umask du BEAM, l'atelier cessait d'etre ecrivable par
  # le groupe, et un depot humain s'y refusait sans qu'aucun message ne le dise (mesure du
  # 2026-09-16 sur LCARS-beta). Un littéral recopié est la forme que reprend ce défaut.
  @writer_face_mode_rx ~r/0o2[0-7]{3}/
  @face_mode_declaration "lib/fleet/layout.ex"

  @doc """
  Checks the setgid modes of the writer faces are declared ONCE, in `Fleet.Layout`.

  Scans the Elixir sources of this tree for a setgid directory literal outside that declaration,
  comments stripped. It does not check the values against the deployment manifest: the manifest
  declares the face ROOTS, which `layout.face_roots_provisioned` covers, not a project's face
  directory inside them.
  """
  @spec check_face_mode_single_source(String.t()) :: Support.result()
  def check_face_mode_single_source(root) do
    id = "layout.face_mode_single_source"

    declares =
      case File.read(Path.join(root, @face_mode_declaration)) do
        {:ok, code} ->
          case Regex.run(~r/@writer_face_modes\s+%\{[^}]*\}/, code) do
            [map] -> length(Regex.scan(@writer_face_mode_rx, map))
            nil -> 0
          end

        {:error, _} ->
          0
      end

    sources =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        rel = Path.relative_to(path, root)
        rel == @face_mode_declaration or Support.checker_source?(rel)
      end)

    copies =
      for path <- sources,
          {line, texte} <- grep_lines(path, @writer_face_mode_rx),
          Regex.match?(@writer_face_mode_rx, strip_comment(texte)),
          do: "#{Path.relative_to(path, root)}:#{line}"

    Support.measured_verdict(id, %{
      remediation:
        "read the mode from `Fleet.Layout.writer_face_mode/1` — a face mode written twice is a " <>
          "face that stops being group-writable the day one copy moves, in silence",
      broken: face_mode_broken(declares, sources),
      findings: Enum.sort(copies),
      note:
        "#{declares} writer face mode(s) declared in #{@face_mode_declaration}, " <>
          "#{length(sources)} other source(s) scanned"
    })
  end

  # Two guards, because either half alone would pass on an empty measure: a declaration that no
  # longer reads as literals, and a corpus this check never opened.
  defp face_mode_broken(declares, sources) do
    cond do
      declares < 2 -> "#{@face_mode_declaration} no longer declares two writer face modes"
      Support.measured_nothing?(sources) -> "no Elixir source scanned under lib/"
      true -> nil
    end
  end

  # ── Les faits de la machine (⚖ decision 3) ──────────────────────────────────────────────────
  @facts_file "etc/facts.env"
  # Les deux lecteurs du fichier — le seul du shell, le seul du Python. Ils le NOMMENT, forcement.
  @facts_readers ~w(services/lib/facts.sh services/lcars_facts.py lib/fleet/facts.ex)
  @facts_scan ~w(.sh .bash .py .ex .exs .env)
  # Les repertoires ou vit du code qui pourrait rejouer un defaut. `priv/` porte du catalogue (de la
  # prose de SP, pas du code de la machine) et reste dehors, comme partout ailleurs dans ce module.
  @facts_trees ~w(bin services config lib ../deploy)

  @doc """
  Refuses a SECOND default for any machine fact declared in `etc/facts.env`.

  A fact is written once and read by four languages. A reader that writes `${LCARS_X:-literal}`,
  `System.get_env("LCARS_X", literal)` or `environ.get("LCARS_X", literal)` reintroduces the
  duplicate the file exists to remove, and the copy that drifts is always the one nobody rereads.

  Derivations are allowed and unaffected: `${LCARS_OPS_REPO:-$LCARS_FORGE_ORG/_ops}` names a RULE,
  not a fact, and its own wall holds it. Only a literal default for a DECLARED fact key is refused.

  Scope is the shell, Python and Elixir of the product plus the installer tree; `priv/` (catalogue
  prose) and the checkers themselves are out. An absent installer tree is named, not silently passed.
  """
  @spec check_facts_single_source(String.t()) :: Support.result()
  def check_facts_single_source(root) do
    id = "facts.single_source"

    remediation =
      "read the fact instead of re-defaulting it: source `services/lib/facts.sh` (shell), " <>
        "`lcars_facts.get` (Python) or `Fleet.Facts.get!` (Elixir). A fact written twice is a " <>
        "fact that splits the day one copy moves, and nothing says so"

    keys = facts_keys(root)
    sources = facts_corpus(root)
    # Compile once, read each file once: sixteen facts times four hundred files is six thousand
    # reads of the same bytes, and this check runs on every gate.
    patterns = Enum.map(keys, &{&1, facts_default_rx(&1)})
    copies = Enum.flat_map(sources, &facts_copies(&1, root, patterns))

    Support.measured_verdict(id, %{
      remediation: remediation,
      broken: facts_broken(keys, sources),
      findings: copies |> Enum.uniq() |> Enum.sort(),
      note:
        "#{length(keys)} machine fact(s) declared in #{@facts_file}, " <>
          "#{length(sources)} source(s) scanned in #{Enum.join(@facts_trees, ", ")}"
    })
  end

  # A NUL-bearing file is not source: reading it as text would scan a provider binary line by line.
  defp facts_copies(path, root, patterns) do
    case File.read(path) do
      {:ok, body} ->
        if String.contains?(body, <<0>>),
          do: [],
          else: facts_scan(body, facts_rel(path, root), patterns)

      _ ->
        []
    end
  end

  defp facts_scan(body, rel, patterns) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {texte, line} ->
      code = strip_comment(texte)

      for {key, rx} <- patterns, Regex.match?(rx, code), do: "#{rel}:#{line} (#{key})"
    end)
  end

  # ⚠ C'EST LE `source` QU'ON CHERCHE, PAS LE NOM DU FICHIER. Premiere ecriture de ce mur : il
  # cherchait la chaine « facts.sh » n'importe ou dans le corps. Commenter la ligne
  # `. "$FACTS_SH"` le laissait VERT — l'affectation `FACTS_SH="…/facts.sh"` juste au-dessus
  # portait encore la chaine. Un mur qui cherche un nom mesure une intention ; celui-ci mesure un
  # GESTE : une ligne de code qui SOURCE, dont la cible mene aux faits.
  # ⚠ DEUX FORMES, ET LA SECONDE N'EST PAS UNE FACILITE : le `HEALTHCHECK` du Dockerfile source
  # `/opt/lcars/services/lib/facts.sh` EN DUR, parce qu'il n'a ni voisin ni variable — il tourne
  # dans l'image, ou le chemin du produit EST le fait. Ne reconnaitre que la variable rendait ce
  # fichier « debranche » alors qu'il est le plus litteralement branche du depot.
  # ⚠ ET L'ANCRE N'EST PLUS LE DEBUT DE LIGNE : ce meme `source` vit au milieu d'un `CMD` JSON, donc
  # derriere un guillemet. Un `source` COMMENTE ne repasse pas pour autant — `facts_cable?` retire
  # les commentaires AVANT d'appliquer ce motif, et c'est la que la mesure du debranchement tient.
  @facts_source_shell ~r/(?:^|[;&|(]|["']\s*)\s*(?:\.|source)\s+["']?(?:\$\{?(?:LCARS_FACTS_SH|FACTS_SH|LCARS_MODULE_PROTOCOL|MODULE_PROTOCOL|LCARS_HUMAN_PROTOCOL|HUMAN_PROTOCOL)\b|[^\s"';|&]*\/(?:facts|module-protocol|human-protocol)\.sh\b)/m
  @facts_cablage %{python: ["lcars_facts"], elixir: ["Fleet.Facts"]}

  @doc """
  Refuses a file that NAMES a machine fact without being WIRED to a reader of `etc/facts.env`.

  ⚖ Phase 5, la moitie manquante. Les murs de cette famille tiennent tous la meme chose : que la
  VALEUR d'un fait ne soit ecrite qu'une fois. Aucun ne tenait son APPROVISIONNEMENT. Mesure du
  2026-09-19 : commenter le `. "$FACTS_SH"` de `services/console.sh` laisse les 80 murs verts, et
  le lanceur pose son repertoire de socket SANS GROUPE — parce que `$LCARS_CONSOLE_GROUP` vaut la
  chaine vide. Avant cette passe, le fichier portait `${LCARS_CONSOLE_GROUP:-lcars-console}` : une
  propriete verifiable statiquement, remplacee par une propriete que rien ne mesurait.

  Etre cable, c'est porter l'un des signes de son langage : sourcer `lib/facts.sh`, ou sourcer un
  protocole qui le source (`LCARS_MODULE_PROTOCOL`, `LCARS_HUMAN_PROTOCOL`), ou importer
  `lcars_facts`, ou appeler `Fleet.Facts`. C'est une verification de FORME : elle ne prouve pas que
  le fichier source est lisible a l'execution, ni que la valeur arrive.
  """
  @spec check_facts_readers_wired(String.t()) :: Support.result()
  def check_facts_readers_wired(root) do
    id = "facts.readers_wired"

    remediation =
      "source le lecteur des faits (`services/lib/facts.sh`, ou un protocole qui le source ; " <>
        "`lcars_facts` en Python, `Fleet.Facts` en Elixir) — un fichier qui NOMME un fait sans " <>
        "etre branche le lit VIDE, et rien d'autre ne le dit"

    keys = facts_keys(root)
    sources = facts_corpus(root)

    debranches =
      for path <- sources,
          langue = facts_langue(path),
          langue != nil,
          body = facts_body(path),
          body != nil,
          facts_nomme?(body, keys, langue),
          not facts_cable?(body, langue),
          do: facts_rel(path, root)

    Support.measured_verdict(id, %{
      remediation: remediation,
      broken: facts_broken(keys, sources),
      findings: debranches |> Enum.uniq() |> Enum.sort(),
      note:
        "#{length(keys)} machine fact(s) declared in #{@facts_file}, " <>
          "#{length(sources)} source(s) scanned in #{Enum.join(@facts_trees, ", ")}"
    })
  end

  @doc """
  Refuses a shell variable that bears a machine fact's NAME and receives a LITERAL.

  ⚖ Phase 5, the other half of `facts.single_source`. That wall keys on the fact's name inside an
  expansion — `${LCARS_X:-literal}` — so it sees a second DEFAULT. It cannot see a second VALUE
  under a shortened name: `SYSTEM_ACCOUNT="system_starfleet_v2"` names no fact and defaults nothing.
  Measured 2026-09-19: that exact line left all eighty walls green, and the gesture then spoke to
  the forge as an account nobody declared.

  The rule is the product's own idiom turned into a property: every alias of a fact in this tree
  reads `NAME="$LCARS_NAME"`. A right-hand side with no expansion in it is a COPY of the value, and
  a copy is what the facts file exists to remove.

  Scope is the shell of the product and the installer, tests excluded — a bench decor sets literals
  on purpose, and that is what a decor is for. Array literals are skipped: the installer's
  translation tables (`PROV_PRODUCT_NAMES`, `PROV_FACT_MIRRORS`) carry `LCARS_X=PROV_Y` pairs, which
  are NAMES facing each other, not a value written twice. This is a check of FORM: it does not
  prove the alias is read, nor that the fact it names carries what the caller expects.
  """
  @spec check_facts_no_literal_alias(String.t()) :: Support.result()
  def check_facts_no_literal_alias(root) do
    id = "facts.no_literal_alias"

    remediation =
      "assign the alias FROM the fact — `NAME=\"$LCARS_NAME\"` — after sourcing " <>
        "`services/lib/facts.sh`. A literal under a fact's name is a second value that no wall " <>
        "compares, and the day the fact moves, this copy stays"

    keys = facts_keys(root)
    sources = Enum.reject(facts_corpus(root), &facts_decor?(&1, root))
    patterns = Enum.map(keys, &{&1, facts_alias_rx(&1)})

    copies =
      for path <- sources,
          facts_langue(path) == :shell,
          body = facts_body(path),
          body != nil,
          finding <- facts_alias_scan(body, facts_rel(path, root), patterns),
          do: finding

    Support.measured_verdict(id, %{
      remediation: remediation,
      broken: facts_broken(keys, sources),
      findings: copies |> Enum.uniq() |> Enum.sort(),
      note:
        "#{length(keys)} machine fact(s) declared in #{@facts_file}, " <>
          "#{length(sources)} non-test source(s) scanned in #{Enum.join(@facts_trees, ", ")}"
    })
  end

  # `LCARS_X=…` with an unprefixed twin `X=…`: both are the fact's name, and both must read it.
  defp facts_alias_rx(key) do
    court = String.replace_prefix(key, "LCARS_", "")

    Regex.compile!(
      "^\\s*(?:export|local|declare|readonly|typeset)?\\s*(?:#{Regex.escape(key)}|" <>
        "#{Regex.escape(court)})=(.*)$"
    )
  end

  # An array literal opens on `NAME=(` and closes on a lone `)`. Its rows are name→name pairs, not
  # assignments; scanning them would report the installer's translation tables as copies.
  defp facts_alias_scan(body, rel, patterns) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {texte, line}, {dans_tableau?, acc} ->
      code = strip_comment(texte)

      cond do
        dans_tableau? -> {not Regex.match?(~r/^\s*\)\s*$/, code), acc}
        Regex.match?(~r/^\s*[A-Za-z_][A-Za-z0-9_]*=\(\s*$/, code) -> {true, acc}
        true -> {false, acc ++ facts_alias_hits(code, rel, line, patterns)}
      end
    end)
    |> elem(1)
  end

  defp facts_alias_hits(code, rel, line, patterns) do
    for {key, rx} <- patterns,
        [_, valeur] <- [Regex.run(rx, code)],
        facts_litteral?(valeur),
        do: "#{rel}:#{line} (#{key})"
  end

  # A right-hand side with an expansion in it READS something; only one with none is a copy.
  # An empty one declares nothing, and `$(…)`, `${…}` and `"$X"` all carry the `$`.
  defp facts_litteral?(valeur) do
    trimmed = String.trim(valeur)
    trimmed != "" and not String.contains?(trimmed, "$")
  end

  # A bench decor sets literals ON PURPOSE — that is what a decor is. Refusing them would make the
  # wall unplayable, and the witnesses are not the machine.
  defp facts_decor?(path, root) do
    path
    |> facts_rel(root)
    |> Path.split()
    |> Enum.any?(&(&1 in ["test", "tests"]))
  end

  defp facts_cable?(body, :shell) do
    body
    |> String.split("\n")
    |> Enum.map(&strip_comment/1)
    |> Enum.any?(&Regex.match?(@facts_source_shell, &1))
  end

  defp facts_cable?(body, langue),
    do: Enum.any?(@facts_cablage[langue], &String.contains?(body, &1))

  defp facts_langue(path) do
    case Path.extname(path) do
      ".py" -> :python
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".sh" -> :shell
      ".bash" -> :shell
      # `bin/lcars`, `bin/fleet` : sans extension, et ce sont des scripts shell.
      "" -> :shell
      _ -> nil
    end
  end

  defp facts_body(path) do
    case File.read(path) do
      {:ok, body} -> if String.contains?(body, <<0>>), do: nil, else: body
      _ -> nil
    end
  end

  # Le shell NOMME un fait par une expansion ; le Python et l'Elixir par une chaine litterale.
  defp facts_nomme?(body, keys, :shell) do
    code = Enum.map_join(String.split(body, "\n"), "\n", &strip_comment/1)
    Enum.any?(keys, &Regex.match?(Regex.compile!("\\$\\{?#{Regex.escape(&1)}\\b"), code))
  end

  defp facts_nomme?(body, keys, _langue) do
    code = Enum.map_join(String.split(body, "\n"), "\n", &strip_comment/1)
    Enum.any?(keys, &String.contains?(code, "\"#{&1}\""))
  end

  defp facts_keys(root) do
    case File.read(Path.join(root, @facts_file)) do
      {:ok, body} ->
        ~r/^([A-Z][A-Z0-9_]*)=/m
        |> Regex.scan(body)
        |> Enum.map(&List.last/1)

      _ ->
        []
    end
  end

  defp facts_corpus(root) do
    @facts_trees
    |> Enum.map(&Path.expand(&1, root))
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&Support.corpus_files/1)
    |> Enum.filter(&(Path.extname(&1) in @facts_scan or Path.extname(&1) == ""))
    |> Enum.reject(fn path ->
      rel = Path.relative_to(path, root)
      rel in @facts_readers or Support.checker_source?(rel) or not File.regular?(path)
    end)
    |> Enum.sort()
  end

  # Le voisin s'écrit `../deploy/x`, comme partout ailleurs dans ce module : une preuve absolue
  # porte le chemin de la MACHINE qui a joué le mur, que personne ne peut retrouver ailleurs.
  defp facts_rel(path, root) do
    parent = Path.dirname(root)

    cond do
      String.starts_with?(path, root <> "/") -> Path.relative_to(path, root)
      String.starts_with?(path, parent <> "/") -> Path.join("..", Path.relative_to(path, parent))
      true -> path
    end
  end

  # `${K:-lit}` / `${K:=lit}` in shell, `get_env("K", lit)` in Elixir, `get("K", "lit")` in Python.
  # A default that is itself an expansion (`${K:-$OTHER}`) is a derivation and stays legal.
  defp facts_default_rx(key) do
    k = Regex.escape(key)
    Regex.compile!("\\$\\{#{k}:[-=][^$}][^}]*\\}|[gG]et(?:_env)?\\(\\s*[\"']#{k}[\"']\\s*,")
  end

  defp facts_broken(keys, sources) do
    cond do
      Support.measured_nothing?(keys) -> "#{@facts_file} declares no machine fact"
      Support.measured_nothing?(sources) -> "no source scanned for a second default"
      true -> nil
    end
  end
end

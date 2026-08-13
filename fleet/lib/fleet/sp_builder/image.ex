defmodule Fleet.SPBuilder.Image do
  @moduledoc """
  Versioned closed-world snapshot of all SP-builder prompt material. Boot reads and
  fingerprints required artifacts into persistent storage; published images never
  fall back to live disk. Drift is reported while pods keep receiving proven bytes.
  """

  require Logger

  @doc """
  Builds and publishes the SP image from the live roots. Raises on any unreadable root —
  the artifacts are load-bearing prompt material, a hole is a broken deploy. Gated by the
  caller (`:lcars_fleet, :sp_builder_publish_image`).
  """
  @spec publish!() :: :ok
  def publish! do
    # UNE image PAR CATALOGUE ACTIF. La cle etait scalaire et les quatre arbres se resolvaient par
    # `search/1`, donc les catalogues fusionnaient : le SP d'un role venait de n'importe lequel
    # d'entre eux. Un pod de catalogue k doit recevoir le materiel de k, pas celui de son voisin.
    for root <- Fleet.Catalogue.active_roots(), do: publish_scope!(root)
    :ok
  end

  defp publish_scope!(root) do
    ensure_declared_roles_carry_an_sp!(root)

    image = %{
      modop_sp:
        read_dir_map!(modop_roots(root), "*/sp.md", &(&1 |> Path.dirname() |> Path.basename())),
      subagent:
        read_dir_map!(
          subagent_roots(root),
          "subagent-*.md",
          &(&1 |> Path.basename(".md") |> String.replace_prefix("subagent-", ""))
        ),
      drafts:
        read_dir_map!(
          drafts_roots(root),
          "agent-*-base.md",
          &(&1
            |> Path.basename(".md")
            |> String.replace_prefix("agent-", "")
            |> String.replace_suffix("-base", ""))
        ),
      worker_protocol: read_worker_protocol!(root),
      human_protocol: read_protocol!(human_protocol_path(root), "human protocol"),
      # (`sp_role_bases` lived here: a SECOND corpus of prompt files, keyed by path under the
      # cap-profiles root, serving `spec.systemPrompt`. The field was forbidden by the schema, so no
      # valid catalogue could name one — the map was always empty, and the key it would have been
      # looked up by was a path. `spec.systemPrompt` now names a ROLE, so it resolves through
      # `drafts` above and needs no corpus of its own.)
      # The two EEx templates, frozen as SOURCE (rendered with eval_string against the image). A
      # template is the SHAPE of every prompt the fleet emits — the last thing that may drift
      # mid-life while the version claims otherwise.
      templates: read_dir_map!(template_roots(root), "*.eex", &Path.basename(&1))
    }

    # The SOURCES this epoch was opened with: absolute path -> content sha. Not a second copy — a
    # FINGERPRINT, so the epoch can answer "is the disk still what I validated?". Without it, an
    # edit to the deployed program's prompt material under a live daemon is a NON-EVENT: the image
    # keeps serving the good copy (which is the point — tampered bytes never reach an agent) and
    # nobody ever learns the two diverged. Serving proven-good is the defence; staying SILENT about
    # the divergence is the defect, and the doctrine is explicit — active suspicion of silent failure.
    sources = source_fingerprints(root)

    # MEME TAMPON, MEME DIMENSIONNEMENT QUE `CapProfile.Image.version_of/2` — 48 bits pour
    # distinguer deux epoques dans une trace, jamais pour identifier durablement quoi que ce soit.
    # Il ne quitte pas la VM (calcule ici, range en `persistent_term`, relu par le meme noeud) et
    # `lib/` ne le compare nulle part.
    #
    # ⚠ ICI L'ENTREE EST UNE MAP DE CONTENUS DE FICHIERS, NON TRIEE, et c'est le point sur lequel
    # une revue a soupconne un aggravant : l'ordre de parcours d'une map ne serait pas stable entre
    # executions. MESURE, et c'est FAUX sur cet OTP : `term_to_binary` rend le meme binaire pour
    # deux maps construites dans des ordres opposes — 3 cles ou 60, cles binaires, et imbriquees
    # comprises. Pas de tri ajoute : il n'achete rien d'observable ici, et un geste qui n'achete
    # rien sur un tampon n'est pas neutre (il change toutes les versions deja tracees).
    version =
      :crypto.hash(:sha256, :erlang.term_to_binary(image))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    :persistent_term.put(
      image_key(root),
      image |> Map.put(:version, version) |> Map.put(:sources, sources)
    )

    # Every section counted: the line an operator reads to know WHAT the version covers. A section
    # published but unnamed here is a piece of the epoch nobody can see was frozen.
    Logger.info(
      "SPBuilder.Image: published (#{map_size(image.modop_sp)} modop fragments, " <>
        "#{map_size(image.subagent)} subagent templates, #{map_size(image.drafts)} drafts, " <>
        "#{map_size(image.templates)} EEx templates, " <>
        "worker + human protocols frozen, version=#{version})"
    )

    :ok
  end

  # DECLARING a role and SUPERSEDING its prompt are two different gestures, and the guard between
  # them is ASYMMETRIC — which is the whole content of this function.
  #
  #   * a catalogue that DECLARES `<role>.yaml` must also carry its SP: `agent-<role>-base.md` in
  #     its own drafts tree, or a `spec.systemPrompt` naming the role it reuses. A cap-profile grants
  #     PERMISSIONS; the SP decides BEHAVIOUR. A role with neither behaves like whoever's prompt it
  #     inherited, and its name lies.
  #   * a catalogue that carries `agent-<role>-base.md` and NOT the yaml is superseding a role it
  #     did not write. That is the child-theme gesture, it is the point, and it is silent here.
  #
  # PER CATALOGUE, and that is what a deployment-wide check cannot do. `canon spawn-proof` already
  # refuses a role whose draft exists in NO root — but it reads the union, so a role declared by
  # catalogue A and prompted by an unrelated catalogue B passes: A's role silently runs B's
  # behaviour. With the two bundled roots that configuration is unreachable (the only names both
  # sides carry are the four the system also DECLARES, which is the legal override). It becomes
  # reachable the moment an operator stacks catalogues, which is what the search path was built for
  # — so the guard lands WITH the mechanism rather than after the first accident.
  #
  # LIMIT, and it is structural: a FINE override moves one tree out of its catalogue, and nothing
  # can then attribute a role to a catalogue. Such a tree is not visited rather than guessed at.
  defp ensure_declared_roles_carry_an_sp!(scope_root) do
    # Grouped by ROLE across the catalogues that declare it, never per catalogue in isolation. A
    # business catalogue that copies `architect.yaml` to widen its tools and keeps the system's
    # prompt declares a role whose SP it does not carry — and that is LEGAL, because the name means
    # the same thing on both sides. The lie needs a name introduced by one catalogue and prompted by
    # another that never heard of it.
    carried =
      Enum.reduce([scope_root, Fleet.Catalogue.system_root()], %{}, fn root, acc ->
        cap_dir = Path.join(root, Fleet.Catalogue.rel(:cap_profiles))
        drafts_dir = Path.join(root, Fleet.Catalogue.rel(:sp_drafts))

        case Fleet.CapProfile.index_of(cap_dir) do
          {:ok, index} ->
            Enum.reduce(Map.keys(index), acc, fn role, acc ->
              Map.update(
                acc,
                role,
                sp_carried?(index, drafts_dir, role),
                &(&1 or sp_carried?(index, drafts_dir, role))
              )
            end)

          {:error, _} ->
            acc
        end
      end)

    orphans = carried |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    unless orphans == [] do
      raise "SPBuilder.Image: #{Enum.join(orphans, ", ")} — declared by a catalogue that carries " <>
              "no SP for them. A catalogue that DECLARES a role owes its prompt: " <>
              "`agent-<role>-base.md` in its own sp_drafts, or `spec.systemPrompt` naming the role " <>
              "it reuses. Carrying the draft ALONE is the legal gesture (superseding a role you did " <>
              "not write) and is never reported here. Proven-good image at boot, or do not boot."
    end

    :ok
  end

  # `systemPrompt` is honoured WITHOUT following it: whether the borrowed role resolves is
  # `read_agent_draft/1`'s answer and the spawn proof's to enforce. This one asks only whether the
  # catalogue SAID where the behaviour comes from — declaring the reuse IS carrying the SP.
  defp sp_carried?(index, drafts_dir, role) do
    borrowed = index |> Map.get(role, %{}) |> get_in(["spec", "systemPrompt"])

    is_binary(borrowed) or File.regular?(Path.join(drafts_dir, "agent-#{role}-base.md"))
  end

  @doc """
  Paths whose content no longer matches what `publish!/0` validated, as
  `[{path, :modified | :vanished}]`. `[]` = the disk still agrees with the epoch; `:unpublished`
  when no image is live (nothing was ever validated, so nothing can have drifted).

  Answers the question the image used to swallow. A non-empty list means the deployed program's
  prompt material changed under a running daemon: the pods keep receiving the proven-good content
  (that is the defence), and the operator gets told (that is what was missing).
  """
  @spec drift() :: {:ok, [{Path.t(), :modified | :vanished}]} | :unpublished
  def drift do
    case published() do
      %{sources: sources} ->
        {:ok,
         sources
         |> Enum.flat_map(fn {path, sha} ->
           case File.read(path) do
             {:ok, content} -> if sha_of(content) == sha, do: [], else: [{path, :modified}]
             {:error, _} -> [{path, :vanished}]
           end
         end)
         |> Enum.sort()}

      _ ->
        :unpublished
    end
  end

  # Same roots, same globs as the sections above — one traversal, hashed. Kept beside them on
  # purpose: a section added without a line here would be material the drift check cannot see.
  defp source_fingerprints(root) do
    # The ROOTS here are the plural ones, and that is the whole point of this function's warning:
    # reading only the business root would leave the system catalogue's prompt material outside the
    # fingerprint — editable under a live daemon with nobody told.
    [
      {modop_roots(root), "*/sp.md"},
      {subagent_roots(root), "subagent-*.md"},
      {drafts_roots(root), "agent-*-base.md"},
      {template_roots(root), "*.eex"}
    ]
    |> Enum.flat_map(fn {roots, glob} ->
      Enum.flat_map(roots, &(&1 |> Path.join(glob) |> Path.wildcard()))
    end)
    |> Enum.concat([worker_protocol_path(root), human_protocol_path(root)])
    |> Enum.uniq()
    |> Map.new(fn path -> {path, path |> File.read!() |> sha_of()} end)
  end

  defp sha_of(content), do: :crypto.hash(:sha256, content)

  @doc "The published image of a catalogue, or nil. No argument = the FIRST active catalogue."
  @spec published() :: map() | nil
  def published do
    # `active_roots/0` rend TOUJOURS au moins le catalogue bundle — pas de branche vide a ecrire.
    Fleet.Catalogue.active_roots() |> hd() |> published()
  end

  @spec published(Path.t()) :: map() | nil
  def published(root) when is_binary(root), do: :persistent_term.get(image_key(root), nil)

  @doc "Erases every published image — TESTS ONLY."
  @spec unpublish() :: :ok
  def unpublish do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, :image, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  @doc """
  Restores an image for the FIRST active catalogue — TESTS ONLY, symmetric of `unpublish/0`.

  Exists so a test never writes the persistent_term key itself: the key carries the catalogue root
  now, and a test that composes it by hand pins a private representation instead of the contract —
  which is exactly how two of them broke when the key changed.
  """
  @spec republish(map()) :: :ok
  def republish(%{} = image) do
    :persistent_term.put(image_key(hd(Fleet.Catalogue.active_roots())), image)
    :ok
  end

  defp image_key(root), do: {__MODULE__, :image, root}

  @doc """
  The role's SP draft from the published image (`{:ok, content}`), `:not_found` if the image is
  published but carries no draft for `role` (closed world), `:unpublished` otherwise (the
  caller falls back to disk). Consulted by the spawner's Assets rail.
  """
  @spec draft(String.t()) :: {:ok, binary()} | :not_found | :unpublished
  def draft(role) when is_binary(role), do: draft(role, nil)

  @doc """
  Le meme draft, dans l'image du catalogue NOMME. `nil` = le premier actif (comportement du jour).

  La racine vient du PROFIL (`%CapProfile{}.catalogue_root`) chez les appelants qui en ont un : le
  draft d'un role appartient au catalogue qui le declare, pas au premier de la liste.
  """
  @spec draft(String.t(), Path.t() | nil) :: {:ok, binary()} | :not_found | :unpublished
  def draft(role, root) when is_binary(role) do
    case published_or_default(root) do
      %{drafts: drafts} ->
        case Map.fetch(drafts, role) do
          {:ok, content} -> {:ok, content}
          :error -> :not_found
        end

      nil ->
        :unpublished
    end
  end

  @doc """
  The pod's `protocole-user.md` from the image (`{:ok, content}`) or `:unpublished` (the caller
  falls back to disk). Resolved at PUBLISH time through the same `:protocole_user_path` override
  the disk path honours, so a deployment override still applies while a mid-life edit of that file
  no longer changes the pods spawn by spawn — which is the whole promise.
  """
  @spec worker_protocol() :: {:ok, binary()} | :unpublished
  def worker_protocol, do: worker_protocol(nil)

  @spec worker_protocol(Path.t() | nil) :: {:ok, binary()} | :unpublished
  def worker_protocol(root) do
    case published_or_default(root) do
      %{worker_protocol: content} -> {:ok, content}
      nil -> :unpublished
    end
  end

  @doc """
  The conversation contract added for a human interlocutor (`{:ok, content}`) or `:unpublished`.
  """
  @spec human_protocol() :: {:ok, binary()} | :unpublished
  def human_protocol, do: human_protocol(nil)

  @spec human_protocol(Path.t() | nil) :: {:ok, binary()} | :unpublished
  def human_protocol(root) do
    case published_or_default(root) do
      %{human_protocol: content} -> {:ok, content}
      nil -> :unpublished
    end
  end

  defp published_or_default(nil), do: published()
  defp published_or_default(root) when is_binary(root), do: published(root)

  @doc """
  An EEx template SOURCE by file name (`"sp_template.eex"`): `{:ok, source}`, `:not_found`
  (closed world) or `:unpublished`.
  """
  @spec template(String.t()) :: {:ok, binary()} | :not_found | :unpublished
  def template(name) when is_binary(name), do: lookup(:templates, name)

  defp lookup(section, key) do
    case published() do
      nil ->
        :unpublished

      image ->
        case image |> Map.fetch!(section) |> Map.fetch(key) do
          {:ok, content} -> {:ok, content}
          :error -> :not_found
        end
    end
  end

  # `roots` is ALWAYS a search path. The single-root clause that used to sit beside this one went
  # dead the day the last reader stopped resolving on its own — dialyzer said so before I did, and
  # that unreachability is the proof the door is single.
  defp read_dir_map!(roots, glob, key_fun) when is_list(roots) do
    if Enum.all?(roots, &(Path.wildcard(Path.join(&1, glob)) == [])) do
      raise "SPBuilder.Image: no artifact matches #{glob} under #{inspect(roots)} — " <>
              "proven-good image at boot, or do not boot (broken deploy?)"
    end

    read_dir_map(roots, glob, key_fun)
  end

  # Same read, WITHOUT the non-empty-directory requirement — for a root whose emptiness is a valid
  # deployment shape. A truncated FILE still raises either way: an empty artifact is a broken deploy
  # whatever the root, and that check is the one this image exists for.
  defp read_dir_map(roots, glob, key_fun) when is_list(roots) do
    # `Map.put_new` and the roots in PRECEDENCE order: the first root that carries a key wins, and
    # the later one is not read. That is the child-theme rule — a business catalogue shipping its
    # own `rubber-duck` REPLACES the system's, without declaring anything, which is the whole point
    # of a search path. It refused the collision until 2026-08-10; refusing made overriding
    # impossible, which is the opposite of what a default is for.
    Enum.reduce(roots, %{}, fn root, acc ->
      root
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.reduce(acc, fn path, inner ->
        key = key_fun.(path)

        if Map.has_key?(inner, key) do
          inner
        else
          content = File.read!(path)

          if content == "" do
            raise "SPBuilder.Image: artifact #{path} is empty — proven-good image requires " <>
                    "non-empty artifacts (truncated file in deploy?)"
          end

          Map.put(inner, key, content)
        end
      end)
    end)
  end

  defp read_worker_protocol!(root),
    do: read_protocol!(worker_protocol_path(root), "worker protocol")

  defp read_protocol!(path, label) do
    content = File.read!(path)

    if content == "" do
      raise "SPBuilder.Image: #{label} is empty — proven-good image requires non-empty artifacts"
    end

    content
  end

  # SAME resolution as `Pod.Assets`' machine half (override first, bundled worker default
  # otherwise) — the image must freeze what the consumer would have read, or it freezes the wrong
  # file and the override silently escapes the epoch. Reading another domain's config ATOM creates
  # no module edge (the `:fleet_<dom>` atoms are legacy-valid, D-07); the alternative was a second
  # resolution of the same asset, one edit away from diverging with no gate to catch it.
  defp worker_protocol_path(root) do
    Application.get_env(:lcars_fleet, :spawner_protocole_user_path) ||
      Fleet.Catalogue.find_in(
        Fleet.Catalogue.tree_scope(root, :sp_drafts),
        "protocole-user-worker.md"
      )
  end

  # No override knob, DELIBERATELY: the machine protocol has one because a deployment may need to
  # re-cut the work-item contract, whereas the operator-facing half is meant to be replaced by the
  # operator's own file through the deploy's override scheme, not by a runtime config path. Adding
  # a second knob now would be inventing the mechanism twice before either exists.
  defp human_protocol_path(root),
    do:
      Fleet.Catalogue.find_in(
        Fleet.Catalogue.tree_scope(root, :sp_drafts),
        "protocole-user-human.md"
      )

  # The SAME roots the disk fallback reads (SPBuilder modop_root/subagent_template_root). The drafts
  # root is NOT resolved here: it has a reader in ANOTHER domain (`Spawner.Pod.Assets`, the
  # unpublished path), so it lives on the facade as the single authority — see `drafts_root/0` below.
  # Single authority on the facade — the image and the spawn's disk fallback MUST read one root.
  # THE search path, resolved by `Fleet.Catalogue` like every other reader. A fine override moves
  # the business root only; the system root is never dropped, and an absent directory is — which is
  # what lets the system catalogue ship only what its roles need (it has no subagent template and
  # must not fake one).
  defp modop_roots(root), do: Fleet.Catalogue.tree_scope(root, :modops)

  defp subagent_roots(root), do: Fleet.Catalogue.tree_scope(root, :subagent_templates)

  defp drafts_roots(root), do: Fleet.Catalogue.tree_scope(root, :sp_drafts)

  # Two of the three readers that never learned the search path, and were defects for it: the EEx
  # templates shape the MECHANISM's prompts, and the human protocol was demanded from catalogues
  # that have no human-facing role at all (W-13). They go through the same door as the rest. The
  # third was `sp_role_bases`, and it is gone rather than fixed — see the publish above.
  defp template_roots(root), do: Fleet.Catalogue.tree_scope(root, :sp_templates)
end

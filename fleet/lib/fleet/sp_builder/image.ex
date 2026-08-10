defmodule Fleet.SPBuilder.Image do
  @moduledoc """
  Versioned closed-world snapshot of all SP-builder prompt material. Boot reads and
  fingerprints required artifacts into persistent storage; published images never
  fall back to live disk. Drift is reported while pods keep receiving proven bytes.
  """

  require Logger

  @key {__MODULE__, :image}

  @doc """
  Builds and publishes the SP image from the live roots. Raises on any unreadable root —
  the artifacts are load-bearing prompt material, a hole is a broken deploy. Gated by the
  caller (`:fleet_sp_builder, :publish_image`).
  """
  @spec publish!() :: :ok
  def publish! do
    image = %{
      modop_sp:
        read_dir_map!(modop_roots(), "*/sp.md", &(&1 |> Path.dirname() |> Path.basename())),
      subagent:
        read_dir_map!(
          subagent_roots(),
          "subagent-*.md",
          &(&1 |> Path.basename(".md") |> String.replace_prefix("subagent-", ""))
        ),
      drafts:
        read_dir_map!(
          drafts_roots(),
          "agent-*-base.md",
          &(&1
            |> Path.basename(".md")
            |> String.replace_prefix("agent-", "")
            |> String.replace_suffix("-base", ""))
        ),
      worker_protocol: read_worker_protocol!(),
      human_protocol: read_protocol!(human_protocol_path(), "human protocol"),
      # (`sp_role_bases` lived here: a SECOND corpus of prompt files, keyed by path under the
      # cap-profiles root, serving `spec.systemPrompt`. The field was forbidden by the schema, so no
      # valid catalogue could name one — the map was always empty, and the key it would have been
      # looked up by was a path. `spec.systemPrompt` now names a ROLE, so it resolves through
      # `drafts` above and needs no corpus of its own.)
      # The two EEx templates, frozen as SOURCE (rendered with eval_string against the image). A
      # template is the SHAPE of every prompt the fleet emits — the last thing that may drift
      # mid-life while the version claims otherwise.
      templates: read_dir_map!(template_roots(), "*.eex", &Path.basename(&1))
    }

    # The SOURCES this epoch was opened with: absolute path -> content sha. Not a second copy — a
    # FINGERPRINT, so the epoch can answer "is the disk still what I validated?". Without it, an
    # edit to the deployed program's prompt material under a live daemon is a NON-EVENT: the image
    # keeps serving the good copy (which is the point — tampered bytes never reach an agent) and
    # nobody ever learns the two diverged. Serving proven-good is the defence; staying SILENT about
    # the divergence is the defect, and the doctrine is explicit — active suspicion of silent failure.
    sources = source_fingerprints()

    version =
      :crypto.hash(:sha256, :erlang.term_to_binary(image))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    :persistent_term.put(@key, image |> Map.put(:version, version) |> Map.put(:sources, sources))

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
  defp source_fingerprints do
    # The ROOTS here are the plural ones, and that is the whole point of this function's warning:
    # reading only the business root would leave the system catalogue's prompt material outside the
    # fingerprint — editable under a live daemon with nobody told.
    [
      {modop_roots(), "*/sp.md"},
      {subagent_roots(), "subagent-*.md"},
      {drafts_roots(), "agent-*-base.md"},
      {template_roots(), "*.eex"}
    ]
    |> Enum.flat_map(fn {roots, glob} ->
      Enum.flat_map(roots, &(&1 |> Path.join(glob) |> Path.wildcard()))
    end)
    |> Enum.concat([worker_protocol_path(), human_protocol_path()])
    |> Enum.uniq()
    |> Map.new(fn path -> {path, path |> File.read!() |> sha_of()} end)
  end

  defp sha_of(content), do: :crypto.hash(:sha256, content)

  @doc "The published image or nil (fallback-to-disk regime)."
  @spec published() :: map() | nil
  def published, do: :persistent_term.get(@key, nil)

  @doc "Erases the published image — TESTS ONLY."
  @spec unpublish() :: :ok
  def unpublish do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The role's SP draft from the published image (`{:ok, content}`), `:not_found` if the image is
  published but carries no draft for `role` (closed world), `:unpublished` otherwise (the
  caller falls back to disk). Consulted by the spawner's Assets rail.
  """
  @spec draft(String.t()) :: {:ok, binary()} | :not_found | :unpublished
  def draft(role) when is_binary(role) do
    case published() do
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
  def worker_protocol do
    case published() do
      %{worker_protocol: content} -> {:ok, content}
      nil -> :unpublished
    end
  end

  @doc """
  The conversation contract added for a human interlocutor (`{:ok, content}`) or `:unpublished`.
  """
  @spec human_protocol() :: {:ok, binary()} | :unpublished
  def human_protocol do
    case published() do
      %{human_protocol: content} -> {:ok, content}
      nil -> :unpublished
    end
  end

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

  defp read_worker_protocol!, do: read_protocol!(worker_protocol_path(), "worker protocol")

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
  defp worker_protocol_path do
    Application.get_env(:fleet_spawner, :protocole_user_path) ||
      Fleet.Catalogue.find(
        drafts_root(),
        Fleet.Catalogue.rel(:sp_drafts),
        "protocole-user-worker.md"
      )
  end

  # No override knob, DELIBERATELY: the machine protocol has one because a deployment may need to
  # re-cut the work-item contract, whereas the operator-facing half is meant to be replaced by the
  # operator's own file through the deploy's override scheme, not by a runtime config path. Adding
  # a second knob now would be inventing the mechanism twice before either exists.
  defp human_protocol_path,
    do:
      Fleet.Catalogue.find(
        drafts_root(),
        Fleet.Catalogue.rel(:sp_drafts),
        "protocole-user-human.md"
      )

  # The SAME roots the disk fallback reads (SPBuilder modop_root/subagent_template_root). The drafts
  # root is NOT resolved here: it has a reader in ANOTHER domain (`Spawner.Pod.Assets`, the
  # unpublished path), so it lives on the facade as the single authority — see `drafts_root/0` below.
  defp modop_root do
    Application.get_env(:fleet_sp_builder, :modop_root) || Fleet.Catalogue.modop_root()
  end

  defp subagent_root do
    Application.get_env(:fleet_sp_builder, :subagent_template_root) ||
      Fleet.Catalogue.subagent_templates_root()
  end

  # Single authority on the facade — the image and the spawn's disk fallback MUST read one root.
  defp drafts_root, do: Fleet.SPBuilder.sp_drafts_root()

  # THE search path, resolved by `Fleet.Catalogue` like every other reader. A fine override moves
  # the business root only; the system root is never dropped, and an absent directory is — which is
  # what lets the system catalogue ship only what its roles need (it has no subagent template and
  # must not fake one).
  defp modop_roots, do: Fleet.Catalogue.search(modop_root(), Fleet.Catalogue.rel(:modops))

  defp subagent_roots,
    do: Fleet.Catalogue.search(subagent_root(), Fleet.Catalogue.rel(:subagent_templates))

  defp drafts_roots, do: Fleet.Catalogue.search(drafts_root(), Fleet.Catalogue.rel(:sp_drafts))

  # Two of the three readers that never learned the search path, and were defects for it: the EEx
  # templates shape the MECHANISM's prompts, and the human protocol was demanded from catalogues
  # that have no human-facing role at all (W-13). They go through the same door as the rest. The
  # third was `sp_role_bases`, and it is gone rather than fixed — see the publish above.
  defp template_roots,
    do: Fleet.Catalogue.search(template_root(), Fleet.Catalogue.rel(:sp_templates))

  defp template_root, do: Fleet.Catalogue.sp_templates_root()
end

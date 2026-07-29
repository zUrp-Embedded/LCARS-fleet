defmodule Fleet.SPBuilder.Image do
  @moduledoc """
  The PROVEN-GOOD SP-artifact image — EVERY piece of sp_builder-side prompt material frozen at boot
  into one versioned snapshot (the cap-profile half lives in `Fleet.CapProfile.Image`). The full
  content, because a snapshot that under-describes itself is the drift it exists to prevent:

    * `modop_sp` — modop SP fragments (`<modop>/sp.md`)
    * `subagent` — subagent templates
    * `drafts` — per-role SP drafts (`agent-<role>-base.md`)
    * `worker_protocol` — the pod's `protocole-user.md`, resolved through the consumer's own
      `:protocole_user_path` override so a deployment override cannot escape the epoch
    * `sp_role_bases` — role SP bases a profile's `spec.systemPrompt` names, keyed by path
      RELATIVE to the SP root (the only OPTIONAL section: a dormant extension point, cf. `publish!/0`)
    * `templates` — the EEx template SOURCES, rendered with `eval_string`

  Same contract: `publish!/0` enumerates + reads every artifact at boot (an unreadable or empty one
  raises — proven-good or do not boot) and publishes to `:persistent_term`; the composer
  (`Fleet.SPBuilder`) and the spawner's Assets rail consume the image when published — a disk
  mutation mid-life no longer changes the prompts pods receive, spawn by spawn.

  Under a PUBLISHED image a missing entry is a CLOSED-WORLD error, never a silent re-read of the
  live file: that fallback is what reopened the epoch exactly where a deployment had extended the
  fleet. Only the absence of an image (tests' hermetic default, tooling) falls back to disk.

  **Last revised**: 2026-07-29
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
        read_dir_map!(modop_root(), "*/sp.md", &(&1 |> Path.dirname() |> Path.basename())),
      subagent:
        read_dir_map!(
          subagent_root(),
          "subagent-*.md",
          &(&1 |> Path.basename(".md") |> String.replace_prefix("subagent-", ""))
        ),
      drafts:
        read_dir_map!(
          drafts_root(),
          "agent-*-base.md",
          &(&1
            |> Path.basename(".md")
            |> String.replace_prefix("agent-", "")
            |> String.replace_suffix("-base", ""))
        ),
      worker_protocol: read_worker_protocol!(),
      # The role SP bases a cap-profile's `spec.systemPrompt` names, keyed by path RELATIVE to the
      # SP root — the composer joins that same relative path, so the key is the lookup. Imaged
      # because it is prompt material like any other: left on a live read, two pods of one
      # deployment could receive different role bases under one image version.
      # OPTIONAL by measurement, not by convenience: no cap-profile of the canon declares
      # `spec.systemPrompt` today (grep: zero), and the root ships no `.md` — the leg is a dormant
      # EXTENSION POINT. So an empty match is legitimate here and must not raise, unlike the material
      # the fleet always needs (an empty modop/draft/template root IS a broken deploy). A deployment
      # that DOES ship role bases gets them frozen; an empty map still closes the world, because a
      # profile naming a base the image lacks now fails loud instead of silently reading the live file.
      sp_role_bases:
        read_dir_map(sp_role_root(), "**/*.md", &Path.relative_to(&1, sp_role_root())),
      # The two EEx templates, frozen as SOURCE (rendered with eval_string against the image). A
      # template is the SHAPE of every prompt the fleet emits — the last thing that may drift
      # mid-life while the version claims otherwise.
      templates: read_dir_map!(template_root(), "*.eex", &Path.basename(&1))
    }

    version =
      :crypto.hash(:sha256, :erlang.term_to_binary(image))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    :persistent_term.put(@key, Map.put(image, :version, version))

    # Every section counted: the line an operator reads to know WHAT the version covers. A section
    # published but unnamed here is a piece of the epoch nobody can see was frozen.
    Logger.info(
      "SPBuilder.Image: published (#{map_size(image.modop_sp)} modop fragments, " <>
        "#{map_size(image.subagent)} subagent templates, #{map_size(image.drafts)} drafts, " <>
        "#{map_size(image.sp_role_bases)} role SP bases, #{map_size(image.templates)} EEx templates, " <>
        "worker protocol frozen, version=#{version})"
    )

    :ok
  end

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
  A role SP base by its path RELATIVE to the SP root: `{:ok, content}`, `:not_found` (image
  published, closed world — the catalogue names a base the deploy does not ship), or `:unpublished`.
  """
  @spec sp_role_base(Path.t()) :: {:ok, binary()} | :not_found | :unpublished
  def sp_role_base(rel_path) when is_binary(rel_path) do
    lookup(:sp_role_bases, rel_path)
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

  defp read_dir_map!(root, glob, key_fun) do
    if Path.wildcard(Path.join(root, glob)) == [] do
      raise "SPBuilder.Image: no artifact matches #{glob} under #{root} — " <>
              "proven-good image at boot, or do not boot (broken deploy?)"
    end

    read_dir_map(root, glob, key_fun)
  end

  # Same read, WITHOUT the non-empty-directory requirement — for a root whose emptiness is a valid
  # deployment shape. A truncated FILE still raises either way: an empty artifact is a broken deploy
  # whatever the root, and that check is the one this image exists for.
  defp read_dir_map(root, glob, key_fun) do
    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Map.new(fn path ->
      content = File.read!(path)

      if content == "" do
        raise "SPBuilder.Image: artifact #{path} is empty — proven-good image requires " <>
                "non-empty artifacts (truncated file in deploy?)"
      end

      {key_fun.(path), content}
    end)
  end

  defp read_worker_protocol! do
    content = File.read!(worker_protocol_path())

    if content == "" do
      raise "SPBuilder.Image: worker protocol is empty — proven-good image requires non-empty artifacts"
    end

    content
  end

  # SAME resolution as `Pod.Assets.read_protocole_user/0` (override first, bundled worker default
  # otherwise) — the image must freeze what the consumer would have read, or it freezes the wrong
  # file and the override silently escapes the epoch. Reading another domain's config ATOM creates
  # no module edge (the `:fleet_<dom>` atoms are legacy-valid, D-07); the alternative was a second
  # resolution of the same asset, one edit away from diverging with no gate to catch it.
  defp worker_protocol_path do
    Application.get_env(:fleet_spawner, :protocole_user_path) ||
      Path.join(drafts_root(), "protocole-user-worker.md")
  end

  # The SAME roots the disk fallback reads (SPBuilder modop_root/subagent_template_root; the
  # drafts root gains its knob here — Assets' app_dir literal stays its fallback).
  defp modop_root do
    Application.get_env(:fleet_sp_builder, :modop_root) ||
      Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/modop-bundles")
  end

  defp subagent_root do
    Application.get_env(:fleet_sp_builder, :subagent_template_root) ||
      Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/subagent-templates")
  end

  defp drafts_root do
    Application.get_env(:fleet_sp_builder, :sp_drafts_root) ||
      Application.app_dir(:lcars_fleet, "priv/sp_builder/sp_drafts")
  end

  # SAME roots the composer's disk fallback reads (`SPBuilder.sp_role_root/0` and its template path)
  # — one resolution per asset, mirrored here, for the reason above.
  defp sp_role_root do
    Application.get_env(:fleet_sp_builder, :sp_role_root) ||
      Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/cap-profiles")
  end

  defp template_root,
    do: Path.join([to_string(:code.priv_dir(:lcars_fleet)), "sp_builder/templates"])
end

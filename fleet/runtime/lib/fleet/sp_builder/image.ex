defmodule Fleet.SPBuilder.Image do
  @moduledoc """
  The PROVEN-GOOD SP-artifact image — modop SP fragments, subagent templates, role drafts and
  the worker protocol frozen at boot into one versioned snapshot (the sp_builder half of the
  image doctrine; the cap-profile half lives in `Fleet.CapProfile.Image`).

  Same contract: `publish!/0` enumerates + reads every artifact at boot (an unreadable one
  raises — proven-good or do not boot) and publishes to `:persistent_term`; the composer
  (`Fleet.SPBuilder`) and the spawner's Assets rail consume the image when published — a disk
  mutation mid-life no longer changes the prompts pods receive, spawn by spawn. No image
  (tests' hermetic default, tooling) → live-disk fallback, unchanged.

  **Last revised**: 2026-07-23
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
      worker_protocol: read_worker_protocol!()
    }

    version =
      :crypto.hash(:sha256, :erlang.term_to_binary(image))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    :persistent_term.put(@key, Map.put(image, :version, version))

    Logger.info(
      "SPBuilder.Image: published (#{map_size(image.modop_sp)} modop fragments, " <>
        "#{map_size(image.subagent)} templates, #{map_size(image.drafts)} drafts, " <>
        "version=#{version})"
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

  defp read_dir_map!(root, glob, key_fun) do
    files = Path.wildcard(Path.join(root, glob))

    if files == [] do
      raise "SPBuilder.Image: no artifact matches #{glob} under #{root} — " <>
              "proven-good image at boot, or do not boot (broken deploy?)"
    end

    Map.new(files, fn path ->
      content = File.read!(path)

      if content == "" do
        raise "SPBuilder.Image: artifact #{path} is empty — proven-good image requires " <>
                "non-empty artifacts (truncated file in deploy?)"
      end

      {key_fun.(path), content}
    end)
  end

  defp read_worker_protocol! do
    content = File.read!(Path.join(drafts_root(), "protocole-user-worker.md"))

    if content == "" do
      raise "SPBuilder.Image: worker protocol is empty — proven-good image requires non-empty artifacts"
    end

    content
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
end

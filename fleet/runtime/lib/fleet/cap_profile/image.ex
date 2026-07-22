defmodule Fleet.CapProfile.Image do
  @moduledoc """
  The PROVEN-GOOD cap-profile image — profiles + modop overlays frozen at boot into one
  versioned snapshot the whole runtime consumes.

  ## Doctrine (images audit, tier B)

  > proven-good image at boot, or do not boot.

  Tier A (CanonProof) proves every canon role composes before readiness but leaves consumption
  on the LIVE disk: a catalogue mutated mid-life still changed the pods spawn by spawn (the
  epoch was closed per-resolve, not per-deployment). This module closes the epoch at the
  DEPLOYMENT scale: `publish!/0` loads and validates EVERY profile and EVERY modop overlay at
  boot — any invalid artifact raises (crash-boot, same posture as the event registry) — then
  publishes the snapshot to `:persistent_term`. `Catalog.read_role/1` and `Catalog.read_modops/1`
  consume the image when published (the CLOSED world: a role absent from the image is
  `:not_found`, whatever the disk now says); the disk path remains the fallback when no image is
  published (tests' hermetic default, standalone tooling). A new image requires a restart —
  exactly the doctrine.

  The truly-dynamic calibration assets stay OUT of the image by design (cf. the SP split).

  **Last revised**: 2026-07-22
  """

  require Logger

  alias Fleet.CapProfile.{Catalog, Schema}

  @key {__MODULE__, :image}

  @doc """
  Builds, validates and publishes the image from the live catalogue roots. Raises on ANY
  invalid artifact — a broken catalogue must not boot (proven-good or nothing). Idempotent
  (re-publish replaces the snapshot). Gated by the caller (`:fleet_cap_profile, :publish_image`).
  """
  @spec publish!() :: :ok
  def publish! do
    index =
      case Catalog.snapshot_roles() do
        {:ok, index} ->
          index

        {:error, reason} ->
          raise "CapProfile.Image: catalogue unreadable (#{inspect(reason)}) — " <>
                  "proven-good image required at boot, refusing to publish"
      end

    Enum.each(index, fn {role, raw} ->
      case Schema.validate(raw, :cap_profile) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "CapProfile.Image: profile #{role} INVALID (#{inspect(reason)}) — " <>
                  "proven-good image at boot, or do not boot"
      end
    end)

    overlays =
      case Catalog.snapshot_overlays() do
        {:ok, overlays} ->
          overlays

        {:error, reason} ->
          raise "CapProfile.Image: modop overlays unreadable (#{inspect(reason)}) — " <>
                  "proven-good image at boot, or do not boot"
      end

    version = version_of(index, overlays)
    :persistent_term.put(@key, %{index: index, overlays: overlays, version: version})

    Logger.info(
      "CapProfile.Image: published (#{map_size(index)} profiles, #{map_size(overlays)} " <>
        "overlays, version=#{version})"
    )

    :ok
  end

  @doc "The published image (`%{index, overlays, version}`) or nil (fallback-to-disk regime)."
  @spec published() :: map() | nil
  def published, do: :persistent_term.get(@key, nil)

  @doc "Erases the published image — TESTS ONLY (returns the runtime to the disk regime)."
  @spec unpublish() :: :ok
  def unpublish do
    _ = :persistent_term.erase(@key)
    :ok
  end

  # Deterministic content stamp: the image is versioned so two epochs are distinguishable in logs.
  defp version_of(index, overlays) do
    :crypto.hash(:sha256, :erlang.term_to_binary({Enum.sort(index), Enum.sort(overlays)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end

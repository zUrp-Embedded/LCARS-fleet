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
  """

  require Logger

  alias Fleet.CapProfile.{Catalog, Schema}

  @key {__MODULE__, :image}

  @doc """
  Validates and publishes the live catalogue, replacing any previous image.
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
      # Branch on kind (BL-6-45): a ReservedSeat is validated against ITS schema — every entry
      # is proven at boot, none rots unvalidated behind its exclusion from the spawnable world.
      # Three exits, the third a raise: an unknown kind is a broken deploy artifact, refused
      # loud here rather than mis-validated against whichever schema a default would pick.
      schema_kind =
        case Map.get(raw, "kind") do
          "CapabilityProfile" ->
            :cap_profile

          "ReservedSeat" ->
            :reserved_seat

          other ->
            raise "CapProfile.Image: entry #{role} declares unknown kind #{inspect(other)} — " <>
                    "proven-good image at boot, or do not boot"
        end

      case Schema.validate(raw, schema_kind) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "CapProfile.Image: profile #{role} INVALID (#{inspect(reason)}) — " <>
                  "proven-good image at boot, or do not boot"
      end
    end)

    ensure_role_indexes_unique!(index)

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

    # Reserved seats named ONCE, loud, at the publish (BL-6-45): the state "declared but not
    # spawnable" is voiced here instead of surfacing as a confusing :not_found downstream.
    seats = for {name, raw} <- index, not Catalog.spawnable?(raw), do: name

    seats_note =
      case seats do
        [] -> ""
        _ -> ", #{length(seats)} reserved seat(s): #{Enum.join(Enum.sort(seats), ", ")}"
      end

    Logger.info(
      "CapProfile.Image: published (#{map_size(index) - length(seats)} profiles, " <>
        "#{map_size(overlays)} overlays#{seats_note}, version=#{version})"
    )

    :ok
  end

  # `role_index` is the role's slot in the hexspeak session UUID, so two entries sharing one slot
  # make `pkill -f '<X>badcafe'` reach two kill classes at once. Nothing held that uniqueness where
  # it now lives: the schema bounds the value per FILE (0..15), and the repo contract check proves
  # it per catalogue ROOT — neither can see the union. Since the search path let a business
  # catalogue superpose the system one, the perimeter of uniqueness became the MERGED index, and
  # this function is the only place that holds it. Measured cost of its absence: `dev` and
  # `gatekeeper` shipped on slot 2 together and the bench stayed green, because their `kill_class`
  # happened to differ. Luck is not a guard.
  #
  # Seats included — a ReservedSeat CLAIMS its slot exactly like a spawnable role. Entries whose
  # `role_index` is not an integer are skipped rather than refused: the schema above is the
  # authority on presence, and duplicating its refusal here would report the wrong fault.
  defp ensure_role_indexes_unique!(index) do
    duplicates =
      index
      |> Enum.flat_map(fn {name, raw} ->
        case get_in(raw, ["metadata", "role_index"]) do
          slot when is_integer(slot) -> [{slot, name}]
          _ -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_slot, names} -> length(names) > 1 end)
      |> Enum.sort()

    unless duplicates == [] do
      detail =
        Enum.map_join(duplicates, "; ", fn {slot, names} ->
          "role_index #{slot} claimed by #{Enum.join(Enum.sort(names), ", ")}"
        end)

      raise "CapProfile.Image: #{detail} — a slot is a kill class, and two roles sharing one " <>
              "make `pkill` reach both. This is checked on the MERGED catalogue, so an entry " <>
              "superposing a system one by NAME is fine (one entry, one slot); two DIFFERENT " <>
              "names on one slot are not. Reassign one (0..15). Proven-good image at boot, or " <>
              "do not boot."
    end

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

  @doc """
  Restores a previously-`published/0` image — TESTS ONLY, the symmetric of `unpublish/0`.

  Exists because unpublishing has no natural undo and a test that omits one leaks the DISK regime
  into every test after it: same read, different path, and a whole run's timing changes under it.
  `publish!/0` is not that undo — it rebuilds from the catalogue currently configured, which a test
  that repointed `root_dir` no longer has.
  """
  @spec republish(map()) :: :ok
  def republish(%{} = image) do
    :persistent_term.put(@key, image)
    :ok
  end

  # Deterministic content stamp: the image is versioned so two epochs are distinguishable in logs.
  defp version_of(index, overlays) do
    :crypto.hash(:sha256, :erlang.term_to_binary({Enum.sort(index), Enum.sort(overlays)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end

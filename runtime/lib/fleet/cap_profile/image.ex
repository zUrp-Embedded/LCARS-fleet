defmodule Fleet.CapProfile.Image do
  @moduledoc """
  Publishes structurally validated profile/overlay snapshots in persistent_term, one per
  installed catalogue over its system fallback. Catalog reads use the published snapshot
  exclusively; disk edits take effect only after republishing or removing that image.
  Publication normally occurs at boot, but the API itself permits replacement without restart.

  This checks schemas and merged role-index uniqueness, not composed semantic invariants.
  CanonProof and the pod spawn gate check composed profiles. Dynamic calibration assets
  are outside this image.
  """

  require Logger

  alias Fleet.CapProfile.{Catalog, Schema}

  @doc """
  Validates and publishes each non-empty installed catalogue scope, replacing its image.
  Invalid artifacts raise before that scope is stored. Scopes publish sequentially, not
  transactionally: earlier publications and old images can remain after a later failure.
  Images for roots no longer installed are not erased here.
  """
  @spec publish!() :: :ok
  def publish! do
    # Keep neighbours separate and key by catalogue root, matching profile/SP image provenance.
    for root <- Fleet.Catalogue.installed_roots(),
        scope = Fleet.Catalogue.tree_scope(root, :cap_profiles),
        scope != [],
        do: publish_scope!(root, scope)

    :ok
  end

  # Seats need their own schema; unknown kinds must not silently select the profile schema.
  # Schema-valid disallowedTools can still fail G24: semantic checks need the composed profile.
  defp validate_entry!({role, raw}) do
    case Schema.validate(raw, schema_kind!(role, Map.get(raw, "kind"))) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "CapProfile.Image: profile #{role} INVALID (#{inspect(reason)}) — " <>
                "proven-good image at boot, or do not boot"
    end
  end

  defp schema_kind!(_role, "CapabilityProfile"), do: :cap_profile
  defp schema_kind!(_role, "ReservedSeat"), do: :reserved_seat

  defp schema_kind!(role, other) do
    raise "CapProfile.Image: entry #{role} declares unknown kind #{inspect(other)} — " <>
            "proven-good image at boot, or do not boot"
  end

  defp publish_scope!(root, scope) do
    index =
      case Catalog.snapshot_roles(scope) do
        {:ok, index} ->
          index

        {:error, reason} ->
          raise "CapProfile.Image: catalogue unreadable (#{inspect(reason)}) — " <>
                  "proven-good image required at boot, refusing to publish"
      end

    Enum.each(index, &validate_entry!/1)

    ensure_role_indexes_unique!(index, root)

    overlays =
      case Catalog.snapshot_overlays(scope) do
        {:ok, overlays} ->
          overlays

        {:error, reason} ->
          raise "CapProfile.Image: modop overlays unreadable (#{inspect(reason)}) — " <>
                  "proven-good image at boot, or do not boot"
      end

    version = version_of(index, overlays)

    :persistent_term.put(image_key(root), %{
      index: index,
      overlays: overlays,
      version: version
    })

    # Expose declared but unspawnable seats at publication.
    seats = for {name, raw} <- index, not Catalog.spawnable?(raw), do: name

    seats_note =
      case seats do
        [] -> ""
        _ -> ", #{length(seats)} reserved seat(s): #{Enum.join(Enum.sort(seats), ", ")}"
      end

    Logger.info(
      "CapProfile.Image: published #{root} (#{map_size(index) - length(seats)} profiles, " <>
        "#{map_size(overlays)} overlays#{seats_note}, version=#{version})"
    )

    :ok
  end

  # Enforce role-index uniqueness after overlays by name, including seats: per-file bounds
  # and per-root checks cannot detect cross-root claims. Schema handles missing/noninteger values.
  # Role index and kill class occupy different session-ID nibbles; sharing an index risks
  # identity/role-pattern ambiguity, not a change to the independently derived kill class.
  defp ensure_role_indexes_unique!(index, business) do
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

      raise "CapProfile.Image: #{business}: #{detail} — a slot is a kill class, and two roles " <>
              "sharing one make `pkill` reach both. This is checked PER CATALOGUE (its own " <>
              "profiles over the system's), so an entry " <>
              "superposing a system one by NAME is fine (one entry, one slot); two DIFFERENT " <>
              "names on one slot are not. Reassign one (0..15). Proven-good image at boot, or " <>
              "do not boot."
    end

    :ok
  end

  @doc """
  Returns `%{index, overlays, version}` or nil (disk fallback).
  No argument uses `Fleet.Catalogue.root/0`; `published/1` reads an explicit catalogue root.
  """
  @spec published() :: map() | nil
  def published do
    published(Fleet.Catalogue.root())
  end

  @spec published(Path.t()) :: map() | nil
  def published(root) when is_binary(root), do: :persistent_term.get(image_key(root), nil)

  @doc "Erases every published image — TESTS ONLY (returns the runtime to the disk regime)."
  @spec unpublish() :: :ok
  def unpublish do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, :image, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp image_key(root), do: {__MODULE__, :image, root}

  @doc """
  Test helper: stores a saved image at the currently configured default catalogue root,
  without validation. Restore the root first if it changed. This restores one image only;
  `unpublish/0` erases all roots. Calling `publish!/0` instead would reread mutated disk data.
  """
  @spec republish(map()) :: :ok
  def republish(%{} = image) do
    :persistent_term.put(image_key(Fleet.Catalogue.root()), image)
    :ok
  end

  # 48-bit log stamp, not a durable identity or collision-free key. Top-level entries are
  # sorted explicitly; nested encoding depends on OTP's term format, not canonical JSON.
  defp version_of(index, overlays) do
    :crypto.hash(:sha256, :erlang.term_to_binary({Enum.sort(index), Enum.sort(overlays)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end

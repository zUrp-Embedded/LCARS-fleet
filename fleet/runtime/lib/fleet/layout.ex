defmodule Fleet.Layout do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: []

  @moduledoc """
  The single authority for the LCARS platform layout — "where things live" on the box.

  ## Why these paths are fixed, not configurable

  LCARS runs ALONE in a dedicated container (docker/WSL), never installed on a user's
  workstation. The layout is imposed by design (BSD philosophy: we impose OUR own clean
  tree, we do not adapt to the surrounding mess): `/home/projects` (the working repos),
  `/home/projects.work` (the meta: journals, seeds, ops), `~/.lcars` (the per-human runtime
  state — each human is created with their home at register/onboarding). **These are NOT
  deployment knobs**: a config file for paths that must never vary would be an API lie
  (over-parametrizing the structural is a mistake). Structural → hardcoded, but typed in ONE
  place: this module is the sole origin of these roots, so they are never re-hardcoded or
  recomposed anywhere else.

  Consumer TEST seams (e.g. `seed_store_root`) stay: their DEFAULT derives from here.

  Foundation (next to `Fleet.Slug`): anything may depend down onto it.
  """

  @projects_root "/home/projects"
  @work_root "/home/projects.work"
  @state_dirname ".lcars"

  @doc "Root of the working repos (`/home/projects`) — imposed container layout."
  @spec projects_root() :: Path.t()
  def projects_root, do: @projects_root

  @doc "Meta/ops root (`/home/projects.work`) — journals, seeds, resume folders."
  @spec work_root() :: Path.t()
  def work_root, do: @work_root

  @doc """
  Per-human runtime state (`~/.lcars`). An unresolvable HOME means a broken runtime →
  fail-loud (`System.user_home!/0` raises), never a fabricated path: the state must not
  silently scatter.
  """
  @spec state_dir() :: Path.t()
  def state_dir, do: Path.join(System.user_home!(), @state_dirname)
end

defmodule Fleet.Layout do
  @moduledoc """
  Autorité UNIQUE du layout plateforme LCARS — « où vivent les choses » sur la boîte.

  ## Doctrine (H1+H3 2026-07-04, décision user)

  LCARS vit SEUL dans un container dédié (docker/WSL), jamais installé sur un poste user. Le
  layout est IMPOSÉ par conception (philosophie BSD : on impose NOTRE arborescence propre, on ne
  s'adapte pas au bazar ambiant) : `/home/projects` (les repos de travail), `/home/projects.work`
  (le méta : journaux, seeds, ops), `~/.lcars` (l'état runtime per-humain — chaque humain est créé
  au register/onboarding avec son home). **Ce ne sont PAS des knobs de déploiement** : un fichier
  de config pour des paths qui ne doivent jamais varier serait un mensonge d'API (doctrine
  ponçage §4 : « sur-paramétriser le structurel = faute »). Structurel → en dur, MAIS tapé UNE
  fois : avant ce module, la racine projets vivait en attribut dans 3 modules (2 non-configurables
  + 1 défaut config) et le préfixe `.lcars` était recomposé dans 3 apps.

  Les seams de TEST des consommateurs (ex. `seed_store_root`) restent : leur DÉFAUT dérive d'ici.

  Ring 0 (fleet_cap_profile, à côté de `Fleet.Slug`) : tout le monde peut descendre dessus.
  """

  @projects_root "/home/projects"
  @work_root "/home/projects.work"
  @state_dirname ".lcars"

  @doc "Racine des repos de travail (`/home/projects`) — layout container imposé."
  @spec projects_root() :: Path.t()
  def projects_root, do: @projects_root

  @doc "Racine méta/ops (`/home/projects.work`) — journaux, seeds, dossiers de reprise."
  @spec work_root() :: Path.t()
  def work_root, do: @work_root

  @doc """
  État runtime per-humain (`~/.lcars`). HOME irrésoluble = runtime cassé → fail-loud
  (`System.user_home!/0` raise), jamais un chemin fabriqué : l'état ne doit pas se disperser
  en silence. (Ce commentaire vivait copié dans 3 apps — il vit ICI désormais.)
  """
  @spec state_dir() :: Path.t()
  def state_dir, do: Path.join(System.user_home!(), @state_dirname)
end

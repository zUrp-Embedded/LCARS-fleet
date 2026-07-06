defmodule Fleet.Pilot.Labels do
  @moduledoc """
  Vocabulaire de labels du **wire-protocol** forge-state-machine : la forge EST la machine à états,
  ces labels sont son fil. SOURCE UNIQUE.

  Ces constantes NE SONT PAS de la config : elles SONT le protocole. Le poller, le dispatcher,
  le completer et le consumer doivent s'accorder au byte près — un verrou `lcars-in-flight` posé
  par l'un n'est levé par l'autre que s'ils nomment le MÊME label. Les re-déclarer en `@attr` par
  module = dérive silencieuse à un renommage. Centralisé ici, consommé partout.

  Usage compile-time (préserve la sémantique de constante, utilisable en `cond`/pattern) :

      @in_flight_label Fleet.Pilot.Labels.in_flight()

  ou runtime direct (`Fleet.Pilot.Labels.awaits_arch()`).

  Deux familles : les VERROUS PLATS `lcars-in-flight` / `lcars-awaits-arch` (concurrence / escalade,
  non-scopés), et la POSITION workflow_map en labels SCOPÉS `wfmap/<map>` + `stage/<step>` (WS2 : l'état
  vit dans le label, mutex natif Gitea `exclusive:true` — plus dans un commentaire route). `lcars-dispatched`
  (lock d'un poller legacy) a été retiré. Hors de ces familles, un label n'existe pas.
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"

  @doc "Verrou « pod en vol » : posé AVANT le spawn (anti double-spawn), levé en fin-de-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "Verrou HUMAIN : l'issue attend une action via l'arch (verdict escalate/halt/redirect)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch

  # --- Position workflow_map (WS2) : 2 scopes de labels mutex (via `exclusive:true`, posé par
  # ForgeClient.ensure_org_label). `wfmap/<map>` = QUELLE map (donnée, par-issue → multi-map) ;
  # `stage/<step>` = l'étape COURANTE, mobile. Valeurs brief-review/build issues du MAP (donnée) ;
  # review/merged = phases du LIFECYCLE PR (mécanisme post-map, humain-seul : la machine ne relit pas
  # get_route sur une issue en review [PR-backed → skip] ni mergée [fermée]).
  @stage_prefix "stage/"
  @wfmap_prefix "wfmap/"
  @stage_review "review"
  @stage_merged "merged"

  @doc "Préfixe scopé de l'étape courante (`stage/`). Scopé → exclusive (mutex)."
  @spec stage_prefix() :: String.t()
  def stage_prefix, do: @stage_prefix

  @doc "Préfixe scopé de la map suivie (`wfmap/`)."
  @spec wfmap_prefix() :: String.t()
  def wfmap_prefix, do: @wfmap_prefix

  @doc "Étape LIFECYCLE PR : l'issue entre en review (deliverable PR ouverte). Mécanisme, pas un step de map."
  @spec stage_review() :: String.t()
  def stage_review, do: @stage_review

  @doc "Étape LIFECYCLE PR : la brique est mergée (terminal). Mécanisme, pas un step de map."
  @spec stage_merged() :: String.t()
  def stage_merged, do: @stage_merged
end

defmodule Fleet.Pilot.Labels do
  @moduledoc """
  Vocabulaire de labels du **wire-protocol** forge-state-machine (DN `orchestration/
  forge-state-machine.md` §5). SOURCE UNIQUE (F072).

  Ces constantes NE SONT PAS de la config : elles SONT le protocole. Le poller, le dispatcher,
  le completer et le consumer doivent s'accorder au byte près — un verrou `lcars-in-flight` posé
  par l'un n'est levé par l'autre que s'ils nomment le MÊME label. Les re-déclarer en `@attr` par
  module (ce qu'on faisait) = dérive silencieuse à un renommage. Centralisé ici, consommé partout.

  Usage compile-time (préserve la sémantique de constante, utilisable en `cond`/pattern) :

      @in_flight_label Fleet.Pilot.Labels.in_flight()

  ou runtime direct (`Fleet.Pilot.Labels.delivered()`).
  """

  @in_flight "lcars-in-flight"
  @awaits_human "lcars-awaits-human"
  @dispatched "lcars-dispatched"
  @state_prefix "state:"

  @doc "Verrou « pod en vol » : posé AVANT le spawn (anti double-spawn), levé en fin-de-hop (§5)."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "Verrou HUMAIN : l'issue attend une action via l'arch (verdict escalate/halt/redirect, A2.3b)."
  @spec awaits_human() :: String.t()
  def awaits_human, do: @awaits_human

  @doc "Lock de catch-up du poller legacy (route → pipeline) : `lcars-dispatched`."
  @spec dispatched() :: String.t()
  def dispatched, do: @dispatched

  @doc "Préfixe des labels d'état `state:*` (un seul actif à la fois ; transition = DELETE+PUT, §5)."
  @spec state_prefix() :: String.t()
  def state_prefix, do: @state_prefix

  @doc "Construit un label d'état `state:<name>`."
  @spec state(String.t()) :: String.t()
  def state(name) when is_binary(name), do: @state_prefix <> name

  @doc "État `state:delivered` (défaut de fin-de-hop : livrable poussé)."
  @spec delivered() :: String.t()
  def delivered, do: @state_prefix <> "delivered"
end

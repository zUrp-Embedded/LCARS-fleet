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

  ou runtime direct (`Fleet.Pilot.Labels.awaits_human()`).

  #5.2 D4 — `lcars-dispatched` (lock du poller legacy, mort) ET la chaîne `state:*` (état-dans-label,
  contredit « état = route-comment » ; lue seulement par le `routing.ex` legacy supprimé) ont été retirés.
  Les VERROUS restent : `lcars-in-flight`, `lcars-awaits-human`.
  """

  @in_flight "lcars-in-flight"
  @awaits_human "lcars-awaits-human"

  @doc "Verrou « pod en vol » : posé AVANT le spawn (anti double-spawn), levé en fin-de-hop (§5)."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "Verrou HUMAIN : l'issue attend une action via l'arch (verdict escalate/halt/redirect, A2.3b)."
  @spec awaits_human() :: String.t()
  def awaits_human, do: @awaits_human
end

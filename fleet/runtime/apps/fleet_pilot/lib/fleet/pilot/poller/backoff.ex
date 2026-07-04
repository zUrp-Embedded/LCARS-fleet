defmodule Fleet.Pilot.Poller.Backoff do
  @moduledoc """
  Timing du poller (extrait de `Fleet.Pilot.Poller`) : jitter anti thundering-herd +
  backoff exponentiel capé. Calcul PUR (modulo `:rand` pour le jitter) — aucun seam,
  aucun état : le GenServer garde l'EFFET (`Process.send_after`) et le rescue de boucle
  (`safe_poll`), ce module ne rend que le DÉLAI.

  ## Pourquoi ces deux mécanismes (port v1.5 `LcarsFleetPoller`, conservé)

    * **Jitter ±10 %** — N daemons qui redémarrent ensemble ne doivent pas marteler la
      forge en phase (anti thundering-herd). Plancher 1 s (jamais de délai nul/négatif).
    * **Backoff exponentiel** sur erreurs (×2 par tick en échec, capé à 5 min) — la
      forge down n'inonde ni les logs ni l'API. Le streak vient du state du poller
      (erreurs de LISTE, mais aussi erreurs de DISPATCH per-item : backoff partiel).
  """

  # Cap du backoff : la forge down ne pousse jamais l'attente au-delà de 5 min
  # (au retour de la forge, on re-poll vite).
  @max_backoff_ms 300_000
  # Amplitude du jitter (±10 % de l'interval).
  @jitter_ratio 0.1

  @doc """
  Délai du prochain tick : interval nominal jitté si le streak d'erreurs est nul,
  sinon backoff exponentiel `base × 2^min(streak, 10)` capé à #{@max_backoff_ms} ms,
  puis jitté.
  """
  @spec next_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  def next_delay(0, base_ms), do: jitter(base_ms)

  def next_delay(streak, base_ms) when is_integer(streak) and streak > 0 do
    factor = :math.pow(2, min(streak, 10)) |> trunc()
    delay = min(base_ms * factor, @max_backoff_ms)
    jitter(delay)
  end

  @doc """
  Jitter ±#{trunc(@jitter_ratio * 100)} % autour de `ms`, plancher 1 s (un délai jitté
  ne descend jamais sous 1 000 ms — pas de busy-poll accidentel sur petit interval).
  """
  @spec jitter(pos_integer()) :: pos_integer()
  def jitter(ms) when is_integer(ms) and ms > 0 do
    delta = trunc(ms * @jitter_ratio)
    offset = :rand.uniform(2 * delta + 1) - delta - 1

    # Clamp explicite (≡ `max(ms + offset, 1_000)`) : le guard de range permet à dialyzer de
    # PROUVER le retour pos_integer (le BIF `max/2` rend l'union des deux args → integer()).
    case ms + offset do
      jittered when jittered >= 1_000 -> jittered
      _ -> 1_000
    end
  end
end

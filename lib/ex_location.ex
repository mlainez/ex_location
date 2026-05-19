# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ExLocation do
  @moduledoc """
  GPS / GNSS location for Qualcomm modems via the QMI **LOC** service.

  Mimics ModemManager's `org.freedesktop.ModemManager1.Modem.Location`
  surface — start a tracking session, choose standalone vs network
  assistance, subscribe to position + satellites-in-view updates.

  ## Events

  Subscribers receive `{ExLocation, kind, payload}`:

    * `{ExLocation, :position, %{latitude, longitude, altitude_msl,
      speed, heading, accuracy, hdop, datetime, …}}` — every fix.
    * `{ExLocation, :sv_info, %{satellites: [%{system, sv_id, snr,
      elevation, azimuth, used_in_fix, healthy}]}}` — satellite list.

  ## Quick start

      iex> ExLocation.subscribe()
      :ok
      flush()
      # {ExLocation, :position, %{latitude: 51.50…, longitude: -0.12…, …}}

  Or, single-shot:

      iex> ExLocation.get_position()
      {:ok, %{latitude: …, longitude: …, datetime: …}}

  By default the supervisor brings up a QMI client against the local
  modem at boot and starts periodic 1 Hz tracking in `:msb`
  (Mobile-Station-Based AGPS — best fix speed when cellular data is
  available). Tune via config:

      config :ex_location,
        operation_mode: :standalone, # :default | :msb | :msa | :standalone | :cellid | :wwan
        interval_ms: 1_000,
        autostart: true,
        log_events: true,
        sync_time: true              # feed GPS UTC to NervesTime if NTP hasn't synced

  ## Clock synchronisation

  When `sync_time: true` (default) and `nerves_time` is on the load
  path, the first position report that carries a valid UTC timestamp
  AND happens while `NervesTime.synchronized?/0` is `false` will be
  used to call `NervesTime.set_system_time/1`. WiFi/Ethernet NTP wins
  when it's available; the GPS path only fills the gap when the
  device has booted offline.

  Time is set at most once per boot from GPS — once `ntpd` takes
  over, GPS doesn't fight it.

  The defaults are deliberately ModemManager-like.
  """

  @doc """
  Subscribe the calling process to location events.

  Idempotent: subscribing twice from the same pid does not duplicate
  delivery. Each subscribed process receives both `:position` and
  `:sv_info` messages.
  """
  @spec subscribe() :: :ok
  def subscribe() do
    if :location in Registry.keys(ExLocation.Registry, self()) do
      :ok
    else
      {:ok, _} = Registry.register(ExLocation.Registry, :location, [])
      :ok
    end
  end

  @doc "Unsubscribe the calling process."
  @spec unsubscribe() :: :ok
  def unsubscribe() do
    Registry.unregister(ExLocation.Registry, :location)
    :ok
  end

  @doc """
  Return the most recently received position fix, or
  `{:error, :no_fix_yet}` if the modem hasn't produced one since boot.
  """
  @spec get_position() :: {:ok, map()} | {:error, :no_fix_yet}
  defdelegate get_position(), to: ExLocation.Tracker

  @doc """
  Return the most recently received satellites-in-view list, or
  `[]` if the modem hasn't reported one yet.
  """
  @spec satellites() :: [map()]
  defdelegate satellites(), to: ExLocation.Tracker

  @doc "Change the LOC operation mode (`:default | :msb | :msa | :standalone | :cellid | :wwan`)."
  @spec set_mode(QMI.Codec.LOC.operation_mode()) :: :ok | {:error, term()}
  defdelegate set_mode(mode), to: ExLocation.Tracker

  @doc "Change the minimum interval (ms) between position reports. Restarts the session."
  @spec set_interval(pos_integer()) :: :ok | {:error, term()}
  defdelegate set_interval(ms), to: ExLocation.Tracker

  @doc "Start tracking explicitly (no-op if already running)."
  @spec start_tracking() :: :ok | {:error, term()}
  defdelegate start_tracking(), to: ExLocation.Tracker

  @doc "Stop tracking explicitly."
  @spec stop_tracking() :: :ok | {:error, term()}
  defdelegate stop_tracking(), to: ExLocation.Tracker

  @doc "Current tracker state — `:idle | :starting | :tracking | :stopped`."
  @spec state() :: :idle | :starting | :tracking | :stopped
  defdelegate state(), to: ExLocation.Tracker
end

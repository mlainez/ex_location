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

  Requires the `qrtr-transport` branch of the
  [mlainez/qmi](https://github.com/mlainez/qmi) fork.

  ## Events

  Subscribers receive `{ExLocation, kind, payload}`:

    * `{ExLocation, :position, %{latitude, longitude, altitude_msl,
      speed, heading, accuracy, hdop, datetime, satellites_used, …}}` —
      sent for each position report that carries a valid fix
      (latitude and longitude present). Reports sent while the
      receiver is still searching are dropped.
    * `{ExLocation, :sv_info, %{satellites: [%{system, sv_id, status,
      snr, elevation, azimuth, healthy}]}}` — satellites in view;
      `status` is `:idle | :searching | :tracking`.

  ## Quick start

      iex> ExLocation.subscribe()
      :ok
      flush()
      # {ExLocation, :position, %{latitude: 51.50…, longitude: -0.12…, …}}

  Or, polling:

      iex> ExLocation.get_position()
      {:ok, %{latitude: …, longitude: …, datetime: …}}

  By default the application starts a QMI client (QRTR transport) at
  boot and, about 1.5 s later, tries to start periodic 1 Hz tracking in
  `:msb` (Mobile-Station-Based AGPS). The LOC service only appears once
  the modem firmware (MPSS) is running, so the tracker retries with
  exponential backoff (1 s doubling up to 30 s) until it does. See the
  README for all configuration keys.

  ## Clock synchronisation

  When `sync_time: true` (default) and `nerves_time` is on the load
  path, the first valid fix that carries a UTC timestamp while
  `NervesTime.synchronized?/0` is `false` is used to call
  `NervesTime.set_system_time/1`. WiFi/Ethernet NTP wins when it's
  available; the GPS path only fills the gap when the device has
  booted offline. Time is set at most once per boot from GPS.
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

  @doc """
  Change the LOC operation mode (`:default | :msb | :msa | :standalone |
  :cellid | :wwan`). If tracking hasn't started yet, the mode is stored
  and used when it does.
  """
  @spec set_mode(QMI.Codec.LOC.operation_mode()) :: :ok | {:error, term()}
  defdelegate set_mode(mode), to: ExLocation.Tracker

  @doc """
  Change the minimum interval (ms) between position reports. Restarts
  the session if tracking; otherwise stored for when tracking starts.
  """
  @spec set_interval(pos_integer()) :: :ok | {:error, term()}
  defdelegate set_interval(ms), to: ExLocation.Tracker

  @doc """
  Start tracking now (no-op if already running). Not needed with
  `autostart: true` (the default); useful after `stop_tracking/0` or
  with `autostart: false`. Returns `{:error, reason}` if the LOC
  service isn't available yet.
  """
  @spec start_tracking() :: :ok | {:error, term()}
  defdelegate start_tracking(), to: ExLocation.Tracker

  @doc "Stop tracking explicitly."
  @spec stop_tracking() :: :ok | {:error, term()}
  defdelegate stop_tracking(), to: ExLocation.Tracker

  @doc "Current tracker state — `:idle | :starting | :tracking | :stopped`."
  @spec state() :: :idle | :starting | :tracking | :stopped
  defdelegate state(), to: ExLocation.Tracker
end

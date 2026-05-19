# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ExLocation.Tracker do
  @moduledoc """
  Owns the QMI LOC tracking session.

  Drives the lifecycle that ModemManager performs internally:

    1. `LOC_REG_EVENTS` with position-report + GNSS-SV-info flags so
       the modem will fire indications.
    2. `LOC_SET_OPERATION_MODE` to pick standalone vs network-assisted.
    3. `LOC_START` with the configured fix interval.
    4. Buffer the latest indications; fan them out to subscribed pids
       via `ExLocation.Registry`.

  Use `ExLocation` as the public entry; this module is the worker.
  """

  use GenServer
  require Logger

  alias QMI.Codec.LOC

  @bootstrap_retry_ms 1_500
  @bootstrap_max_attempts 20

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  # Public API delegates from `ExLocation` -----------------------------

  def get_position(), do: GenServer.call(__MODULE__, :get_position)
  def satellites(), do: GenServer.call(__MODULE__, :satellites)
  def state(), do: GenServer.call(__MODULE__, :state)
  def start_tracking(), do: GenServer.call(__MODULE__, :start)
  def stop_tracking(), do: GenServer.call(__MODULE__, :stop)
  def set_mode(mode), do: GenServer.call(__MODULE__, {:set_mode, mode})
  def set_interval(ms), do: GenServer.call(__MODULE__, {:set_interval, ms})

  # Called by the QMI supervisor whenever an indication arrives.
  # Forwards into the GenServer mailbox so all state lives in one place.
  @spec handle_indication(map()) :: :ok
  def handle_indication(indication) do
    GenServer.cast(__MODULE__, {:indication, indication})
  end

  # ---- GenServer ----------------------------------------------------

  @impl GenServer
  def init([]) do
    cfg = Application.get_all_env(:ex_location)

    state = %{
      qmi: ExLocation.QMI,
      mode: Keyword.get(cfg, :operation_mode, :msb),
      interval_ms: Keyword.get(cfg, :interval_ms, 1_000),
      autostart: Keyword.get(cfg, :autostart, true),
      sync_time: Keyword.get(cfg, :sync_time, true),
      session_id: 1,
      fsm: :idle,
      last_position: nil,
      last_satellites: [],
      bootstrap_attempts: 0,
      time_synced_from_gps?: false
    }

    if state.autostart do
      Process.send_after(self(), :bootstrap, @bootstrap_retry_ms)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:bootstrap, state) do
    case bootstrap(state) do
      :ok ->
        Logger.info(
          "[ExLocation] tracking started (mode=#{state.mode}, interval=#{state.interval_ms}ms)"
        )

        {:noreply, %{state | fsm: :tracking}}

      {:error, reason} ->
        if state.bootstrap_attempts < @bootstrap_max_attempts do
          Logger.debug(
            "[ExLocation] bootstrap retry (attempt #{state.bootstrap_attempts + 1}): #{inspect(reason)}"
          )

          Process.send_after(self(), :bootstrap, @bootstrap_retry_ms)

          {:noreply, %{state | bootstrap_attempts: state.bootstrap_attempts + 1, fsm: :starting}}
        else
          Logger.warning(
            "[ExLocation] gave up bootstrapping after #{state.bootstrap_attempts} tries: #{inspect(reason)}"
          )

          {:noreply, %{state | fsm: :idle}}
        end
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:indication, %{name: :position_report} = pos}, state) do
    broadcast({:position, pos})
    state = maybe_sync_time(state, pos)
    {:noreply, %{state | last_position: pos}}
  end

  def handle_cast({:indication, %{name: :gnss_sv_info, satellites: sats} = sv}, state) do
    broadcast({:sv_info, sv})
    {:noreply, %{state | last_satellites: sats}}
  end

  def handle_cast({:indication, _other}, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, state.fsm, state}

  def handle_call(:get_position, _from, %{last_position: nil} = state),
    do: {:reply, {:error, :no_fix_yet}, state}

  def handle_call(:get_position, _from, %{last_position: pos} = state),
    do: {:reply, {:ok, pos}, state}

  def handle_call(:satellites, _from, state), do: {:reply, state.last_satellites, state}

  def handle_call(:start, _from, %{fsm: :tracking} = state), do: {:reply, :ok, state}

  def handle_call(:start, _from, state) do
    case bootstrap(state) do
      :ok -> {:reply, :ok, %{state | fsm: :tracking}}
      err -> {:reply, err, state}
    end
  end

  def handle_call(:stop, _from, state) do
    res = QMI.call(LOC.stop(state.session_id), state.qmi)
    {:reply, res, %{state | fsm: :stopped}}
  end

  def handle_call({:set_mode, mode}, _from, state) do
    case QMI.call(LOC.set_operation_mode(mode), state.qmi) do
      :ok -> {:reply, :ok, %{state | mode: mode}}
      err -> {:reply, err, state}
    end
  end

  def handle_call({:set_interval, ms}, _from, state) when is_integer(ms) and ms > 0 do
    # Restart the session at the new rate. STOP first to cleanly tear
    # down, then START with the new interval.
    _ = QMI.call(LOC.stop(state.session_id), state.qmi)

    case QMI.call(LOC.start(session_id: state.session_id, interval_ms: ms), state.qmi) do
      :ok -> {:reply, :ok, %{state | interval_ms: ms, fsm: :tracking}}
      err -> {:reply, err, state}
    end
  end

  # ---- Internals ----------------------------------------------------

  defp bootstrap(%{qmi: qmi, mode: mode, interval_ms: interval, session_id: sid}) do
    with :ok <-
           QMI.call(LOC.register_events([:position_report, :gnss_satellite_info]), qmi),
         :ok <- QMI.call(LOC.set_operation_mode(mode), qmi),
         :ok <- QMI.call(LOC.start(session_id: sid, interval_ms: interval), qmi) do
      :ok
    end
  end

  defp broadcast(event) do
    Registry.dispatch(ExLocation.Registry, :location, fn subs ->
      for {pid, _} <- subs, do: send(pid, {ExLocation, elem(event, 0), elem(event, 1)})
    end)
  end

  # Feed the GPS-derived datetime to nerves_time when:
  #   1. The user opted in (config :ex_location, sync_time: true — default).
  #   2. nerves_time is on the load path (no-op in plain-Elixir use).
  #   3. nerves_time hasn't reached NTP-synced state yet (so wifi/ethernet
  #      NTP wins automatically when available — we only fill the gap).
  #   4. We have a real DateTime (codec returns nil for indications without
  #      TLV 0x25, so cell-tower fallback fixes don't trigger this).
  #   5. We haven't already pushed a GPS time this session — set once and
  #      let ntpd take it from there.
  defp maybe_sync_time(%{sync_time: false} = state, _pos), do: state
  defp maybe_sync_time(%{time_synced_from_gps?: true} = state, _pos), do: state
  defp maybe_sync_time(state, %{datetime: nil}), do: state

  defp maybe_sync_time(state, %{datetime: %DateTime{} = dt}) do
    cond do
      not Code.ensure_loaded?(NervesTime) ->
        state

      apply(NervesTime, :synchronized?, []) ->
        # NTP already won — leave the clock alone.
        %{state | time_synced_from_gps?: true}

      true ->
        naive = DateTime.to_naive(dt)

        case apply(NervesTime, :set_system_time, [naive]) do
          :ok ->
            Logger.info("[ExLocation] set system time from GPS: #{NaiveDateTime.to_iso8601(naive)}")
            %{state | time_synced_from_gps?: true}

          other ->
            Logger.warning("[ExLocation] NervesTime.set_system_time/1 returned #{inspect(other)}")
            state
        end
    end
  end

  defp maybe_sync_time(state, _pos), do: state
end

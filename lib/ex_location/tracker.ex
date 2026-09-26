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

  The LOC service only exists once the modem firmware (MPSS) is
  running and has announced it. Until then every QMI call fails, so
  bootstrap is retried with exponential backoff (1 s doubling up to
  30 s) for as long as it takes. QMI errors and exits are caught; the
  tracker never crashes because the modem isn't ready.

  Use `ExLocation` as the public entry; this module is the worker.
  """

  use GenServer
  require Logger

  alias QMI.Codec.LOC

  @bootstrap_delay_ms 1_500
  @retry_initial_ms 1_000
  @retry_max_ms 30_000

  # A bootstrap is up to three sequential QMI calls with a 5 s timeout
  # each, so the public API needs more than GenServer's default 5 s.
  @call_timeout 30_000

  @modes [:default, :msb, :msa, :standalone, :cellid, :wwan]

  @doc """
  Start the tracker.

  Options override the `:ex_location` application environment. These
  extra options exist for testing:

    * `:qmi` — QMI supervisor name (default `ExLocation.QMI`)
    * `:qmi_call` — 2-arity function used instead of `QMI.call/2`
    * `:bootstrap_delay_ms`, `:retry_initial_ms`, `:retry_max_ms`
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Public API delegates from `ExLocation` -----------------------------

  def get_position(), do: GenServer.call(__MODULE__, :get_position)
  def satellites(), do: GenServer.call(__MODULE__, :satellites)
  def state(), do: GenServer.call(__MODULE__, :state)
  def start_tracking(), do: GenServer.call(__MODULE__, :start, @call_timeout)
  def stop_tracking(), do: GenServer.call(__MODULE__, :stop, @call_timeout)
  def set_mode(mode), do: GenServer.call(__MODULE__, {:set_mode, mode}, @call_timeout)
  def set_interval(ms), do: GenServer.call(__MODULE__, {:set_interval, ms}, @call_timeout)

  # Called by the QMI driver whenever an indication arrives.
  # Forwards into the GenServer mailbox so all state lives in one place.
  @spec handle_indication(map()) :: :ok
  def handle_indication(indication) do
    GenServer.cast(__MODULE__, {:indication, indication})
  end

  # ---- GenServer ----------------------------------------------------

  @impl GenServer
  def init(opts) do
    cfg = Keyword.merge(Application.get_all_env(:ex_location), opts)
    retry_initial_ms = Keyword.get(cfg, :retry_initial_ms, @retry_initial_ms)

    state = %{
      qmi: Keyword.get(cfg, :qmi, ExLocation.QMI),
      qmi_call: Keyword.get(cfg, :qmi_call, &QMI.call/2),
      mode: Keyword.get(cfg, :operation_mode, :msb),
      interval_ms: Keyword.get(cfg, :interval_ms, 1_000),
      autostart: Keyword.get(cfg, :autostart, true),
      sync_time: Keyword.get(cfg, :sync_time, true),
      retry_initial_ms: retry_initial_ms,
      retry_max_ms: Keyword.get(cfg, :retry_max_ms, @retry_max_ms),
      retry_ms: retry_initial_ms,
      retry_timer: nil,
      bootstrap_attempts: 0,
      session_id: 1,
      fsm: :idle,
      last_position: nil,
      last_satellites: [],
      time_synced_from_gps?: false
    }

    state =
      if state.autostart do
        delay = Keyword.get(cfg, :bootstrap_delay_ms, @bootstrap_delay_ms)
        %{state | fsm: :starting, retry_timer: Process.send_after(self(), :bootstrap, delay)}
      else
        state
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:bootstrap, %{fsm: :starting} = state) do
    state = %{state | retry_timer: nil, bootstrap_attempts: state.bootstrap_attempts + 1}

    case bootstrap(state) do
      :ok ->
        {:noreply, tracking(state)}

      {:error, reason} ->
        if state.bootstrap_attempts == 1 do
          Logger.info(
            "[ExLocation] LOC service not ready (#{inspect(reason)}); " <>
              "retrying until the modem is up"
          )
        else
          Logger.debug(
            "[ExLocation] bootstrap attempt #{state.bootstrap_attempts} failed: #{inspect(reason)}; " <>
              "next in #{state.retry_ms} ms"
          )
        end

        timer = Process.send_after(self(), :bootstrap, state.retry_ms)

        {:noreply,
         %{state | retry_timer: timer, retry_ms: min(state.retry_ms * 2, state.retry_max_ms)}}
    end
  end

  # Stale timer (tracking was started or stopped manually meanwhile).
  def handle_info(:bootstrap, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:indication, %{name: :position_report} = pos}, state) do
    if valid_fix?(pos) do
      broadcast({:position, pos})
      state = maybe_sync_time(state, pos)
      {:noreply, %{state | last_position: pos}}
    else
      {:noreply, state}
    end
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
      :ok -> {:reply, :ok, tracking(state)}
      err -> {:reply, err, state}
    end
  end

  def handle_call(:stop, _from, state) do
    state = cancel_retry(state)
    res = qmi_call(state, LOC.stop(state.session_id))
    {:reply, res, %{state | fsm: :stopped}}
  end

  def handle_call({:set_mode, mode}, _from, state) when mode not in @modes,
    do: {:reply, {:error, :invalid_mode}, state}

  def handle_call({:set_mode, mode}, _from, %{fsm: :tracking} = state) do
    case qmi_call(state, LOC.set_operation_mode(mode)) do
      :ok -> {:reply, :ok, %{state | mode: mode}}
      err -> {:reply, err, state}
    end
  end

  # Not tracking yet: remember the mode for the next bootstrap.
  def handle_call({:set_mode, mode}, _from, state) do
    {:reply, :ok, %{state | mode: mode}}
  end

  def handle_call({:set_interval, ms}, _from, %{fsm: :tracking} = state)
      when is_integer(ms) and ms > 0 do
    # Restart the session at the new rate. STOP first to cleanly tear
    # down, then START with the new interval.
    _ = qmi_call(state, LOC.stop(state.session_id))

    case qmi_call(state, LOC.start(session_id: state.session_id, interval_ms: ms)) do
      :ok -> {:reply, :ok, %{state | interval_ms: ms}}
      # The old session is gone; call start_tracking/0 to retry.
      err -> {:reply, err, %{state | interval_ms: ms, fsm: :idle}}
    end
  end

  # Not tracking yet: remember the interval for the next bootstrap.
  def handle_call({:set_interval, ms}, _from, state) when is_integer(ms) and ms > 0 do
    {:reply, :ok, %{state | interval_ms: ms}}
  end

  def handle_call({:set_interval, _ms}, _from, state),
    do: {:reply, {:error, :invalid_interval}, state}

  # ---- Internals ----------------------------------------------------

  defp bootstrap(%{mode: mode, interval_ms: interval, session_id: sid} = state) do
    with :ok <- qmi_call(state, LOC.register_events([:position_report, :gnss_satellite_info])),
         :ok <- qmi_call(state, LOC.set_operation_mode(mode)),
         :ok <- qmi_call(state, LOC.start(session_id: sid, interval_ms: interval)) do
      :ok
    end
  end

  defp tracking(state) do
    Logger.info(
      "[ExLocation] tracking started (mode=#{state.mode}, interval=#{state.interval_ms}ms)"
    )

    %{cancel_retry(state) | fsm: :tracking, retry_ms: state.retry_initial_ms}
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(%{retry_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | retry_timer: nil}
  end

  # QMI.call/2 returns {:error, _} for modem-side problems but exits if
  # the QMI driver isn't running (e.g. while it restarts). Normalise
  # both into {:error, reason} so the tracker never crashes on them.
  defp qmi_call(%{qmi_call: call, qmi: qmi}, request) do
    case call.(request, qmi) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Only real fixes are stored and broadcast. The modem also sends
  # position reports while it is still searching (session status
  # :in_progress, no latitude/longitude) and on failures.
  defp valid_fix?(%{session_status: status, latitude: lat, longitude: lon})
       when status in [:success, :in_progress] and is_number(lat) and is_number(lon),
       do: true

  defp valid_fix?(_pos), do: false

  defp broadcast({kind, payload}) do
    Registry.dispatch(ExLocation.Registry, :location, fn subs ->
      for {pid, _} <- subs, do: send(pid, {ExLocation, kind, payload})
    end)
  end

  # Feed the GPS-derived datetime to nerves_time when:
  #   1. The user opted in (config :ex_location, sync_time: true — default).
  #   2. nerves_time is on the load path (no-op in plain-Elixir use).
  #   3. nerves_time hasn't reached NTP-synced state yet (so wifi/ethernet
  #      NTP wins automatically when available — we only fill the gap).
  #   4. We have a real DateTime from a valid fix (the codec returns nil
  #      for reports without TLV 0x25).
  #   5. We haven't already pushed a GPS time this session — set once and
  #      let ntpd take it from there.
  defp maybe_sync_time(%{sync_time: false} = state, _pos), do: state
  defp maybe_sync_time(%{time_synced_from_gps?: true} = state, _pos), do: state

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
            Logger.info(
              "[ExLocation] set system time from GPS: #{NaiveDateTime.to_iso8601(naive)}"
            )

            %{state | time_synced_from_gps?: true}

          other ->
            Logger.warning("[ExLocation] NervesTime.set_system_time/1 returned #{inspect(other)}")
            state
        end
    end
  end

  defp maybe_sync_time(state, _pos), do: state
end

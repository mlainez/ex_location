defmodule ExLocation.TrackerTest do
  use ExUnit.Case, async: false

  alias ExLocation.Tracker

  setup do
    start_supervised!({Registry, keys: :duplicate, name: ExLocation.Registry})
    :ok
  end

  defp start_tracker(opts) do
    opts = Keyword.merge([autostart: false, sync_time: false], opts)
    start_supervised!({Tracker, opts})
  end

  # Fake QMI.call/2: reports every request to the test process and
  # returns whatever `responder` says.
  defp fake_qmi(test, responder) do
    fn request, _qmi ->
      <<msg_id::little-16, _::binary>> = IO.iodata_to_binary(request.payload)
      send(test, {:qmi_call, msg_id})
      responder.(msg_id)
    end
  end

  defp flush_qmi_calls do
    receive do
      {:qmi_call, _} -> flush_qmi_calls()
    after
      0 -> :ok
    end
  end

  defp position(overrides) do
    Map.merge(
      %{
        name: :position_report,
        service_id: 0x10,
        indication_id: 0x24,
        session_status: :success,
        session_id: 1,
        latitude: 50.85,
        longitude: 4.35,
        altitude_msl: 60.0,
        altitude_ellipsoid: nil,
        speed: 0.0,
        heading: nil,
        accuracy: 10.0,
        vertical_accuracy: nil,
        hdop: 1.0,
        pdop: nil,
        vdop: nil,
        utc_timestamp: nil,
        datetime: nil,
        satellites_used: [3, 7]
      },
      Map.new(overrides)
    )
  end

  describe "indications" do
    setup do
      start_tracker(qmi_call: fake_qmi(self(), fn _ -> :ok end))
      :ok = ExLocation.subscribe()
      :ok
    end

    test "valid fixes are broadcast and stored" do
      assert ExLocation.get_position() == {:error, :no_fix_yet}

      pos = position([])
      Tracker.handle_indication(pos)

      assert_receive {ExLocation, :position, ^pos}
      assert ExLocation.get_position() == {:ok, pos}
    end

    test "in-progress reports without a position are ignored" do
      good = position([])
      Tracker.handle_indication(good)
      assert_receive {ExLocation, :position, ^good}

      Tracker.handle_indication(
        position(session_status: :in_progress, latitude: nil, longitude: nil)
      )

      Tracker.handle_indication(position(session_status: :timeout, latitude: nil, longitude: nil))

      refute_receive {ExLocation, :position, _}, 50
      # last good fix is kept
      assert ExLocation.get_position() == {:ok, good}
    end

    test "intermediate reports that carry a position are accepted" do
      pos = position(session_status: :in_progress, accuracy: 150.0)
      Tracker.handle_indication(pos)
      assert_receive {ExLocation, :position, ^pos}
    end

    test "failed sessions are ignored even with coordinates" do
      Tracker.handle_indication(position(session_status: :general_failure))
      refute_receive {ExLocation, :position, _}, 50
      assert ExLocation.get_position() == {:error, :no_fix_yet}
    end

    test "satellite info is broadcast and stored" do
      sats = [
        %{
          system: :gps,
          sv_id: 7,
          status: :tracking,
          elevation: 61.0,
          azimuth: 210.0,
          snr: 38.0,
          healthy: true
        }
      ]

      sv = %{name: :gnss_sv_info, service_id: 0x10, indication_id: 0x25, satellites: sats}
      Tracker.handle_indication(sv)

      assert_receive {ExLocation, :sv_info, ^sv}
      assert ExLocation.satellites() == sats
    end

    test "unsubscribe stops delivery" do
      :ok = ExLocation.unsubscribe()
      Tracker.handle_indication(position([]))
      refute_receive {ExLocation, :position, _}, 50
    end
  end

  describe "bootstrap" do
    test "retries with backoff until the LOC service appears" do
      {:ok, ready} = Agent.start_link(fn -> false end)

      responder = fn _msg ->
        if Agent.get(ready, & &1), do: :ok, else: {:error, {:service_not_found, 0x10}}
      end

      start_tracker(
        autostart: true,
        bootstrap_delay_ms: 0,
        retry_initial_ms: 10,
        retry_max_ms: 40,
        qmi_call: fake_qmi(self(), responder)
      )

      # a few failed attempts (register events is the first call)
      for _ <- 1..4, do: assert_receive({:qmi_call, 0x21}, 500)
      assert ExLocation.state() == :starting

      Agent.update(ready, fn _ -> true end)

      assert_receive {:qmi_call, 0x4A}, 500
      assert_receive {:qmi_call, 0x22}, 500
      assert ExLocation.state() == :tracking

      # no more bootstrap attempts once tracking
      flush_qmi_calls()
      refute_receive {:qmi_call, _}, 100
    end

    test "survives the QMI driver not running" do
      # Real QMI.call/2 against a QMI instance that doesn't exist exits
      # with :noproc; the tracker must catch it and keep retrying.
      pid =
        start_tracker(
          autostart: true,
          qmi: ExLocation.TrackerTest.NoSuchQMI,
          bootstrap_delay_ms: 0,
          retry_initial_ms: 10,
          retry_max_ms: 20
        )

      Process.sleep(100)
      assert Process.alive?(pid)
      assert ExLocation.state() == :starting
      assert {:error, {:exit, _}} = ExLocation.start_tracking()
    end

    test "backoff is capped and never gives up" do
      start_tracker(
        autostart: true,
        bootstrap_delay_ms: 0,
        retry_initial_ms: 1,
        retry_max_ms: 5,
        qmi_call: fake_qmi(self(), fn _ -> {:error, :timeout} end)
      )

      for _ <- 1..30, do: assert_receive({:qmi_call, 0x21}, 500)
      assert ExLocation.state() == :starting
    end

    test "start_tracking/0 bootstraps on demand and is idempotent" do
      start_tracker(qmi_call: fake_qmi(self(), fn _ -> :ok end))
      assert ExLocation.state() == :idle

      assert ExLocation.start_tracking() == :ok
      assert_receive {:qmi_call, 0x21}
      assert_receive {:qmi_call, 0x4A}
      assert_receive {:qmi_call, 0x22}
      assert ExLocation.state() == :tracking

      assert ExLocation.start_tracking() == :ok
      refute_receive {:qmi_call, _}, 50

      assert ExLocation.stop_tracking() == :ok
      assert_receive {:qmi_call, 0x23}
      assert ExLocation.state() == :stopped
    end

    test "start_tracking/0 returns the error when LOC isn't there" do
      start_tracker(qmi_call: fake_qmi(self(), fn _ -> {:error, {:service_not_found, 16}} end))
      assert ExLocation.start_tracking() == {:error, {:service_not_found, 16}}
      assert ExLocation.state() == :idle
    end
  end

  describe "mode and interval" do
    test "are stored before tracking and used at bootstrap" do
      test = self()

      call = fn request, _qmi ->
        send(test, {:payload, IO.iodata_to_binary(request.payload)})
        :ok
      end

      start_tracker(qmi_call: call)

      assert ExLocation.set_mode(:standalone) == :ok
      assert ExLocation.set_interval(2_000) == :ok
      refute_receive {:payload, _}, 50

      assert ExLocation.set_mode(:bogus) == {:error, :invalid_mode}
      assert ExLocation.set_interval(0) == {:error, :invalid_interval}

      assert ExLocation.start_tracking() == :ok
      assert_receive {:payload, <<0x21, 0x00, _::binary>>}
      assert_receive {:payload, <<0x4A, 0x00, 7, 0, 1, 4, 0, 4, 0, 0, 0>>}
      assert_receive {:payload, <<0x22, 0x00, _::binary-size(16), 2_000::little-32>>}
    end
  end
end

# ex_location

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on Fairphone 3 hardware. There are no stability guarantees and APIs will change without notice.

GPS / GNSS location for Qualcomm modems via the QMI **LOC** service.

Mirrors ModemManager's `org.freedesktop.ModemManager1.Modem.Location`
surface: start a tracking session, pick standalone or network-assisted
mode, and subscribe to position and satellite updates.

## Install

```elixir
defp deps do
  [{:ex_location, github: "mlainez/ex_location"}]
end
```

**Requires the `qrtr-transport` branch of the
[`mlainez/qmi`](https://github.com/mlainez/qmi/tree/qrtr-transport) fork**,
not the Hex release: upstream `qmi` has neither the QRTR transport nor
the LOC codec. `ex_location` already declares it:

```elixir
{:qmi, github: "mlainez/qmi", branch: "qrtr-transport"}
```

If another dependency (e.g. `vintage_net_qmi`) pulls in `qmi` from Hex,
add the line above with `override: true` to your own `deps`.

## Toolchain

Built and tested with Erlang/OTP 29.1.1 and Elixir 1.20.4, matching the official Nerves systems (see `.tool-versions`).

## Usage

The application starts tracking on its own (`autostart: true`), so
subscribing is all you need:

```elixir
ExLocation.subscribe()

# {ExLocation, :position, %{latitude: 51.50…, longitude: -0.12…,
#                           altitude_msl: 35.2, speed: 0.0,
#                           heading: 0.0, accuracy: 12.0,
#                           hdop: 1.1, datetime: ~U[…],
#                           satellites_used: [3, 7, 12, …], …}}
#
# {ExLocation, :sv_info, %{satellites: [
#   %{system: :gps, sv_id: 7, status: :tracking, snr: 38.0,
#     elevation: 61.0, azimuth: 210.0, healthy: true}, …]}}
```

`:position` is sent for each position report that carries a valid fix
(latitude and longitude present). Reports the modem sends while it is
still searching, or when a session fails, are not broadcast and don't
replace the last fix. `:sv_info` is sent for every satellites-in-view
update; `status` is `:idle`, `:searching` or `:tracking`.
`satellites_used` lists the SV IDs used for the fix (GLONASS IDs are
65–96 there but 1–32 in `:sv_info`).

Polling API, if you'd rather not subscribe:

```elixir
ExLocation.get_position()   # {:ok, fix} | {:error, :no_fix_yet}
ExLocation.satellites()     # last satellites-in-view list
ExLocation.state()          # :idle | :starting | :tracking | :stopped
```

Control:

```elixir
ExLocation.stop_tracking()
ExLocation.start_tracking()        # only needed after stop, or with autostart: false
ExLocation.set_mode(:standalone)
ExLocation.set_interval(5_000)
```

`set_mode/1` and `set_interval/1` apply immediately while tracking, and
are otherwise remembered for when tracking starts.

## Configuration

```elixir
config :ex_location,
  transport: :qrtr,
  operation_mode: :msb,
  interval_ms: 1_000,
  autostart: true,
  log_events: true,
  sync_time: true
```

| Key | Default | Meaning |
| --- | --- | --- |
| `:transport` | `:qrtr` | QMI transport passed to `QMI.Supervisor`. `:qrtr` (`AF_QIPCRTR` sockets) is what the Fairphone 3's in-kernel modem uses. `:qmux` is for modems with a `/dev/cdc-wdm*` chardev and needs `:device_path`; it has not been tested with `ex_location`. |
| `:device_path` | unset | QMI control device for `transport: :qmux` (e.g. `"/dev/cdc-wdm0"`). Ignored for `:qrtr`. |
| `:operation_mode` | `:msb` | LOC operation mode: `:default`, `:msb` (Mobile-Station-Based A-GPS), `:msa`, `:standalone`, `:cellid` or `:wwan`. Use `:standalone` without cellular data. |
| `:interval_ms` | `1_000` | Minimum interval between position reports. |
| `:autostart` | `true` | Start tracking automatically at boot (with retries, see below). With `false`, call `ExLocation.start_tracking/0` yourself. |
| `:log_events` | `true` | Start `ExLocation.Logger`, which logs each fix and satellite update via `Logger.info`. |
| `:sync_time` | `true` | Set the system clock from the first GPS fix when `nerves_time` is present and NTP hasn't synchronized yet. At most once per boot. |

## Modem startup

The LOC service is published by the modem firmware (MPSS). It only
appears on QRTR once the modem remote processor is up and running, which
on the Fairphone 3 means the MPSS firmware must be loaded and booted by
the kernel's remoteproc driver. Until then, QMI calls fail with
`{:error, {:service_not_found, 16}}`.

The tracker handles this: about 1.5 s after boot it tries to register for
events, set the operation mode and start the session. If that fails
(LOC not announced yet, QMI driver not ready, timeout) it retries with
exponential backoff — 1 s doubling up to 30 s — indefinitely, and never
crashes. `ExLocation.state/0` reports `:starting` while it waits.

Known limitation: if the modem restarts *after* tracking has started, the
session is lost and the tracker doesn't notice. Call
`ExLocation.stop_tracking/0` and `ExLocation.start_tracking/0` to recover.

## Getting a fix

A cold standalone fix outdoors takes minutes — the receiver has to
download almanac and ephemeris data from the satellites themselves.
Network assistance shortens this considerably where it's available.
Indoors you will usually get satellites in view via `:sv_info` but never
converge to a position.

For a demo, start tracking early and near a window.

## Status

The retry/backoff logic, fix filtering and LOC codec have tests on a
host with a simulated QMI layer. The latest changes (driver error
handling in the `qmi` fork, codec fixes, tracker retries) have **not**
been verified on a Fairphone 3 modem yet.

## License

Apache-2.0

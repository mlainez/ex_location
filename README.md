# ex_location

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on
> Fairphone 3 hardware. It exists for tinkering and teaching.
>
> **Not an actively maintained project** (yet) — no stability
> guarantees, no test coverage, APIs will change without notice.

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

Depends on [`qmi`](https://github.com/mlainez/qmi) — the fork, not the
Hex release. Upstream `qmi` has no LOC service codec; this needs it.

## Usage

```elixir
ExLocation.subscribe()
ExLocation.start_tracking()

# {ExLocation, :position, %{latitude: 51.50…, longitude: -0.12…,
#                           altitude_msl: 35.2, speed: 0.0,
#                           heading: 0.0, accuracy: 12.0,
#                           hdop: 1.1, datetime: ~U[…]}}
#
# {ExLocation, :sv_info, %{satellites: [
#   %{system: :gps, sv_id: 7, snr: 38.0, elevation: 61.0,
#     azimuth: 210.0, used_in_fix: true, healthy: true}, …]}}
```

Polling API, if you'd rather not subscribe:

```elixir
ExLocation.get_position()
ExLocation.satellites()
ExLocation.state()
ExLocation.stop_tracking()
```

## Getting a fix

A cold standalone fix outdoors takes minutes — the receiver has to
download almanac and ephemeris data from the satellites themselves.
Network assistance shortens this considerably where it's available.
Indoors you will usually get satellites in view via `:sv_info` but never
converge to a position.

For a demo, start tracking early and near a window.

## License

Apache-2.0

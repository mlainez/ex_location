# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ExLocation.Logger do
  @moduledoc """
  Default subscriber that pretty-prints each fix and satellite update
  via `Logger.info`. Disable with `config :ex_location, log_events: false`.
  """

  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl GenServer
  def init([]) do
    :ok = ExLocation.subscribe()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({ExLocation, :position, pos}, state) do
    Logger.info("[ExLocation] fix " <> format_pos(pos))
    {:noreply, state}
  end

  def handle_info({ExLocation, :sv_info, %{satellites: sats}}, state) do
    used = Enum.count(sats, & &1.used_in_fix)
    seen = length(sats)

    by_system =
      sats
      |> Enum.frequencies_by(& &1.system)
      |> Enum.map(fn {sys, n} -> "#{sys}=#{n}" end)
      |> Enum.join(",")

    Logger.info("[ExLocation] satellites used=#{used}/#{seen} (#{by_system})")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp format_pos(%{latitude: nil}), do: "no-fix"

  defp format_pos(pos) do
    [
      "lat=#{fmt(pos.latitude, 6)}",
      "lon=#{fmt(pos.longitude, 6)}",
      pos.altitude_msl && "alt=#{fmt(pos.altitude_msl, 1)}m",
      pos.speed && "speed=#{fmt(pos.speed, 2)}m/s",
      pos.heading && "hdg=#{fmt(pos.heading, 1)}°",
      pos.accuracy && "±#{fmt(pos.accuracy, 1)}m",
      pos.hdop && "hdop=#{fmt(pos.hdop, 1)}",
      pos.datetime && "t=#{DateTime.to_iso8601(pos.datetime)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp fmt(nil, _), do: nil
  defp fmt(n, decimals) when is_float(n), do: :erlang.float_to_binary(n, decimals: decimals)
  defp fmt(n, _), do: to_string(n)
end

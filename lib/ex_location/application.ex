# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ExLocation.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    log_events? = Application.get_env(:ex_location, :log_events, true)

    children =
      [
        {Registry, keys: :duplicate, name: ExLocation.Registry},
        {QMI.Supervisor,
         name: ExLocation.QMI,
         transport: Application.get_env(:ex_location, :transport, :qrtr),
         indication_callback: &ExLocation.Tracker.handle_indication/1},
        ExLocation.Tracker
      ] ++ if(log_events?, do: [ExLocation.Logger], else: [])

    Supervisor.start_link(children, strategy: :one_for_one, name: ExLocation.Supervisor)
  end
end

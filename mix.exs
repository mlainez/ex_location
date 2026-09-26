defmodule ExLocation.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_location,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExLocation.Application, []}
    ]
  end

  # Tests start the pieces they need themselves instead of the whole
  # application (which would try to talk to a modem).
  defp aliases do
    [test: "test --no-start"]
  end

  defp deps do
    [
      {:qmi, github: "mlainez/qmi", branch: "qrtr-transport"}
    ]
  end
end

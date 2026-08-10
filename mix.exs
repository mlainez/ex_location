defmodule ExLocation.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_location,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExLocation.Application, []}
    ]
  end

  defp deps do
    [
      {:qmi, github: "mlainez/qmi", branch: "qrtr-transport"}
    ]
  end
end

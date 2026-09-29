defmodule SampleDep.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_dep,
      version: "0.1.0",
      deps: [],
      build_per_environment: false,
      aliases: [compile: [&prepare/1, "compile"]]
    ]
  end

  defp prepare(_) do
    File.mkdir_p!("priv")
    File.write!("priv/generated.txt", "dependency alias ran")
  end
end

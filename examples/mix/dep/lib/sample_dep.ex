defmodule SampleDep do
  @config_marker Application.compile_env!(:sample, :compile_marker)
  @root_env System.fetch_env!("MIX_ENV")
  def answer, do: 42
  def config_marker, do: @config_marker
  def root_env, do: @root_env
  def generated, do: Application.app_dir(:sample_dep, "priv/generated.txt") |> File.read!()
end

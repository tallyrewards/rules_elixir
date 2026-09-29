defmodule Sample do
  @answer SampleDep.answer()
  @config_marker SampleDep.config_marker()
  @root_env SampleDep.root_env()
  def root_env, do: @root_env
  @generated SampleDep.generated()
  def generated, do: @generated
  def answer, do: @answer
  def config_marker, do: @config_marker
  def resource, do: Application.app_dir(:sample, "priv/message.txt") |> File.read!()
end

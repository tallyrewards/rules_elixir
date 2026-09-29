defmodule SampleNative do
  {generated, 0} = System.cmd("fixture-codegen", [])
  @generated generated
  def generated, do: @generated

  @on_load :load
  def load,
    do:
      :erlang.load_nif(
        Application.app_dir(:sample_native, "priv/sample") |> String.to_charlist(),
        0
      )

  def answer, do: :erlang.nif_error(:not_loaded)
end

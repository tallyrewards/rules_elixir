defmodule Sample.Unicode do
  @external_resource Path.expand("../priv/café.txt", __DIR__)
  @greeting File.read!(@external_resource)

  def greeting, do: @greeting
end

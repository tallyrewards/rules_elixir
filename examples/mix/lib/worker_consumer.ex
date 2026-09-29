defmodule Sample.WorkerConsumer do
  @value Sample.WorkerLeaf.value()
  @external_resource "priv/message.txt"
  @message File.read!(@external_resource)
  def value, do: @value
  def message, do: @message
end

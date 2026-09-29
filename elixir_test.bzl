"""Run ExUnit against the precompiled test configuration."""

load("//private:mix_consumers.bzl", _elixir_test = "elixir_test")

elixir_test = _elixir_test

"""Assemble a named Mix release from the precompiled prod configuration."""

load("//private:mix_consumers.bzl", _elixir_release = "elixir_release")

elixir_release = _elixir_release

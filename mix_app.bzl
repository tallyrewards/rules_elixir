"""Compile one Mix application from Bazel-built OTP dependencies."""

load("//private:mix_app.bzl", _mix_app = "mix_app")

def mix_app(name, mix_exs, **kwargs):
    """Compile the Mix project rooted at mix_exs."""
    _mix_app(name = name, project_file = mix_exs, **kwargs)

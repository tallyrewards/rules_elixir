"""Root configuration read by independently built dependencies."""

load("//private:mix_app.bzl", _MixConfigInfo = "MixConfigInfo", _mix_config = "mix_config")

MixConfigInfo = _MixConfigInfo
mix_config = _mix_config

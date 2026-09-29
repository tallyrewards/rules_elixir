"""Check dependency drift offline from declared root and dependency sources."""

load("//private:mix_lock_test.bzl", _mix_lock_test = "mix_lock_test")

mix_lock_test = _mix_lock_test

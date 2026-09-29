# Elixir distributions

Download tags in the module extension retain their existing interface. Archives
are checksum verified and extracted during repository setup. Compilation and
prebuilt staging consume declared files without action-time downloads.

Direct `elixir_build` and `elixir_prebuilt` callers must replace URL, checksum
and strip-prefix attributes with `srcs` (the extracted distribution files) and
`root` (a marker file in the distribution root). Prefer the module-extension
tags when fetching a distribution. See `examples/distributions`.

A source build still runs the execution platform's `make`, and OTP provisioning
still follows the selected rules_erlang toolchain. This change does not make
either relocatable or fully hermetic; prefer a prebuilt distribution where that
matters.

# Remote execution and cache validation

## Individual remote actions

Run the Mix example against a REAPI-compatible execution service with the same
OTP, Elixir and native toolchain configuration as the client. An installed system
runtime must exist at the configured path on workers. Pin the worker image and
include its identity in the execution platform properties when using system
tools; paths alone do not identify their contents.

From `examples/mix`, build in a new output directory:

```sh
bazel --output_base=/tmp/elixir-producer test //... \
  --remote_executor=grpc://localhost:50051 \
  --remote_cache=grpc://localhost:50051 \
  --noremote_local_fallback --spawn_strategy=remote \
  --remote_download_outputs=all \
  --execution_log_json_file=/tmp/elixir-producer.json
```

Repeat with a different, empty `--output_base` and execution log. Keep the source,
toolchains, flags and execution properties identical. Check that the second log
reports cache hits for all worker actions, and compare downloaded release file
hashes. A warm build in the same output directory does not test remote reuse.

To test declared inputs, isolate worker actions from the client's checkout,
Bazel output directories and network. Repository downloads happen before action
execution and need their own network access. Do not permit local fallback: it
can hide missing worker inputs.

## Validated scope

An earlier revision of this fixture passed on Linux arm64 (Bazel 9.2, Elixir
1.20.3, OTP 29.0.5, NativeLink 1.7.1), with worker network access disabled and
the checkout and client caches hidden from workers. It covered native
compilation against a declared C library, compile-time NIF loading, two ExUnit
shards, manifest drift checking and two named releases. A fresh output base
reused every cached action and received identical release files.

This checks remote scheduling and cache transport with an installed runtime and
C compiler. It does not establish cross-platform compilation or a portable,
fully declared runtime closure. Absolute paths embedded by application macros
can also prevent byte-identical independent compilations; cache hits still
reproduce the original artifact bytes.

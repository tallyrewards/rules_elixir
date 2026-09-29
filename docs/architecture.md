# Mix application graph

Mix owns project semantics; Bazel owns declared inputs and compilation actions.
Each OTP application exports ErlangAppInfo and compiles against already-built
dependencies. Configuration, generated sources and resources must be declared.

The default cache boundary is an application. A one-file edit can therefore
recompile the application. Declared dependencies retain their own cache entries.

Compile actions block network access, but system runtimes, C compilers and shell
utilities still depend on the execution environment. The selected rules_erlang
OTP adapter also retains action-time downloads and absolute installation paths.
This is not a fully portable runtime closure. See the [usage guide](mix.md).

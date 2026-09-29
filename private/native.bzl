"""Use public rules_cc APIs; no downstream package-name policy."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

NativePlatformInfo = provider(fields = ["constraints"])
NATIVE_CONSTRAINTS = [Label("@platforms//" + value) for value in ["cpu:aarch64", "cpu:x86_64", "os:linux", "os:macos", "os:windows"]]

def _platform_impl(ctx):
    return [NativePlatformInfo(constraints = [str(v.label) for v in ctx.attr.constraints if ctx.target_platform_has_constraint(v[platform_common.ConstraintValueInfo])])]

native_platform = rule(implementation = _platform_impl, attrs = {"constraints": attr.label_list(default = NATIVE_CONSTRAINTS)})

def target_platform(ctx):
    """Architecture fields used to validate emitted native files."""

    # Read the declared names: platforms' macos label aliases osx internally.
    values = [label.name for label, target in zip(NATIVE_CONSTRAINTS, ctx.attr._native_constraints) if ctx.target_platform_has_constraint(target[platform_common.ConstraintValueInfo])]
    cpus = [v for v in values if v in ["aarch64", "x86_64"]]
    systems = [v for v in values if v in ["linux", "macos", "windows"]]
    return {"cpu": cpus[0] if cpus else "unknown", "os": systems[0] if systems else "unknown"}

def require_matching_platforms(ctx):
    """The current OTP toolchain represents one executable runtime, not a pair."""
    target = [str(v.label) for v in ctx.attr._native_constraints if ctx.target_platform_has_constraint(v[platform_common.ConstraintValueInfo])]
    if len(target) != 2 or target != ctx.attr._native_exec_platform[NativePlatformInfo].constraints:
        fail("native Mix compilation and release assembly currently require matching execution and target CPU/OS; cross-platform runtime/NIF loading needs separate exec and target artifacts")

def native_configuration(ctx):
    if not ctx.attr.native and not ctx.attr.native_deps and not any([f.extension in ["c", "cc", "cpp", "cxx", "m"] for f in ctx.files.srcs]):
        return ({}, depset(), [])
    require_matching_platforms(ctx)
    payloads = ctx.toolchains["//:mix_payloads_toolchain_type"]
    if payloads == None:
        fail("native sources require a registered mix_payloads toolchain with declared build tools")
    cc = find_cc_toolchain(ctx)
    features = cc_common.configure_features(ctx = ctx, cc_toolchain = cc, requested_features = ctx.features, unsupported_features = ctx.disabled_features)
    commands = {}
    environment = {}
    includes = {}
    defines = []
    libraries = []
    extra_link_flags = []
    native_inputs = []
    for dep in ctx.attr.native_deps:
        context = dep[CcInfo].compilation_context
        native_inputs.append(context.headers)
        defines.extend(context.defines.to_list())
        for flag, paths in {
            "-I": context.includes,
            "-iquote": context.quote_includes,
            "-isystem": context.system_includes,
            "-F": context.framework_includes,
        }.items():
            includes[flag] = includes.get(flag, []) + paths.to_list()
        for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
            extra_link_flags.extend(linker_input.user_link_flags)
            native_inputs.append(depset(linker_input.additional_inputs))
            for library in linker_input.libraries:
                archive = library.pic_static_library or library.static_library
                if not archive:
                    fail("native_deps currently require static libraries; dynamic libraries need an explicit runtime packaging adapter: " + str(dep.label))
                if library.alwayslink:
                    fail("alwayslink native libraries require an explicit link adapter: " + str(dep.label))
                libraries.append(archive)
    for name, action in {"CC": ACTION_NAMES.c_compile, "CXX": ACTION_NAMES.cpp_compile}.items():
        compile_variables = cc_common.create_compile_variables(feature_configuration = features, cc_toolchain = cc, user_compile_flags = ctx.fragments.cpp.copts + (ctx.fragments.cpp.conlyopts if name == "CC" else ctx.fragments.cpp.cxxopts))
        commands[name] = [cc_common.get_tool_for_action(feature_configuration = features, action_name = action)] + cc_common.get_memory_inefficient_command_line(feature_configuration = features, action_name = action, variables = compile_variables)
        environment.update(cc_common.get_environment_variables(feature_configuration = features, action_name = action, variables = compile_variables))
    return ({
        "commands": commands,
        "environment": environment,
        "includes": includes,
        "defines": defines,
        "libraries": [f.path for f in depset(libraries).to_list()],
        "link_flags": ctx.fragments.cpp.linkopts + extra_link_flags,
        "tools": {name: f.path for name, f in payloads.executables.items()},
    }, depset(libraries, transitive = [cc.all_files, payloads.inputs] + native_inputs), payloads.files_to_run)

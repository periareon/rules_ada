"""GNAT toolchain repository configuration."""

PLATFORM_TO_CONSTRAINTS = {
    "darwin-aarch64": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "darwin-x86_64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "linux-aarch64": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "linux-x86_64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "windows-x86_64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

_GNAT_TOOLCHAIN_BUILD_TEMPLATE = """\
load("@rules_ada//ada:ada_toolchain.bzl", "ada_toolchain")

filegroup(
    name = "ada_std",
    srcs = glob([
        "{adalib}/**",
        "{adainclude}/**",
    ]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "compiler_lib",
    srcs = glob(
        [
            "lib/**",
            "libexec/**",
        ],
        exclude = [
            "{adalib}/**",
            "{adainclude}/**",
        ],
    ),
    visibility = ["//visibility:public"],
)

ada_toolchain(
    name = "ada_toolchain",
    compiler = "{compiler}",
    binder = "{binder}",
    ar = {ar},
    gcov = {gcov},
    ada_std = ":ada_std",
    compiler_lib = ":compiler_lib",
    static_runtime_lib = [{static_runtime_lib}],
    dynamic_runtime_lib = [{dynamic_runtime_lib}],
    args = [{args}],
    known_features = ["@rules_ada//ada/toolchains/features:static_libgcc"],
    enabled_features = [{enabled_features}],
    artifact_name_patterns = {{{artifact_name_patterns}}},
    target_triple = "{target_triple}",
    visibility = ["//visibility:public"],
)
"""

def _find_runtime_paths(repository_ctx):
    """Discover runtime library and tool paths inside the extracted GNAT archive.

    Returns a struct with adalib, adainclude, gcc_lib paths and tool binaries.
    """
    repo_prefix = str(repository_ctx.path("")) + "/"
    lib_gcc = repository_ctx.path("lib/gcc")
    if not lib_gcc.exists:
        fail("Expected lib/gcc directory not found in GNAT archive")

    adalib_rel = None
    adainclude_rel = None
    gcc_lib_rel = None
    target_triple = None

    for triplet_entry in lib_gcc.readdir():
        for version_entry in triplet_entry.readdir():
            adalib = version_entry.get_child("adalib")
            adainclude = version_entry.get_child("adainclude")
            if adalib.exists:
                adalib_rel = str(adalib).removeprefix(repo_prefix)
                gcc_lib_rel = str(version_entry).removeprefix(repo_prefix)
                target_triple = triplet_entry.basename
                if adainclude.exists:
                    adainclude_rel = str(adainclude).removeprefix(repo_prefix)

    if not adalib_rel:
        fail("Could not find adalib directory in GNAT archive")

    def _find_tool(name):
        """Find a tool binary, checking for the .exe suffix on Windows."""
        for ext in ["", ".exe"]:
            if repository_ctx.path(name + ext).exists:
                return name + ext
        return None

    compiler_path = _find_tool("bin/gcc")
    if not compiler_path:
        fail("Could not find gcc compiler in GNAT archive")

    binder_path = _find_tool("bin/gnatbind")
    if not binder_path:
        fail("Could not find gnatbind in GNAT archive")

    ar_path = _find_tool("bin/ar")

    gcov_path = _find_tool("bin/gcov")

    return struct(
        adalib = adalib_rel,
        adainclude = adainclude_rel or adalib_rel.replace("adalib", "adainclude"),
        gcc_lib = gcc_lib_rel,
        target_triple = target_triple,
        compiler = compiler_path,
        binder = binder_path,
        ar = ar_path,
        gcov = gcov_path,
    )

def _quoted(items):
    """Render a list of strings as the body of a BUILD list literal."""
    return ", ".join(['"%s"' % item for item in items])

def _gnat_repository_impl(repository_ctx):
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        integrity = repository_ctx.attr.integrity,
        stripPrefix = repository_ctx.attr.strip_prefix,
    )

    rt = _find_runtime_paths(repository_ctx)

    platform = repository_ctx.attr.platform

    # Static archives are scanned once, in order, by GNU ld: libgnarl (the
    # tasking runtime) references symbols in libgnat, so it must come first.
    # This is the order gnatlink uses (-lgnarl -lgnat). The list is explicit
    # on purpose: a glob would sort libgcc.a first.
    static_runtime_lib = [
        "%s/libgnarl.a" % rt.adalib,
        "%s/libgnat.a" % rt.adalib,
        "%s/libgcc.a" % rt.gcc_lib,
    ]
    for archive in static_runtime_lib:
        if not repository_ctx.path(archive).exists:
            fail("GNAT archive is missing the runtime library %s" % archive)

    # libatomic.a, shipped by the aarch64 toolchains, is needed for outline
    # atomics.
    if repository_ctx.path("lib/libatomic.a").exists:
        static_runtime_lib.append("lib/libatomic.a")

    dynamic_runtime_lib = []
    artifact_name_patterns = {}

    # The hermetic toolchains follow gnatlink wherever doing so keeps outputs
    # reproducible across machines and free of build-host dependencies; each
    # departure below says what gnatlink does instead. See "Differences from
    # gnatlink" in docs/src/toolchains.md.
    #
    # libgcc is linked statically on every platform. That is gnatlink's own
    # default on Linux and Windows and keeps binaries off the host's
    # libgcc_s. On macOS gnatlink defaults to the shared libgcc_s.1.1.dylib
    # found through absolute rpaths into the GNAT installation, a shape that
    # is neither reproducible nor relocatable; the unwinder is libSystem's
    # either way, so nothing is lost. A target that needs the shared libgcc
    # (one unwinder shared with dlopen'd C++ or JIT code) disables the
    # feature and, on macOS, gets the dylib staged next to it.
    enabled_features = ["@rules_ada//ada/toolchains/features:static_libgcc"]

    # The link line comes from the arg sets rules_ada ships per platform
    # family; see ada/toolchains/args/*/BUILD.bazel for what each flag does.
    if "linux" in platform:
        args = [
            "@rules_ada//ada/toolchains/args/elf:link_line",
            "@rules_ada//ada/toolchains/args/elf:linux_system_libs",
        ]
    elif "darwin" in platform:
        # gnatlink leaves the driver's absolute rpaths and deployment target
        # alone; nodefaultrpaths drops the former for reproducibility and the
        # link line mirrors the C/C++ toolchain's deployment target so Ada
        # and C/C++ objects agree.
        args = [
            "@rules_ada//ada/toolchains/args/darwin:link_line",
            "@rules_ada//ada/toolchains/args/darwin:sysroot_from_env",
            "@rules_ada//ada/toolchains/args/darwin:nodefaultrpaths",
        ]
        if repository_ctx.path("lib/libgcc_s.1.1.dylib").exists:
            dynamic_runtime_lib.append("lib/libgcc_s.1.1.dylib")
    elif "windows" in platform:
        args = ["@rules_ada//ada/toolchains/args/windows:link_line"]
        artifact_name_patterns = {
            "executable": "%{name}.exe",
            "shared_library": "%{name}.dll",
        }
    else:
        fail("Unsupported platform %s" % platform)

    repository_ctx.file("BUILD.bazel", _GNAT_TOOLCHAIN_BUILD_TEMPLATE.format(
        adalib = rt.adalib,
        adainclude = rt.adainclude,
        compiler = rt.compiler,
        binder = rt.binder,
        ar = "\"{}\"".format(rt.ar) if rt.ar else "None",
        gcov = "\"{}\"".format(rt.gcov) if rt.gcov else "None",
        static_runtime_lib = _quoted(static_runtime_lib),
        dynamic_runtime_lib = _quoted(dynamic_runtime_lib),
        args = _quoted(args),
        enabled_features = _quoted(enabled_features),
        artifact_name_patterns = ", ".join(['"%s": "%s"' % kv for kv in artifact_name_patterns.items()]),
        target_triple = rt.target_triple,
    ))

gnat_repository = repository_rule(
    doc = "Downloads a pre-built hermetic-gnat archive and creates an ada_toolchain target.",
    implementation = _gnat_repository_impl,
    attrs = {
        "integrity": attr.string(
            doc = "Integrity hash of the archive (sha256-<base64>).",
            mandatory = True,
        ),
        "platform": attr.string(
            doc = "The exec platform of the toolchain",
            mandatory = True,
        ),
        "strip_prefix": attr.string(
            doc = "Directory prefix to strip from the extracted archive.",
            mandatory = True,
        ),
        "urls": attr.string_list(
            doc = "URLs to download the GNAT archive from.",
            mandatory = True,
        ),
    },
)

_HUB_TOOLCHAIN_TEMPLATE = """\
toolchain(
    name = "{name}",
    exec_compatible_with = {exec_compatible_with},
    target_settings = {target_settings},
    toolchain = "{toolchain}",
    toolchain_type = "@rules_ada//ada:toolchain_type",
    visibility = ["//visibility:public"],
)
"""

def _gnat_toolchain_hub_impl(repository_ctx):
    entries = []
    for name in repository_ctx.attr.toolchain_names:
        label = repository_ctx.attr.toolchain_labels[name]
        constraints = repository_ctx.attr.exec_compatible_with.get(name, [])
        settings = repository_ctx.attr.target_settings.get(name, [])
        entries.append(_HUB_TOOLCHAIN_TEMPLATE.format(
            name = name,
            exec_compatible_with = repr(constraints),
            target_settings = repr(settings),
            toolchain = label,
        ))

    repository_ctx.file("BUILD.bazel", "\n".join(entries))

gnat_toolchain_hub = repository_rule(
    doc = "Generates a repository with toolchain() targets for all configured GNAT platforms.",
    implementation = _gnat_toolchain_hub_impl,
    attrs = {
        "exec_compatible_with": attr.string_list_dict(
            doc = "Map from toolchain name to execution platform constraints.",
            mandatory = True,
        ),
        "target_settings": attr.string_list_dict(
            doc = "Map from toolchain name to config_settings that must match for this toolchain.",
            mandatory = True,
        ),
        "toolchain_labels": attr.string_dict(
            doc = "Map from toolchain name to the label of the ada_toolchain target.",
            mandatory = True,
        ),
        "toolchain_names": attr.string_list(
            doc = "Ordered list of toolchain names.",
            mandatory = True,
        ),
    },
)

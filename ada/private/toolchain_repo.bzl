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
    compiler = "bin/gcc",
    binder = "bin/gnatbind",
    ar = "{ar}",
    gcov = "{gcov}",
    ada_std = ":ada_std",
    compiler_lib = ":compiler_lib",
    link_flags = [{link_flags}],
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

    for triplet_entry in lib_gcc.readdir():
        for version_entry in triplet_entry.readdir():
            adalib = version_entry.get_child("adalib")
            adainclude = version_entry.get_child("adainclude")
            if adalib.exists:
                adalib_rel = str(adalib).removeprefix(repo_prefix)
                gcc_lib_rel = str(version_entry).removeprefix(repo_prefix)
                if adainclude.exists:
                    adainclude_rel = str(adainclude).removeprefix(repo_prefix)

    if not adalib_rel:
        fail("Could not find adalib directory in GNAT archive")

    # Find ar (prefer gcc-ar, fall back to ar)
    ar_path = "bin/ar"
    for name in ["bin/gcc-ar", "bin/ar"]:
        if repository_ctx.path(name).exists:
            ar_path = name
            break

    # Find gcov
    gcov_path = "bin/gcov"
    if not repository_ctx.path(gcov_path).exists:
        gcov_path = None

    return struct(
        adalib = adalib_rel,
        adainclude = adainclude_rel or adalib_rel.replace("adalib", "adainclude"),
        gcc_lib = gcc_lib_rel,
        ar = ar_path,
        gcov = gcov_path,
    )

def _gnat_repository_impl(repository_ctx):
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        integrity = repository_ctx.attr.integrity,
        stripPrefix = repository_ctx.attr.strip_prefix,
    )

    rt = _find_runtime_paths(repository_ctx)

    link_flags = [
        '"%s/libgnat.a"' % rt.adalib,
        '"%s/libgnarl.a"' % rt.adalib,
        '"%s/libgcc.a"' % rt.gcc_lib,
    ]

    # libatomic.a is needed on aarch64 for outline atomics
    libatomic = repository_ctx.path("lib/libatomic.a")
    if libatomic.exists:
        link_flags.append('"lib/libatomic.a"')

    repository_ctx.file("BUILD.bazel", _GNAT_TOOLCHAIN_BUILD_TEMPLATE.format(
        adalib = rt.adalib,
        adainclude = rt.adainclude,
        ar = rt.ar,
        gcov = rt.gcov or "bin/gcov",
        link_flags = ", ".join(link_flags),
    ))

gnat_repository = repository_rule(
    doc = "Downloads a pre-built GNAT FSF archive and creates an ada_toolchain target.",
    implementation = _gnat_repository_impl,
    attrs = {
        "integrity": attr.string(
            doc = "Integrity hash of the archive (sha256-<base64>).",
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

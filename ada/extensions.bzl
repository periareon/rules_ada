"""# Ada module extensions"""

load(
    "//ada/private:toolchain_repo.bzl",
    "PLATFORM_TO_CONSTRAINTS",
    "gnat_repository",
    "gnat_toolchain_hub",
)
load("//ada/private:versions.bzl", "GNAT_VERSIONS")
load("//ada/private/coverage/3rdparty/crates:crates.bzl", "crate_repositories")

def _ada_impl(module_ctx):
    """Download GNAT toolchains for all supported platforms and register them.

    For each (version, platform) pair in GNAT_VERSIONS, creates a
    gnat_repository that downloads the pre-built archive, then creates
    a hub repository with toolchain() targets constrained to the
    appropriate execution platform.

    Args:
        module_ctx: The module extension context.

    Returns:
        module_ctx.extension_metadata: Extension metadata marked as reproducible.
    """
    toolchain_names = []
    toolchain_labels = {}
    exec_compatible_with = {}
    target_settings = {}

    for version, platforms in GNAT_VERSIONS.items():
        for platform, info in platforms.items():
            repo_name = "gnat__{}_{}".format(
                version.replace(".", "_").replace("-", "_"),
                platform.replace("-", "_"),
            )

            gnat_repository(
                name = repo_name,
                platform = platform,
                urls = [info["url"]],
                integrity = info["integrity"],
                strip_prefix = info["strip_prefix"],
            )

            toolchain_names.append(repo_name)
            toolchain_labels[repo_name] = "@{}//:ada_toolchain".format(repo_name)
            exec_compatible_with[repo_name] = PLATFORM_TO_CONSTRAINTS[platform]
            target_settings[repo_name] = ["@rules_ada//ada/settings:version_{}".format(version)]

    gnat_toolchain_hub(
        name = "gnat_toolchains",
        toolchain_names = toolchain_names,
        toolchain_labels = toolchain_labels,
        exec_compatible_with = exec_compatible_with,
        target_settings = target_settings,
    )

    root_module_direct_deps = ["gnat_toolchains"]
    root_module_direct_deps.extend([repo.repo for repo in crate_repositories()])

    return module_ctx.extension_metadata(
        reproducible = True,
        root_module_direct_deps = root_module_direct_deps,
        root_module_direct_dev_deps = [],
    )

ada = module_extension(
    doc = "Ada module extensions",
    implementation = _ada_impl,
)

"""# Ada settings

Definitions for all `@rules_ada//ada` settings.
"""

load(
    "@bazel_skylib//rules:common_settings.bzl",
    "string_flag",
)
load("//ada/private:versions.bzl", "DEFAULT_GNAT_VERSION", "GNAT_VERSIONS")

def version(name = "version"):
    """The target version of the GNAT toolchain."""
    string_flag(
        name = name,
        values = GNAT_VERSIONS.keys(),
        build_setting_default = DEFAULT_GNAT_VERSION,
    )

    for ver in GNAT_VERSIONS.keys():
        native.config_setting(
            name = "{}_{}".format(name, ver),
            flag_values = {str(Label("//ada/settings:{}".format(name))): ver},
        )

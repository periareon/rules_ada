"""# ada_toolchain"""

load(
    "//ada/private:providers.bzl",
    _AdaToolchainInfo = "AdaToolchainInfo",
)
load(
    "//ada/private:toolchain.bzl",
    _ada_toolchain = "ada_toolchain",
)

ada_toolchain = _ada_toolchain
AdaToolchainInfo = _AdaToolchainInfo

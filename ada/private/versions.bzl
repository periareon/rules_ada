"""GNAT toolchain versions

A mapping of platform to integrity of the archive for each GCC version in
hermetic-gnat release 2026.09.30 (https://github.com/periareon/hermetic-gnat).
"""

# AUTO-GENERATED: DO NOT MODIFY
#
# Update using the following command:
#
# ```
# bazel run //tools/update_versions
# ```

HERMETIC_GNAT_RELEASE = "2026.09.30"

GNAT_VERSIONS = {
    "15.3.0": {
        "darwin-aarch64": {
            "integrity": "sha256-sr7g8ar21ZlaFZqlYX3MUoe/rmqeeHTG1BvIQu/Gfno=",
            "strip_prefix": "gnat-aarch64-darwin-15.3.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-aarch64-darwin-15.3.0.tar.gz",
        },
        "darwin-x86_64": {
            "integrity": "sha256-svTvjTD5XZKofh5auSkatkQfmxVpS41eOh/XUtLIwA0=",
            "strip_prefix": "gnat-x86_64-darwin-15.3.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-x86_64-darwin-15.3.0.tar.gz",
        },
        "linux-aarch64": {
            "integrity": "sha256-J8HtEkUWjR48JqTe7sygwBg8ZdnRmMP8GAn5X+PfVgw=",
            "strip_prefix": "gnat-aarch64-linux-15.3.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-aarch64-linux-15.3.0.tar.gz",
        },
        "linux-x86_64": {
            "integrity": "sha256-NmA7KPv5UrHSnePScsNpML29suZzqiHNv6Ga834dCuw=",
            "strip_prefix": "gnat-x86_64-linux-15.3.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-x86_64-linux-15.3.0.tar.gz",
        },
        "windows-x86_64": {
            "integrity": "sha256-HrwizeE86L3g8FCMZ36sFRe6v/Hc6caYfyRIJEbeSuo=",
            "strip_prefix": "gnat-x86_64-windows64-15.3.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-x86_64-windows64-15.3.0.tar.gz",
        },
    },
    "16.1.0": {
        "darwin-aarch64": {
            "integrity": "sha256-DyK2HToQettn5yZQbz/P3pDGfbWTXrJZ7D169MaqaMM=",
            "strip_prefix": "gnat-aarch64-darwin-16.1.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-aarch64-darwin-16.1.0.tar.gz",
        },
        "darwin-x86_64": {
            "integrity": "sha256-/g5jIJkXZg7BPD7bEXusHkBUqT2CU5PsFfKB1FAdDgQ=",
            "strip_prefix": "gnat-x86_64-darwin-16.1.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-x86_64-darwin-16.1.0.tar.gz",
        },
        "linux-aarch64": {
            "integrity": "sha256-uPeQFB2JAr2lr9w98FOAoMUCabCgcM5syMmt6MIVIq8=",
            "strip_prefix": "gnat-aarch64-linux-16.1.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-aarch64-linux-16.1.0.tar.gz",
        },
        "linux-x86_64": {
            "integrity": "sha256-9QlCkfNUKjYL1BtjWhLk/x3rqGcZOWBz4wiGCTXeMG0=",
            "strip_prefix": "gnat-x86_64-linux-16.1.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-x86_64-linux-16.1.0.tar.gz",
        },
        "windows-x86_64": {
            "integrity": "sha256-Jp7K8zvfn8+7l/oWOYz5tNUZf3ADea12Fv7Mj2m8Dko=",
            "strip_prefix": "gnat-x86_64-windows64-16.1.0",
            "url": "https://github.com/periareon/hermetic-gnat/releases/download/2026.09.30/gnat-x86_64-windows64-16.1.0.tar.gz",
        },
    },
}

DEFAULT_GNAT_VERSION = "16.1.0"

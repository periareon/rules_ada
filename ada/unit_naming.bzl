"""# unit_naming"""

load(
    "//ada/private:unit_naming.bzl",
    _collect_units = "collect_units",
)

collect_units = _collect_units

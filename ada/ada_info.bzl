"""# ada_info"""

load(
    "//ada/private:providers.bzl",
    _AdaInfo = "AdaInfo",
    _merge_ada_infos = "merge_ada_infos",
)

AdaInfo = _AdaInfo
merge_ada_infos = _merge_ada_infos

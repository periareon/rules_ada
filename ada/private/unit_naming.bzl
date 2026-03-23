"""Group .ads/.adb files into compilation units, separating out subunits."""

_VALID_EXTS = ("ads", "adb")

def collect_units(srcs):
    """Group .ads/.adb files into compilation units, separating out subunits.

    Heuristic: a .adb whose stem contains '-' and has no matching .ads is a
    subunit. Hyphenated child-package bodies always have specs in valid Ada,
    so a hyphenated body-without-spec must be a `separate` subunit.

    Args:
        srcs: list[File] of .ads and .adb source files.

    Returns:
        A tuple (units_by_stem, subunits) where units_by_stem is a
        dict[stem] -> struct(spec, body) and subunits is a list[File].
    """
    by_stem = {}
    for f in srcs:
        base = f.basename
        stem, _, ext = base.rpartition(".")
        if ext not in _VALID_EXTS:
            fail("rules_ada: %s does not have a .ads or .adb extension" % f.path)
        existing = by_stem.get(stem, struct(spec = None, body = None))
        if ext == "ads":
            if existing.spec != None:
                fail("rules_ada: duplicate spec for unit %s: %s vs %s" %
                     (stem, existing.spec.path, f.path))
            by_stem[stem] = struct(spec = f, body = existing.body)
        else:
            if existing.body != None:
                fail("rules_ada: duplicate body for unit %s: %s vs %s" %
                     (stem, existing.body.path, f.path))
            by_stem[stem] = struct(spec = existing.spec, body = f)

    units = {}
    subunits = []
    for stem, u in by_stem.items():
        if u.spec == None and u.body != None and "-" in stem:
            subunits.append(u.body)
        else:
            units[stem] = u
    return units, subunits

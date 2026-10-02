"""Expansion of `ada_args` templates into command-line strings.

Functions that can fail take a `report` parameter (`fail` by default) so the
module can be unit tested with a recording stand-in. Starlark has neither recursion nor `while`, so
the tree of nested args is walked with an explicit stack inside a bounded
loop.
"""

# Upper bound on the frames one `ada_args` expansion may process.
_MAX_FRAMES = 100000

def _string():
    return struct(kind = "string")

def _file():
    return struct(kind = "file")

def _bool():
    return struct(kind = "bool")

def _option(inner):
    return struct(kind = "option", inner = inner)

def _list(inner):
    return struct(kind = "list", inner = inner)

def _struct(**fields):
    return struct(kind = "struct", fields = fields)

# Variable types used to validate `ada_args` targets at analysis time.
types = struct(
    string = _string(),
    file = _file(),
    bool = _bool(),
    option = _option,
    list = _list,
    struct = _struct,
)

def parse_arg(arg, report = fail):
    """Split an argument template into literal and variable segments.

    Args:
        arg: str, e.g. `-Wl,-rpath,$ORIGIN/{dir}`. `{{` and `}}` are literal
            braces.
        report: failure callback.

    Returns:
        list[struct]: each with either a `literal` or a `variable` field.
    """
    segments = []
    literal = ""
    variable = ""
    in_variable = False
    skip = False
    n = len(arg)
    for i in range(n):
        if skip:
            skip = False
            continue
        c = arg[i]
        following = arg[i + 1] if i + 1 < n else ""
        if in_variable:
            if c != "}":
                variable += c
                continue
            if not variable:
                report("ada_args: empty `{}` in %r; name the variable to expand" % arg)
                return []
            segments.append(struct(variable = variable))
            variable = ""
            in_variable = False
        elif c == "{" and following == "{":
            literal += "{"
            skip = True
        elif c == "}" and following == "}":
            literal += "}"
            skip = True
        elif c == "{":
            if literal:
                segments.append(struct(literal = literal))
                literal = ""
            in_variable = True
        elif c == "}":
            report("ada_args: unexpected `}` in %r" % arg)
            return []
        else:
            literal += c
    if in_variable:
        report("ada_args: unmatched `{` in %r" % arg)
        return []
    if literal:
        segments.append(struct(literal = literal))
    return segments

def lookup(scope, path, report = fail):
    """Resolve a dotted variable path against a scope.

    The longest dotted prefix present in `scope` wins, so a name bound by
    `iterate_over` shadows the list it iterates. Remaining components are
    struct fields. `None` short-circuits to `None`.

    Args:
        scope: dict[str, value].
        path: str such as `libraries_to_link.file`.
        report: failure callback.

    Returns:
        The value, or `None` when unset.
    """
    parts = path.split(".")
    for n in range(len(parts), 0, -1):
        key = ".".join(parts[:n])
        if key not in scope:
            continue
        value = scope[key]
        for field in parts[n:]:
            if value == None:
                return None
            if type(value) != "struct" or not hasattr(value, field):
                report("ada_args: variable %r has no field %r" % (key, field))
                return None
            value = getattr(value, field)
        return value
    report("ada_args: unknown variable %r (known: %s)" % (path, ", ".join(sorted(scope.keys()))))
    return None

def is_unset(value):
    """Whether `requires_not_none` / `requires_none` treat a value as absent (None or empty list)."""
    return value == None or (type(value) == "list" and len(value) == 0)

def render(value, report = fail):
    """Render one scalar as a command-line string.

    Args:
        value: str or an object with a `path` attribute (a File).
        report: failure callback.

    Returns:
        str: the argument text.
    """
    if type(value) == "string":
        return value
    if hasattr(value, "path"):
        return value.path
    report("ada_args: cannot render a %s on the command line; lists need `iterate_over` or a bare `{name}` argument, bools only drive `requires_*`" % type(value))
    return ""

def format_arg(arg, scope, report = fail):
    """Expand one argument template.

    Args:
        arg: str template.
        scope: dict of variables.
        report: failure callback.

    Returns:
        list[str]: one string, or one per element when the whole argument is
            a single placeholder naming a list.
    """
    segments = parse_arg(arg, report)
    if len(segments) == 1 and hasattr(segments[0], "variable"):
        value = lookup(scope, segments[0].variable, report)
        if value == None:
            report("ada_args: variable %r is unset in %r; guard the argument with `requires_not_none`" % (segments[0].variable, arg))
            return []
        if type(value) == "list":
            return [render(v, report) for v in value]
        return [render(value, report)]

    out = ""
    for segment in segments:
        if hasattr(segment, "literal"):
            out += segment.literal
            continue
        value = lookup(scope, segment.variable, report)
        if value == None:
            report("ada_args: variable %r is unset in %r; guard the argument with `requires_not_none`" % (segment.variable, arg))
            return []
        if type(value) == "list":
            report("ada_args: list variable %r cannot be interpolated into %r; use `iterate_over` or make it the whole argument" % (segment.variable, arg))
            return []
        out += render(value, report)
    return [out]

def _requires_satisfied(nested, scope, report):
    if nested.requires_not_none != None:
        return not is_unset(lookup(scope, nested.requires_not_none, report))
    if nested.requires_none != None:
        return is_unset(lookup(scope, nested.requires_none, report))
    for name, wanted in (("requires_true", True), ("requires_false", False)):
        path = getattr(nested, name)
        if path == None:
            continue
        value = lookup(scope, path, report)
        if type(value) != "bool":
            report("ada_args: `%s = %r` needs a bool variable, got %s" % (name, path, type(value)))
            return False
        return value == wanted
    return True

def expand_nested(root, scope, report = fail):
    """Expand one `ada_args` tree.

    Args:
        root: AdaNestedArgsInfo at the root of the tree.
        scope: dict of variables for the action.
        report: failure callback.

    Returns:
        list[str]: expanded arguments in order.
    """
    out = []

    # Frames are (node, scope, bound): `bound` marks a frame whose
    # `iterate_over` element is already in `scope`. Children are pushed in
    # reverse so popping preserves declaration order.
    stack = [(root, scope, False)]
    for _ in range(_MAX_FRAMES):
        if not stack:
            break
        node, node_scope, bound = stack.pop()
        if not bound:
            if not _requires_satisfied(node, node_scope, report):
                continue
            if node.iterate_over != None:
                value = lookup(node_scope, node.iterate_over, report)
                if value == None:
                    continue
                if type(value) != "list":
                    report("ada_args: `iterate_over = %r` needs a list variable, got %s" % (node.iterate_over, type(value)))
                    continue
                for item in reversed(value):
                    stack.append((node, node_scope | {node.iterate_over: item}, True))
                continue
        for arg in node.args:
            out.extend(format_arg(arg, node_scope, report))
        for child in reversed(node.nested):
            stack.append((child, node_scope, False))
    if stack:
        report("ada_args: expansion of %s exceeded %d frames" % (root.label, _MAX_FRAMES))
    return out

def expand_args(args_infos, action, variables, report = fail):
    """Expand every `ada_args` that applies to an action.

    Args:
        args_infos: list[AdaArgsInfo] in command-line order.
        action: str action name.
        variables: dict of variables provided by the rule for this action.
        report: failure callback.

    Returns:
        list[str]: the arguments to append after the tool.
    """
    out = []
    for info in args_infos:
        if action not in info.actions:
            continue
        out.extend(expand_nested(info.nested, dict(variables), report))
    return out

def _unwrap(var_type):
    """Strip `option` wrappers; placeholders may name optional variables."""
    for _ in range(8):
        if var_type == None or var_type.kind != "option":
            return var_type
        var_type = var_type.inner
    return var_type

def _lookup_type(bindings, path, report):
    parts = path.split(".")
    for n in range(len(parts), 0, -1):
        key = ".".join(parts[:n])
        if key not in bindings:
            continue
        var_type = bindings[key]
        for field in parts[n:]:
            var_type = _unwrap(var_type)
            if var_type == None or var_type.kind != "struct" or field not in var_type.fields:
                report("ada_args: variable %r has no field %r" % (key, field))
                return None
            var_type = var_type.fields[field]
        return var_type
    report("ada_args: unknown variable %r for this action (known: %s)" % (path, ", ".join(sorted(bindings.keys())) or "none"))
    return None

def _check_placeholder(arg, bindings, report):
    segments = parse_arg(arg, report)
    whole = len(segments) == 1 and hasattr(segments[0], "variable")
    for segment in segments:
        if hasattr(segment, "literal"):
            continue
        var_type = _unwrap(_lookup_type(bindings, segment.variable, report))
        if var_type == None:
            continue
        if var_type.kind == "list":
            if not whole:
                report("ada_args: list variable %r cannot be interpolated into %r; use `iterate_over` or make it the whole argument" % (segment.variable, arg))
                continue
            var_type = _unwrap(var_type.inner)
        if var_type.kind not in ("string", "file"):
            report("ada_args: variable %r in %r is a %s and cannot be rendered" % (segment.variable, arg, var_type.kind))

def validate_args(args_info, action_variables, report = fail):
    """Check an `ada_args` tree against the variables of each of its actions.

    Args:
        args_info: AdaArgsInfo.
        action_variables: dict[str, dict[str, type]] per action.
        report: failure callback.
    """
    for action in args_info.actions:
        if action not in action_variables:
            report("ada_args: unknown action %r (expected one of %s)" % (action, ", ".join(sorted(action_variables.keys()))))
            continue
        stack = [(args_info.nested, dict(action_variables[action]))]
        for _ in range(_MAX_FRAMES):
            if not stack:
                break
            node, bindings = stack.pop()
            for name in ("requires_true", "requires_false"):
                path = getattr(node, name)
                if path != None:
                    var_type = _unwrap(_lookup_type(bindings, path, report))
                    if var_type != None and var_type.kind != "bool":
                        report("ada_args: `%s = %r` needs a bool variable, got %s" % (name, path, var_type.kind))
            for name in ("requires_not_none", "requires_none"):
                path = getattr(node, name)
                if path != None:
                    var_type = _lookup_type(bindings, path, report)
                    if var_type != None and var_type.kind not in ("option", "list"):
                        report("ada_args: `%s = %r` needs an optional or list variable, got %s" % (name, path, var_type.kind))
            if node.iterate_over != None:
                var_type = _unwrap(_lookup_type(bindings, node.iterate_over, report))
                if var_type != None:
                    if var_type.kind != "list":
                        report("ada_args: `iterate_over = %r` needs a list variable, got %s" % (node.iterate_over, var_type.kind))
                    else:
                        bindings = bindings | {node.iterate_over: var_type.inner}
            for arg in node.args:
                _check_placeholder(arg, bindings, report)
            for child in reversed(node.nested):
                stack.append((child, bindings))

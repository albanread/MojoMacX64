#!/usr/bin/env python3
"""Can (linkage name, local name, decl file, decl line) identify a Mojo local?

The semantic sidecar needs a post-link join: match each variable die in the
final dSYM to the compiler's semantic record for it. That join is done with a
"natural tuple" of things both sides know. This asks whether the tuple is
actually discriminating, on a real dSYM.

Two failure modes, and only one of them is fatal:

  MULTIPLICITY  one source entity described by several dies (the same
                function emitted into several compile units). Not an error --
                but the join map MUST be one-record-to-many-offsets, or the
                dies it drops become unresolvable at debug time.

  AMBIGUITY     one tuple covering genuinely different source entities. This
                is fatal: the join cannot decide which record a die belongs
                to, and will attach the wrong semantic type.

Types are compared by NAME, never by die offset: the same type has a
different offset in every compile unit, so offsets measure duplication rather
than disagreement.

  ./dwarf-identity-collisions.py Program.dSYM
"""
import collections
import re
import subprocess
import sys

VAR_TAGS = {"DW_TAG_variable", "DW_TAG_formal_parameter"}
SCOPE_TAGS = {"DW_TAG_subprogram", "DW_TAG_inlined_subroutine"}


def load(dsym):
    out = subprocess.run(["dwarfdump", "--debug-info", dsym],
                         capture_output=True, text=True).stdout
    dies, order, cur = {}, [], None
    for line in out.splitlines():
        m = re.match(r"^(0x[0-9a-f]+):(\s+)(DW_TAG_\w+)", line)
        if m:
            cur = {"off": m.group(1), "depth": len(m.group(2)),
                   "tag": m.group(3), "attrs": {}}
            dies[cur["off"]] = cur
            order.append(cur)
            continue
        if re.match(r"^0x[0-9a-f]+:\s+NULL", line):
            cur = None
            continue
        m = re.search(r"(DW_AT_\w+)\s+\((.*)\)\s*$", line)
        if m and cur is not None:
            cur["attrs"][m.group(1)] = m.group(2).strip()
    return dies, order


def _ref(v):
    m = re.match(r"^(0x[0-9a-f]+)", v or "")
    return m.group(1) if m else None


def attr(dies, die, name, seen=None):
    """Read an attribute, following abstract_origin/specification links."""
    if die is None:
        return None
    seen = seen or set()
    if die["off"] in seen:
        return None
    seen.add(die["off"])
    if name in die["attrs"]:
        return die["attrs"][name]
    for link in ("DW_AT_abstract_origin", "DW_AT_specification"):
        target = _ref(die["attrs"].get(link))
        if target and target in dies:
            found = attr(dies, dies[target], name, seen)
            if found is not None:
                return found
    return None


def canonical(dies, die):
    """The declaration die an inlined instance inherits from, or itself."""
    seen = set()
    while True:
        target = _ref(die["attrs"].get("DW_AT_abstract_origin"))
        if not target or target not in dies or target in seen:
            return die
        seen.add(target)
        die = dies[target]


def type_name(dies, die):
    raw = attr(dies, die, "DW_AT_type") or ""
    m = re.search(r'"(.*)"\s*$', raw)
    return m.group(1) if m else raw


def run(dsym):
    dies, order = load(dsym)

    stack, enclosing = [], {}
    for die in order:
        while stack and stack[-1]["depth"] >= die["depth"]:
            stack.pop()
        if die["tag"] in VAR_TAGS:
            for scope in reversed(stack):
                if scope["tag"] in SCOPE_TAGS:
                    enclosing[die["off"]] = scope
                    break
        stack.append(die)

    groups = collections.defaultdict(list)
    no_linkage = 0
    for die in order:
        if die["tag"] not in VAR_TAGS:
            continue
        scope = enclosing.get(die["off"])
        linkage = attr(dies, scope, "DW_AT_linkage_name")
        if linkage is None:
            no_linkage += 1
        key = (linkage or attr(dies, scope, "DW_AT_name"),
               attr(dies, die, "DW_AT_name"),
               attr(dies, die, "DW_AT_decl_file"),
               attr(dies, die, "DW_AT_decl_line"))
        groups[key].append(canonical(dies, die))

    unique = multiplicity = ambiguity = 0
    examples = []
    for key, members in groups.items():
        decls = {d["off"] for d in members}
        if len(decls) == 1:
            unique += 1
            continue
        variants = {(type_name(dies, dies[o]),
                     dies[o]["attrs"].get("DW_AT_decl_column")) for o in decls}
        if len(variants) == 1:
            multiplicity += 1
        else:
            ambiguity += 1
            if len(examples) < 10:
                examples.append((key, len(decls), sorted(variants)))

    total_vars = sum(len(v) for v in groups.values())
    print(f"dSYM: {dsym}")
    print(f"  variable/formal dies              : {total_vars}")
    print(f"  scopes with no linkage name       : {no_linkage}")
    print(f"  distinct tuples                   : {len(groups)}")
    print(f"  unambiguous (one declaration)     : {unique}")
    print(f"  MULTIPLICITY (one entity, N dies) : {multiplicity}")
    print(f"  AMBIGUITY (different entities)    : {ambiguity}")
    for key, n, variants in examples:
        print(f"    name={key[1]} line={key[3]} declarations={n}")
        for tname, col in variants:
            print(f"      type={tname!r} column={col}")
        print(f"      in: {(key[0] or '')[:100]}")
    return 1 if ambiguity else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(run(sys.argv[1]))

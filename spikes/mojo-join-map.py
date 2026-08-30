#!/usr/bin/env python3
"""Build the post-link join map: DWARF variable dies -> Mojo semantic records.

The semantic sidecar answers "what type is this variable"; DWARF answers
"where are its bits". This is the join between them, and it has to be built
*after* dsymutil, because dsymutil rewrites die offsets.

The shape that matters is one-to-many. A quarter of all natural tuples in a
real dSYM describe ONE source entity through SEVERAL dies -- the same function
emitted into several compile units, plus an abstract declaration behind every
inlined instance. A 1:1 table silently drops those dies, and the debugger then
fails to resolve a type depending on which compile unit it happened to stop
in, which presents as flakiness rather than as a missing feature. So:

    record  ->  many die offsets      (one semantic entity, many descriptions)
    offset  ->  exactly one record    (what the debugger looks up)

Records are keyed by a deterministic digest of the natural tuple, not by
allocation order, so an incremental rebuild that changes one function does not
renumber every record. The eventual mojo_type_id from the compiler replaces
the digest; the shape of the map does not change when it does.

  ./mojo-join-map.py Program.dSYM -o Program.mojojoin
"""
import argparse
import collections
import hashlib
import json
import re
import subprocess
import sys

SCHEMA = 1
VAR_TAGS = {"DW_TAG_variable", "DW_TAG_formal_parameter"}
SCOPE_TAGS = {"DW_TAG_subprogram", "DW_TAG_inlined_subroutine"}


def dwarfdump(*args):
    return subprocess.run(["dwarfdump", *args],
                          capture_output=True, text=True).stdout


def uuid_of(dsym):
    """The dSYM's UUID. The map is only valid for the binary that has it."""
    m = re.search(r"UUID:\s*([0-9A-Fa-f-]+)", dwarfdump("--uuid", dsym))
    return m.group(1) if m else None


def load(dsym):
    dies, order, cur = {}, [], None
    for line in dwarfdump("--debug-info", dsym).splitlines():
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


def unquote(v):
    if v is None:
        return None
    m = re.match(r'^"(.*)"$', v)
    return m.group(1) if m else v


def type_name(dies, die):
    """Type by NAME. Never by die offset: the same type has a different offset
    in every compile unit, so offsets would split one record into many."""
    raw = attr(dies, die, "DW_AT_type") or ""
    m = re.search(r'"(.*)"\s*$', raw)
    return m.group(1) if m else (raw or None)


def enclosing_scopes(order):
    stack, out = [], {}
    for die in order:
        while stack and stack[-1]["depth"] >= die["depth"]:
            stack.pop()
        if die["tag"] in VAR_TAGS:
            for scope in reversed(stack):
                if scope["tag"] in SCOPE_TAGS:
                    out[die["off"]] = scope
                    break
        stack.append(die)
    return out


def record_key(dies, die, scope):
    """The natural tuple. Everything in it is available to both the compiler
    and a post-link reader, which is what makes the join possible at all."""
    return {
        "function": unquote(attr(dies, scope, "DW_AT_linkage_name")
                            or attr(dies, scope, "DW_AT_name")),
        "variable": unquote(attr(dies, die, "DW_AT_name")),
        "file": unquote(attr(dies, die, "DW_AT_decl_file")),
        "line": unquote(attr(dies, die, "DW_AT_decl_line")),
        "type": type_name(dies, die),
    }


def record_id(key):
    """Deterministic: content, not allocation order, so an incremental
    rebuild does not renumber unrelated records."""
    blob = "\x1f".join(str(key[k]) for k in
                       ("function", "variable", "file", "line", "type"))
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def build(dsym):
    dies, order = load(dsym)
    scopes = enclosing_scopes(order)

    records, offset_to_record = {}, {}
    for die in order:
        if die["tag"] not in VAR_TAGS:
            continue
        key = record_key(dies, die, scopes.get(die["off"]))
        rid = record_id(key)
        rec = records.setdefault(rid, {**key, "dies": []})
        rec["dies"].append(die["off"])
        offset_to_record[die["off"]] = rid

    return {
        "schema": SCHEMA,
        "uuid": uuid_of(dsym),
        "records": records,
        "offsets": offset_to_record,
    }


def validate(dsym, doc):
    """A map nobody checked is a map that quietly loses dies."""
    dies, order = load(dsym)
    all_vars = [d["off"] for d in order if d["tag"] in VAR_TAGS]
    problems = []

    missing = [o for o in all_vars if o not in doc["offsets"]]
    if missing:
        problems.append(f"{len(missing)} variable dies absent from the map")

    for off in all_vars:
        rid = doc["offsets"].get(off)
        if rid and off not in doc["records"][rid]["dies"]:
            problems.append(f"die {off} maps to {rid} but is not in its list")
            break

    # Records differing ONLY by type are the known variadic-unroll ambiguity:
    # same function, name and line, in one lexical block. Report, do not hide.
    by_tuple = collections.defaultdict(set)
    for rid, rec in doc["records"].items():
        by_tuple[(rec["function"], rec["variable"], rec["file"],
                  rec["line"])].add(rid)
    ambiguous = {k: v for k, v in by_tuple.items() if len(v) > 1}

    if not doc["uuid"]:
        problems.append("no dSYM UUID: the map cannot be tied to a binary")

    return all_vars, problems, ambiguous


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dsym")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()

    doc = build(args.dsym)
    all_vars, problems, ambiguous = validate(args.dsym, doc)

    fanout = collections.Counter(len(r["dies"]) for r in doc["records"].values())
    shared = sum(n for w, n in fanout.items() if w > 1)

    print(f"dSYM   : {args.dsym}")
    print(f"UUID   : {doc['uuid']}")
    print(f"  variable dies mapped        : {len(doc['offsets'])} / {len(all_vars)}")
    print(f"  semantic records            : {len(doc['records'])}")
    print(f"  records with >1 die         : {shared}"
          f"  (max fan-out {max(fanout) if fanout else 0})")
    print(f"  tuples needing type to split: {len(ambiguous)}")
    for k, v in list(ambiguous.items())[:4]:
        print(f"    {k[1]} line {k[3]} -> {len(v)} records")
    print(f"  validation                  : "
          f"{'OK' if not problems else 'FAILED'}")
    for p in problems:
        print(f"    ! {p}")

    if args.output:
        with open(args.output, "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
        print(f"  written                     : {args.output}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Storage-layout gate for the F-01 upgrade (design 2A.4, 6.6).

Run from the repo root:  python3 test/layout/check_storage_layout.py
Self-check of the gate:  python3 test/layout/check_storage_layout.py --self-test

Compares `forge inspect` output with the layouts pinned next to this file:
  * escrow against production baseline 86bbb204: every baseline variable keeps
    its label, slot, offset and encoded type; new variables only after the last
    one. The one allowed retype is `_vault`, contract to contract, same slot.
  * vault namespace against its pin: ManifestEntry and Expected are frozen;
    Custody and ReleaseRecord (direct mapping values) and VaultStorage itself
    may only grow at their end.
AST ids in type names are stripped: they change with every compile.
"""
import copy, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ESCROW = "NewTradeEscrowV2"
VAULT = "VaultStorageLayoutProbe"
ALLOWED_RETYPE = {"_vault"}
FROZEN = {"ManifestEntry", "Expected"}
GROW_AT_END = {"Custody", "ReleaseRecord", "VaultStorage"}


def inspect(target):
    out = subprocess.run(["forge", "inspect", target, "storageLayout", "--json"],
                         check=True, capture_output=True, text=True, env={**os.environ, "FOUNDRY_OFFLINE": "true"}).stdout
    return json.loads(out[out.index("{"):])


def norm(t):
    return re.sub(r"\)\d+", ")", t)


def shape(types, t, seen=()):
    """The fully expanded, id-free shape of a type."""
    info = types[t]
    out = {"label": re.sub(r"\)\d+", ")", info["label"]), "encoding": info["encoding"], "bytes": info["numberOfBytes"]}
    if t in seen:
        return out
    seen = seen + (t,)
    if "members" in info:
        out["members"] = [member(types, m, seen) for m in info["members"]]
    for k in ("key", "value", "base"):
        if k in info:
            out[k] = shape(types, info[k], seen)
    return out


def member(types, m, seen=()):
    return {"label": m["label"], "slot": m["slot"], "offset": m["offset"], "type": shape(types, m["type"], seen)}


def flatten(layout):
    return [member(layout["types"], s) for s in layout["storage"]]


def struct_name(s):
    return s["label"].split(".")[-1].replace("struct ", "")


def compare_struct(path, old, new, errors):
    name = struct_name(old)
    a, b = old["members"], new.get("members", [])
    if len(b) < len(a):
        errors.append(f"{path}: member removed ({len(a)} -> {len(b)})")
    for i, (x, y) in enumerate(zip(a, b)):
        compare_member(f"{path}.{x['label']}", x, y, errors)
    if len(b) > len(a) and name not in GROW_AT_END:
        errors.append(f"{path}: {name} is frozen or embedded and may not grow")
    if old["bytes"] != new["bytes"] and name not in GROW_AT_END:
        errors.append(f"{path}: {name} size {old['bytes']} -> {new['bytes']}")


def compare_type(path, old, new, errors):
    if old["encoding"] != new["encoding"]:
        errors.append(f"{path}: encoding {old['encoding']} -> {new['encoding']}")
    if "members" in old:
        if "members" not in new:
            errors.append(f"{path}: no longer a struct")
            return
        if struct_name(old) != struct_name(new):
            errors.append(f"{path}: struct {old['label']} -> {new['label']}")
        compare_struct(path, old, new, errors)
        return
    if old["label"] != new["label"] or old["bytes"] != new["bytes"]:
        errors.append(f"{path}: type {old['label']}/{old['bytes']} -> {new['label']}/{new['bytes']}")
    for k in ("key", "value", "base"):
        if k in old:
            if k not in new:
                errors.append(f"{path}: lost {k}")
            else:
                compare_type(f"{path}[{k}]", old[k], new[k], errors)


def compare_member(path, old, new, errors, allow_retype=False):
    for k in ("label", "slot", "offset"):
        if old[k] != new[k]:
            errors.append(f"{path}: {k} {old[k]} -> {new[k]}")
    if allow_retype:
        a, b = old["type"], new["type"]
        if a["label"].split()[0] != "contract" or b["label"].split()[0] != "contract" or a["bytes"] != b["bytes"]:
            errors.append(f"{path}: retype must stay contract to contract, same size")
        return
    compare_type(path, old["type"], new["type"], errors)


def compare_top(old, new, allowed=frozenset()):
    errors = []
    if len(new) < len(old):
        errors.append(f"variable removed ({len(old)} -> {len(new)})")
    for x, y in zip(old, new):
        compare_member(x["label"], x, y, errors, x["label"] in allowed)
    return errors


def compare_vault(old, new):
    errors = []
    if len(old) != 1 or len(new) != 1:
        return [f"probe must declare exactly one variable: {len(old)}, {len(new)}"]
    compare_member("probe", old[0], new[0], errors)
    return errors


def pin(name):
    with open(os.path.join(HERE, name)) as f:
        return json.load(f)


def self_test():
    base = pin("vault-namespace.json")
    assert compare_vault(base, copy.deepcopy(base)) == [], "identical layout must pass"
    vs = lambda d: d[0]["type"]["members"]
    field = lambda d, n: next(m for m in vs(d) if m["label"] == n)
    def struct_of(d, n):
        t = field(d, n)["type"]
        while "members" not in t:
            t = t.get("value") or t["base"]
        return t
    def expect_fail(name, mutate):
        d = copy.deepcopy(base)
        mutate(d)
        assert compare_vault(base, d), f"mutation not caught: {name}"
        print("  caught:", name)
    def swap(d):
        m = vs(d); m[3], m[4] = m[4], m[3]
    def retype(d):
        field(d, "assetPolicyRevision")["type"]["label"] = "uint128"
    def remove(d):
        vs(d).pop()
    def grow(n, f):
        def go(d):
            s = struct_of(d, n)
            s["members"].append({"label": "x", "slot": "9", "offset": 0, "type": {"label": "uint256", "encoding": "inplace", "bytes": "32"}})
        return go
    def reorder(n):
        def go(d):
            m = struct_of(d, n)["members"]; m[0], m[1] = m[1], m[0]
        return go
    expect_fail("VaultStorage reordered", swap)
    expect_fail("VaultStorage field retyped", retype)
    expect_fail("VaultStorage field removed", remove)
    expect_fail("ManifestEntry grown", grow("manifests", 0))
    expect_fail("Expected grown", grow("expected", 0))
    expect_fail("ManifestEntry reordered", reorder("manifests"))
    expect_fail("Custody reordered", reorder("custody"))
    expect_fail("ReleaseRecord reordered", reorder("releases"))
    ok = copy.deepcopy(base)
    grow("custody", 0)(ok)
    assert compare_vault(base, ok) == [], "appending to Custody must pass"
    print("  allowed: Custody grown at its end")
    e = pin("escrow-baseline-86bbb204.json")
    assert compare_top(e, copy.deepcopy(e), ALLOWED_RETYPE) == []
    d = copy.deepcopy(e); d[6]["slot"] = "7"
    assert compare_top(e, d, ALLOWED_RETYPE), "moved _vault must fail"
    print("  caught: escrow _vault moved")
    d = copy.deepcopy(e); d[6]["type"]["label"] = "address"
    assert compare_top(e, d, ALLOWED_RETYPE), "_vault to non-contract must fail"
    print("  caught: escrow _vault retyped to non-contract")
    d = copy.deepcopy(e); d[5]["type"]["label"] = "contract Other"
    assert compare_top(e, d, ALLOWED_RETYPE), "retype of another variable must fail"
    print("  caught: another escrow variable retyped")
    d = copy.deepcopy(e); d.pop(0)
    assert compare_top(e, d, ALLOWED_RETYPE), "removal must fail"
    print("  caught: escrow variable removed")
    print("self-test ok")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    if "--pin-vault" in sys.argv:
        with open(os.path.join(HERE, "vault-namespace.json"), "w") as f:
            json.dump(flatten(inspect(VAULT)), f, indent=1, sort_keys=True)
        print("pinned vault namespace")
        return 0
    errors = compare_top(pin("escrow-baseline-86bbb204.json"), flatten(inspect(ESCROW)), ALLOWED_RETYPE)
    errors = [f"escrow: {e}" for e in errors]
    errors += [f"vault: {e}" for e in compare_vault(pin("vault-namespace.json"), flatten(inspect(VAULT)))]
    if errors:
        print("STORAGE LAYOUT GATE FAILED")
        print("\n".join(errors))
        return 1
    print("storage layout gate ok: escrow against 86bbb204, vault namespace against its pin")
    return 0


if __name__ == "__main__":
    sys.exit(main())

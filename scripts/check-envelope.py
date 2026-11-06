#!/usr/bin/env python3
"""Recorded envelopes against `--envelope-schema`, and envelope.py against the schema.

    scripts/check-envelope.py <schema.json> <envelope.py> <envelope.json>...

Stdlib only. The validator knows the keywords the schema uses and refuses any
other, so a keyword added in Swift cannot be skipped in silence.
"""
from __future__ import annotations

import ast
import copy
import json
import sys
from pathlib import Path
from typing import Any, Callable

KNOWN = {"$schema", "title", "description", "$ref", "$defs", "type", "properties", "required",
         "additionalProperties", "items", "anyOf", "contentEncoding"}
TYPES: dict[str, Callable[[Any], bool]] = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
}


def errors(value: Any, node: dict[str, Any], root: dict[str, Any], at: str = "$") -> list[str]:
    unknown = set(node) - KNOWN
    if unknown:
        return ["%s: the validator does not know %s" % (at, sorted(unknown))]
    if "$ref" in node:
        return errors(value, root["$defs"][node["$ref"].rsplit("/", 1)[1]], root, at)
    if "anyOf" in node:
        if any(not errors(value, option, root, at) for option in node["anyOf"]):
            return []
        return ["%s: matches none of %d options" % (at, len(node["anyOf"]))]
    kinds = node.get("type")
    if kinds is not None:
        kinds = [kinds] if isinstance(kinds, str) else kinds
        if not any(TYPES[k](value) for k in kinds):
            return ["%s: %s is not %s" % (at, type(value).__name__, "/".join(kinds))]
    found: list[str] = []
    if isinstance(value, list) and "items" in node:
        for i, item in enumerate(value):
            found += errors(item, node["items"], root, "%s[%d]" % (at, i))
    if isinstance(value, dict):
        properties = node.get("properties", {})
        found += ["%s: no %s" % (at, k) for k in node.get("required", []) if k not in value]
        extra = node.get("additionalProperties", True)
        for key, item in value.items():
            where = "%s.%s" % (at, key)
            if key in properties:
                found += errors(item, properties[key], root, where)
            elif extra is False:
                found.append("%s: not in the schema" % where)
            elif isinstance(extra, dict):
                found += errors(item, extra, root, where)
    return found


def expected(node: dict[str, Any]) -> str:
    """The annotation envelope.py should carry for a schema node."""
    if "$ref" in node:
        return str(node["$ref"].rsplit("/", 1)[1])
    if "anyOf" in node:
        return " | ".join(expected(option) for option in node["anyOf"])
    kind = node["type"]
    if isinstance(kind, list):
        return "Scalar" if sorted(kind) == ["boolean", "number", "string"] else "?" + "/".join(kind)
    if kind == "array":
        return "list[%s]" % expected(node["items"])
    if kind == "object":
        return "dict[str, %s]" % expected(node["additionalProperties"])
    return {"string": "str", "integer": "int", "number": "float", "boolean": "bool", "null": "None"}[kind]


def typed_dicts(path: Path) -> dict[str, dict[str, tuple[str, bool]]]:
    """Each TypedDict in the file: key -> (annotation, required)."""
    out: dict[str, dict[str, tuple[str, bool]]] = {}
    for cls in ast.parse(path.read_text()).body:
        if not isinstance(cls, ast.ClassDef) or not any(
                isinstance(b, ast.Name) and b.id == "TypedDict" for b in cls.bases):
            continue
        keys: dict[str, tuple[str, bool]] = {}
        for item in cls.body:
            if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name):
                annotation = item.annotation
                optional = (isinstance(annotation, ast.Subscript) and isinstance(annotation.value, ast.Name)
                            and annotation.value.id == "NotRequired")
                if optional:
                    assert isinstance(annotation, ast.Subscript)
                    annotation = annotation.slice
                keys[item.target.id] = (ast.unparse(annotation), not optional)
        out[cls.name] = keys
    return out


def drift(schema: dict[str, Any], envelope_py: Path) -> list[str]:
    defs: dict[str, Any] = schema["$defs"]
    classes = typed_dicts(envelope_py)
    found = ["%s is in the schema and not in envelope.py" % n for n in sorted(set(defs) - set(classes))]
    found += ["%s is in envelope.py and not in the schema" % n for n in sorted(set(classes) - set(defs))]
    for name in sorted(set(defs) & set(classes)):
        node, keys = defs[name], classes[name]
        properties, required = node["properties"], set(node["required"])
        for key in sorted(set(properties) | set(keys)):
            if key not in keys:
                found.append("%s.%s is in the schema and not in envelope.py" % (name, key))
            elif key not in properties:
                found.append("%s.%s is in envelope.py and not in the schema" % (name, key))
            else:
                want = (expected(properties[key]), key in required)
                if keys[key] != want:
                    found.append("%s.%s is %s%s in envelope.py, %s%s in the schema" % (
                        name, key, keys[key][0], "" if keys[key][1] else " (NotRequired)",
                        want[0], "" if want[1] else " (NotRequired)"))
    return found


def broken(envelope: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    """Envelopes the validator must refuse, so a pass means something."""
    changes: list[tuple[str, Callable[[dict[str, Any]], object]]] = [
        ("no text", lambda e: e.pop("text")),
        ("an unknown key", lambda e: e.update(extra=1)),
        ("aligned as a string", lambda e: e.update(aligned="yes")),
        ("a nested var", lambda e: e["ctx"]["vars"].update(x={"y": {"z": 1}})),
        ("a bool where an integer goes", lambda e: e["tokens"].append(
            {"at": True, "len": 1, "text": "x", "tag": "Noun"})),
    ]
    out = []
    for name, change in changes:
        mutated = copy.deepcopy(envelope)
        change(mutated)
        out.append((name, mutated))
    return out


SAYS: dict[str, tuple[str, Callable[[dict[str, Any]], bool]]] = {
    "plain": ("no parse, no readings, no trace",
              lambda e: not {"parse", "readings", "trace"} & set(e)),
    "parse-missing": ("no parse when the parser is not there", lambda e: "parse" not in e),
    "vectors-missing": ("no parse when the parser is not there", lambda e: "parse" not in e),
    "readings-missing": ("readings with a missing reason and no boundary",
                         lambda e: bool(e["readings"].get("missing")) and e["readings"]["boundaries"] == []),
    "readings-none": ("readings with no boundary and no missing reason",
                      lambda e: "missing" not in e["readings"] and e["readings"]["boundaries"] == []),
    "parse": ("a parse with words and no vectors",
              lambda e: bool(e["parse"]["words"]) and all("vector" not in w for w in e["parse"]["words"])),
    "vectors": ("a parse with a vector on every word",
                lambda e: bool(e["parse"]["words"]) and all("vector" in w for w in e["parse"]["words"])),
    "readings": ("readings with boundaries", lambda e: bool(e["readings"]["boundaries"])
                 and "missing" not in e["readings"]),
}


def main() -> int:
    schema = json.loads(Path(sys.argv[1]).read_text())
    failed = 0

    for line in drift(schema, Path(sys.argv[2])):
        print("  ✗ " + line)
        failed += 1
    if not failed:
        print("  ✓ envelope.py has every type, key and annotation the schema has, and no other")

    first: dict[str, Any] | None = None
    for path in map(Path, sys.argv[3:]):
        envelope = json.loads(path.read_text())
        first = first or envelope
        found = errors(envelope, schema, schema)
        if path.stem in SAYS and not SAYS[path.stem][1](envelope):
            found.append("expected " + SAYS[path.stem][0])
        said = SAYS[path.stem][0] if path.stem in SAYS else "matches the schema"
        print(("  ✓ %s: %s" if not found else "  ✗ %s: %s") % (path.name, said))
        for line in found[:10]:
            print("      " + line)
        failed += bool(found)

    if first is not None:
        for name, mutated in broken(first):
            if not errors(mutated, schema, schema):
                print("  ✗ the validator accepted an envelope with %s" % name)
                failed += 1
        reply = {"$ref": "#/$defs/Reply"}
        for good in ({}, {"text": None}, {"text": "x", "vars": {"n": 1, "b": True, "s": "", "f": 0.5}}):
            if errors(good, reply, schema):
                print("  ✗ the validator refused the reply %s" % json.dumps(good))
                failed += 1
        for bad in ({"text": 1}, {"vars": {"n": [1]}}, {"other": 1}):
            if not errors(bad, reply, schema):
                print("  ✗ the validator accepted the reply %s" % json.dumps(bad))
                failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

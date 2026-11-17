#!/usr/bin/env python3
"""Build a fake SMDB shared-memory image from a /jci/smdb/<name>.xml schema.

Independent re-implementation of what libjcismdb.so does when it creates a
database (SMDB_XML_Open + SMDB_SHMEM_Open, see LAYOUT.md). Used only to test
smdb_reader.h for self-consistency; it is NOT evidence about the real car.

  mkimage.py XML OUT [--only A,B,C] [--set NAME=VALUE ...] [--expect FILE]
  mkimage.py --sizes XML [XML ...]      # predicted sizes of the shm objects
"""
import argparse
import os
import struct
import sys
import xml.parsers.expat

T_INT, T_STRING, T_BINARY = 1, 2, 3
TYPE_NAMES = {T_INT: "int", T_STRING: "string", T_BINARY: "binary"}


def pad4(n):
    return n + (-n & 3)


def c_strtol(s):
    """strtol(s, NULL, 0) truncated to 32 bits, as the library stores it."""
    s = s.lstrip(" \t\n\v\f\r")
    neg = False
    if s[:1] in ("+", "-"):
        neg = s[0] == "-"
        s = s[1:]
    if s[:2].lower() == "0x":
        base, digits, s = 16, "0123456789abcdef", s[2:]
    elif s[:1] == "0":
        base, digits = 8, "01234567"
    else:
        base, digits = 10, "0123456789"
    v = 0
    for ch in s.lower():
        if ch not in digits:
            break
        v = v * base + digits.index(ch)
    if neg:
        v = -v
    return v & 0xFFFFFFFF


def load_schema(xml_path):
    """Elements in document order, like the expat-based vendor reader."""
    nodes = []
    parser = xml.parsers.expat.ParserCreate()
    parser.StartElementHandler = lambda name, attrs: nodes.append((name, attrs))
    with open(xml_path, "rb") as f:
        parser.Parse(f.read(), True)
    root_name, root_attrs = nodes[0]
    path = root_attrs.get("path") or root_attrs.get("Path") or None
    entries = []
    for name, attrs in nodes[1:]:
        t = attrs["type"].lower()
        value = attrs["value"]
        if t == "int":
            entries.append((name, T_INT, 4, value))
        elif t == "binary":
            entries.append((name, T_BINARY, int(attrs["size"], 0), value))
        elif t == "string":
            entries.append((name, T_STRING, int(attrs["size"], 0) + 1, value))
        else:
            raise SystemExit("unknown type %r for %r" % (t, name))
    return path, entries


def build(db_name, path, entries, overrides):
    n = len(entries)
    names_size = pad4(sum(len(e[0]) + 1 for e in entries))
    data_size = sum(pad4(e[2]) for e in entries)
    path_size = pad4(len(path) + len(db_name) + 11) if path else 0
    table_end = 16 * (n + 1)
    total = table_end + path_size + names_size + data_size

    img = bytearray(total)
    struct.pack_into("<4I", img, 0, total, n, data_size,
                     table_end if path else 0)
    if path:
        full = path + ("" if path.endswith("/") else "/")
        full += "smdb_" + db_name + ".dat"
        raw = full.encode() + b"\0"
        img[table_end:table_end + len(raw)] = raw

    name_off = table_end + path_size
    data_off = name_off + names_size
    assert data_off == total - data_size
    expect = []
    for i, (name, typ, size, value) in enumerate(entries):
        raw = name.encode() + b"\0"
        img[name_off:name_off + len(raw)] = raw
        struct.pack_into("<4I", img, 16 * (i + 1), name_off, size, typ,
                         data_off)
        if typ == T_INT:
            v = c_strtol(overrides.get(name, value))
            struct.pack_into("<I", img, data_off, v)
            shown = str(v - (1 << 32) if v & 0x80000000 else v)
        elif typ == T_STRING:
            s = overrides.get(name, value).encode()[:size - 1]
            img[data_off:data_off + len(s)] = s
            shown = '"%s"' % s.decode()
        else:  # binary defaults to zeros; an override is a hex string
            b = bytes.fromhex(overrides[name]) if name in overrides else b""
            b = b[:size]
            img[data_off:data_off + len(b)] = b
            shown = bytes(img[data_off:data_off + size]).hex().upper()
        expect.append("%d\t%s\t%s\t%d\t%s" % (i, name, TYPE_NAMES[typ], size,
                                              shown))
        name_off += len(raw)
        data_off += pad4(size)
    return bytes(img), expect, (n, total, data_size, table_end if path else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--expect")
    ap.add_argument("args", nargs="+")
    a = ap.parse_args()

    if a.sizes:
        print("%-38s %5s %8s %8s %8s" % ("database", "n", "total", "data",
                                         "path_off"))
        for xml_path in a.args:
            db = os.path.splitext(os.path.basename(xml_path))[0]
            path, entries = load_schema(xml_path)
            _, _, (n, total, data, poff) = build(db, path, entries, {})
            print("%-38s %5d %8d %8d %8d" % (db, n, total, data, poff))
        return

    xml_path, out = a.args
    db = os.path.splitext(os.path.basename(xml_path))[0]
    path, entries = load_schema(xml_path)
    if a.only:
        want = a.only.split(",")
        entries = [e for e in entries if e[0] in want]
        missing = set(want) - {e[0] for e in entries}
        if missing:
            raise SystemExit("not in schema: %s" % ", ".join(sorted(missing)))
    overrides = dict(s.split("=", 1) for s in a.set)
    img, expect, (n, total, data, poff) = build(db, path, entries, overrides)
    with open(out, "wb") as f:
        f.write(img)
    if a.expect:
        with open(a.expect, "w") as f:
            f.write("\n".join(expect) + ("\n" if expect else ""))
    sys.stderr.write("%s: n=%d total=%d data=%d path_off=%d\n"
                     % (db, n, total, data, poff))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Plays the dashboard page on the WebSocket push: reads the JSON file once
(as the page does, to wake the daemon and learn the port), then takes the
pushed samples. Also checks that a web page (its origin, or no key) is
refused, that pings are answered and frames split across reads are told
apart, and that a client that stops reading does not hold the others up.
usage: wsreader.py FILE SECONDS"""
import base64
import hashlib
import json
import os
import socket
import sys
import time

path, seconds = sys.argv[1], float(sys.argv[2])
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def connect(port, origin, path):
    s = socket.create_connection(("127.0.0.1", port), timeout=2)
    key = base64.b64encode(os.urandom(16)).decode()
    req = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
          "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n" % (port, key)
    if origin is not None:
        req += "Origin: %s\r\n" % origin
    s.sendall((req + "\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        b = s.recv(1)
        if not b:
            break
        head += b
    want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    ok = head.startswith(b"HTTP/1.1 101") and ("Sec-WebSocket-Accept: " + want).encode() in head
    return s, ok, head.split(b"\r\n")[0].decode(errors="replace")


def frame(s):
    h = s.recv(2, socket.MSG_WAITALL)
    if len(h) < 2:
        return None
    n = h[1] & 127
    if n == 126:
        n = int.from_bytes(s.recv(2, socket.MSG_WAITALL), "big")
    data = s.recv(n, socket.MSG_WAITALL) if n else b""
    return h[0], data


def masked(op, payload, fin=True, m=None):
    m = m or os.urandom(4)
    n = len(payload)
    h = bytes([(0x80 if fin else 0) | op])
    h += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + n.to_bytes(2, "big")
    return h + m + bytes(b ^ m[i & 3] for i, b in enumerate(payload))


def next_control(s, want):
    """frames until one with opcode `want` (samples keep coming in between)"""
    t0 = time.time()
    while time.time() - t0 < 2:
        f = frame(s)
        if f is None:
            return None
        if f[0] & 15 == want:
            return f
    return "none"


port, key = 0, ""
t0 = time.time()
while time.time() - t0 < 3 and not port:
    try:
        with open(path) as f:
            o = json.load(f)
            port, key = o.get("ws") or 0, o.get("wsk") or ""
    except (OSError, ValueError):
        pass
    time.sleep(0.04)
print("port from file:", port, "key length:", len(key))
if not port:
    sys.exit(1)
good = "/?k=" + key

for origin, p in (("http://example.com", good), ("null", good), ("file://", good), (None, good),
                  ("null", "/"), ("null", "/?k=" + "0" * len(key)), ("null", good + "x")):
    s, ok, line = connect(port, origin, p)
    print("origin %-20s key %-5s -> %s" % (origin, "ok" if p == good else "wrong", line))
    s.close()

# a ping is answered with its payload; a 300-byte text frame whose byte 256
# looks like a close is skipped whole; a ping and a close in one write are
# both answered; a frame split across reads is put together
s, ok, _ = connect(port, "null", good)
s.sendall(masked(9, b"hello"))
print("ping answered:", next_control(s, 10))
body = bytearray(b"x" * 300)
body[256 - 8] = 0x88                              # frame byte 256 (8-byte header: 4 + mask)
s.sendall(masked(1, bytes(body), m=bytes(4)))   # mask 0: 0x88 on the wire
time.sleep(0.15)
s.sendall(masked(9, b"p3"))
print("after 300-byte frame, ping answered:", next_control(s, 10))
p5 = masked(9, b"split")
s.sendall(p5[:3])
time.sleep(0.15)
s.sendall(p5[3:])
print("ping split across reads:", next_control(s, 10))
s.sendall(masked(9, b"p4") + masked(8, b""))
print("ping+close in one write, pong:", next_control(s, 10))
print("  then close:", next_control(s, 8))
s.close()

stall, ok, _ = connect(port, "file://", good)     # never reads again
s, ok, line = connect(port, "file://", good)
print("handshake accept key ok:", ok)
s.settimeout(1.5)
seqs, times, last, first_gap = [], [], None, None
t0 = time.time()
while time.time() - t0 < seconds:
    try:
        f = frame(s)
    except socket.timeout:
        print("TIMEOUT: nothing pushed for 1.5 s")
        break
    if f is None:
        print("closed by the daemon")
        break
    op, data = f
    o = json.loads(data)
    seqs.append(o["seq"])
    times.append(time.time())
    last = o
gaps = [round((b - a) * 1000) for a, b in zip(times, times[1:])]
span = times[-1] - times[0] if len(times) > 1 else 0
print("pushed samples=%d" % len(seqs))
if span:
    print("rate=%.1f/s gap ms: min=%d median=%d max=%d seq skipped=%d" % (
        (len(times) - 1) / span, min(gaps), sorted(gaps)[len(gaps) // 2], max(gaps),
        (seqs[-1] - seqs[0] + 1) - len(seqs)))
print("last:", json.dumps(last, separators=(",", ":"))[:160])
s.sendall(bytes([0x88, 0x80, 1, 2, 3, 4]))       # masked close, as a browser sends it
try:
    print("close answered:", frame(s))
except OSError as e:
    print("close:", e)
stall.close()

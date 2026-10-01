#!/usr/bin/env python3
"""Record when Binance bookTicker updates actually ARRIVE on this host.

Opens a websocket to one pinned fstream address, subscribes to a fixed symbol
set, and writes one line per update: the update id, the exchange's event
timestamp, and this host's CLOCK_REALTIME at the moment the bytes came off
the socket.

The point is the update id. Binance futures `u` is a global engine counter,
so the SAME id is seen by every host watching the same stream -- join the
three zones' files on it and the difference in arrival time is the only thing
left. The exchange's own clock cancels out and never has to be trusted; all
that matters is that the three probes' clocks agree, which chrony against the
Amazon time source gets to tens of microseconds (run.sh records the residual).

Stdlib only: a fresh Debian box has no websocket library and apt would be one
more thing to differ between the three boxes.
"""
import base64
import json
import os
import signal
import socket
import ssl
import struct
import sys
import time

HOST = "fstream.binance.com"


def frames(sock, deadline):
    """Yield (payload, recv_ns) for every text frame, answering pings."""
    buf = b""
    stamp = 0

    def need(n):
        nonlocal buf, stamp
        while len(buf) < n:
            if time.time() > deadline:
                raise TimeoutError
            chunk = sock.recv(65536)
            # Stamp the read, not the parse: this is the measurement.
            stamp = time.clock_gettime_ns(time.CLOCK_REALTIME)
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk

    while True:
        if time.time() > deadline:
            return
        need(2)
        b0, b1 = buf[0], buf[1]
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        ln = b1 & 0x7F
        off = 2
        if ln == 126:
            need(4)
            ln = struct.unpack(">H", buf[2:4])[0]
            off = 4
        elif ln == 127:
            need(10)
            ln = struct.unpack(">Q", buf[2:10])[0]
            off = 10
        if masked:
            need(off + 4)
            off += 4
        need(off + ln)
        payload = buf[off:off + ln]
        at = stamp
        buf = buf[off + ln:]

        if opcode == 0x1:
            yield payload, at
        elif opcode == 0x9:  # ping -> pong, or the venue drops us
            hdr = bytearray([0x8A, 0x80 | len(payload)])
            mask = os.urandom(4)
            hdr += mask
            hdr += bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
            sock.sendall(bytes(hdr))
        elif opcode == 0x8:
            return


def main():
    ip = sys.argv[1]
    seconds = float(sys.argv[2])
    symbols = sys.argv[3].split(",")
    out = sys.argv[4]

    # A ceiling no path can escape. Every wait below is bounded, but the run
    # fans 8 addresses x 3 zones out and then blocks on all of them, so one
    # stuck probe costs the whole measurement. Dying beats hanging.
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(f"{ip}: gave up"))
    signal.alarm(int(seconds) + 30)

    streams = "/".join(f"{s}@bookTicker" for s in symbols)
    path = f"/stream?streams={streams}"

    raw = socket.create_connection((ip, 443), timeout=10)
    raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    ctx = ssl.create_default_context()
    # Connect to a pinned ADDRESS but present the real name, so every zone is
    # measured against the identical peer rather than whatever DNS felt like.
    sock = ctx.wrap_socket(raw, server_hostname=HOST)

    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {HOST}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode())

    # A peer that declines by closing makes recv return b"" forever, so the
    # empty read has to end this loop: without it one unlucky address in the
    # pinned list spins a core and holds up the whole run.
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            sys.exit(f"{ip}: closed during the upgrade")
        head += chunk
        if len(head) > 65536:
            sys.exit(f"{ip}: no end of headers")
    if b"101" not in head.split(b"\r\n")[0]:
        sys.exit(f"{ip}: upgrade refused: {head.split(b"\r\n")[0]!r}")

    deadline = time.time() + seconds
    n = 0
    with open(out, "w") as fh:
        fh.write("u\tevent_ms\trecv_ns\n")
        try:
            for payload, at in frames(sock, deadline):
                try:
                    d = json.loads(payload)["data"]
                    fh.write(f"{d['u']}\t{d['E']}\t{at}\n")
                    n += 1
                except (KeyError, ValueError):
                    continue
        except (TimeoutError, ConnectionError, OSError):
            pass
    sys.stderr.write(f"{n} updates\n")


if __name__ == "__main__":
    main()

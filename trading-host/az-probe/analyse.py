#!/usr/bin/env python3
"""Join the zones' captures on the update id and report who saw it first.

Every capture is (update id, event ms, arrival ns) from one zone against one
Binance address. Binance futures `u` is a global counter, so an id names the
same engine event everywhere and the arrival times are directly comparable.

Two questions get answered separately:

  per peer   -- same Binance address seen from three zones. This is pure
                network distance and the cleanest signal of which zone shares
                a building with that peer.
  per zone   -- each zone against its own best peer, which is what production
                actually gets, because the bot races every address and acts on
                whichever answers first.
"""
import pathlib
import statistics
import sys


def load(path):
    """-> {update id: arrival ns}, [venue-to-receive ms]"""
    rows = {}
    v2r = []
    with open(path) as fh:
        next(fh, None)
        for line in fh:
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            try:
                u, event_ms, recv_ns = int(parts[0]), int(parts[1]), int(parts[2])
            except ValueError:
                continue
            rows[u] = recv_ns
            v2r.append(recv_ns / 1e6 - event_ms)
    return rows, v2r


def med_us(values):
    return statistics.median(values) / 1000.0


def main():
    root = pathlib.Path(sys.argv[1])
    skew = {}
    skew_file = root / "skew.tsv"
    if skew_file.exists():
        for line in skew_file.read_text().splitlines():
            z, off = line.split("\t")
            skew[z] = float(off)

    caps = {}  # (zone, peer) -> {u: ns}
    v2r = {}   # (zone, peer) -> [venue-to-receive ms]
    for f in sorted(root.glob("*/cap_*.tsv")):
        zone = f.parent.name
        peer = f.stem[len("cap_"):]
        rows, lag = load(f)
        if rows:
            caps[(zone, peer)] = rows
            v2r[(zone, peer)] = lag

    if not caps:
        sys.exit("no captures found")

    zones = sorted({z for z, _ in caps})
    peers = sorted({p for _, p in caps})

    print("captured")
    print(f"{'zone':<12} {'peer':<16} {'updates':>9}")
    for (z, p), rows in sorted(caps.items()):
        print(f"{z:<12} {p:<16} {len(rows):>9}")

    if skew:
        print()
        print("clock offset from the amazon time source (us), bounds the error below")
        for z in zones:
            print(f"  {z:<12} {skew.get(z, float('nan')) * 1e6:>10.1f}")

    print()
    print("venue-to-receive: exchange event stamp to arrival here, median ms")
    print(f"{'peer':<16} " + " ".join(f"{z:>12}" for z in zones))
    for p in peers:
        cells = []
        for z in zones:
            lag = v2r.get((z, p))
            cells.append(f"{statistics.median(lag):>12.1f}" if lag else f"{'-':>12}")
        print(f"{p:<16} " + " ".join(cells))
    print("  Binance stamps `E` in whole milliseconds and its clock carries an")
    print("  unknown offset from ours, so the absolute figure is coarse and biased.")
    print("  Differences BETWEEN zones in a row are the meaningful part; the")
    print("  per-peer table below measures the same thing without either problem.")

    print()
    print("per peer: same binance address, seen from each zone")
    print(f"{'peer':<16} " + " ".join(f"{z:>14}" for z in zones))
    for p in peers:
        present = [z for z in zones if (z, p) in caps]
        if len(present) < 2:
            continue
        common = set(caps[(present[0], p)])
        for z in present[1:]:
            common &= set(caps[(z, p)])
        if len(common) < 100:
            print(f"{p:<16} (only {len(common)} shared updates, skipped)")
            continue
        base = {z: [] for z in present}
        wins = {z: 0 for z in present}
        for u in common:
            times = {z: caps[(z, p)][u] for z in present}
            first = min(times.values())
            wins[min(times, key=times.get)] += 1
            for z in present:
                base[z].append(times[z] - first)
        cells = []
        for z in zones:
            if z in base:
                cells.append(f"{med_us(base[z]):>8.0f}us {100 * wins[z] / len(common):>3.0f}%")
            else:
                cells.append(f"{'-':>14}")
        print(f"{p:<16} " + " ".join(cells))
    print("  (microseconds behind the first zone to see each update, and win share)")

    print()
    print("per zone: each zone against its own best peer -- what production gets")
    best = {}
    for z in zones:
        mine = {p: caps[(z, p)] for p in peers if (z, p) in caps}
        if not mine:
            continue
        # Best = the peer that wins most often against this zone's others.
        shared = None
        for rows in mine.values():
            shared = set(rows) if shared is None else shared & set(rows)
        if not shared or len(mine) == 1:
            best[z] = next(iter(mine))
            continue
        score = {p: 0 for p in mine}
        for u in shared:
            score[min(mine, key=lambda p: mine[p][u])] += 1
        best[z] = max(score, key=score.get)

    merged = {}
    for z in zones:
        if z in best:
            merged[z] = caps[(z, best[z])]
    common = None
    for rows in merged.values():
        common = set(rows) if common is None else common & set(rows)
    print(f"{'zone':<12} {'best peer':<16} {'behind':>10} {'win share':>10}")
    if common and len(common) >= 100:
        wins = {z: 0 for z in merged}
        lag = {z: [] for z in merged}
        for u in common:
            times = {z: merged[z][u] for z in merged}
            first = min(times.values())
            wins[min(times, key=times.get)] += 1
            for z in merged:
                lag[z].append(times[z] - first)
        order = sorted(merged, key=lambda z: med_us(lag[z]))
        for z in order:
            print(f"{z:<12} {best[z]:<16} {med_us(lag[z]):>8.0f}us "
                  f"{100 * wins[z] / len(common):>9.0f}%")
        print(f"\n  {len(common)} updates seen by every zone.")
        win = order[0]
        gap = med_us(lag[order[-1]]) - med_us(lag[win])
        print(f"  {win} is first; the worst zone is {gap:.0f}us behind it.")
    else:
        print("  not enough shared updates to compare")


if __name__ == "__main__":
    main()

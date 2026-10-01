# Which availability zone

One command:

    just az-probe            # 120 s of capture, about 8 minutes end to end
    just az-probe 300        # longer capture, tighter numbers

It builds one `c7g.2xlarge` in each of the region's three zones, has all of
them watch the same Binance bookTicker streams at the same time, joins the
captures on the update id, prints which zone saw each update first, and
destroys the lot. Results land in `results-<timestamp>/`.

## Why it is built this way

**It measures arrival, not handshakes.** A TCP connect time is a proxy; what
the strategy actually waits for is a book update landing in the socket. The
probe records `CLOCK_REALTIME` the instant bytes come off the wire.

**The update id is the join key.** Binance futures `u` is a global engine
counter, so the same id names the same event on every host. Comparing three
hosts' arrival times for one id removes the exchange's clock from the
measurement entirely -- it never has to be trusted or even read.

**All zones are pinned to the same peer list.** `fstream.binance.com`
resolves to several plain EC2 addresses in `ap-northeast-1` (not CloudFront,
unlike Hyperliquid's `api.`). If each box resolved its own, the comparison
would be between different servers. One box resolves, every box uses that
list, and each (zone, peer) pair gets its own socket.

**Clocks are disciplined first.** All three sync to the link-local Amazon
time source `169.254.169.123`, and the report prints each box's residual RMS
offset so you can see whether a difference is real. A zone gap smaller than
the offsets is not a result.

**The instance type matches production.** Network behaviour varies by family,
so a `c7g.medium` probe would not predict a `c7g.2xlarge` host.

## Reading the report

`per peer` is pure network distance: the same Binance address seen from three
zones. A zone at ~0us with a high win share against one peer is sharing a
building with it.

`per zone` is what production would get, since the bot races every address
and acts on whichever answers first. This is the line to decide on.

## Safety

Its own VPC on `10.30.0.0/16` (production is `10.20.0.0/16`), its own local
terraform state, no termination protection, and the destroy runs from a shell
trap so an interrupted run still cleans up. If a destroy ever fails the script
prints the command to finish it -- do not leave three `c7g.2xlarge` running.

## Caveat

It answers for the leader leg only, which is the one that moves with the zone
(Binance is in-region EC2). The lagger leg is CloudFront edge and barely
moves; `just latency` covers both and prints the sum. The zone to pick is the
one with the lowest sum, so read the two together.

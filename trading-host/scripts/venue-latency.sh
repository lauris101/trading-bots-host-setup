#!/usr/bin/env bash
# Measure TCP connect latency from THIS host to BOTH legs of the hot path:
# the lagger (Hyperliquid, where orders go) and the leader (Binance futures,
# where the signal comes from). Run it on a candidate host to compare
# availability zones (README "Availability zone"):
#   just latency                          # from the laptop, over ssh
#   bash scripts/venue-latency.sh 40      # on the host, 40 samples per address
#
# Both legs sit in the same critical path -- signal in from the leader,
# order out to the lagger -- so the zone to pick is the one with the lowest
# SUM, not the best single venue. The script prints that sum.
#
# The two venues are reached differently and that is why the sum can
# surprise you: Hyperliquid's api. addresses are CloudFront edge, taken off
# the AWS edge network, while fstream.binance.com resolves to plain EC2
# instances in ap-northeast-1 (checked against ip-ranges.json, 2026-10-01).
# A same-AZ EC2 peer is a ~100 us handshake and a cross-AZ one is ~0.5 ms,
# so the leader leg is the one that moves most with the zone.
#
# Pure bash (/dev/tcp), no packages: what the venue sees is the TCP handshake,
# and the bot's own scout does the same measurement with more machinery.
set -euo pipefail
SAMPLES="${1:-20}"
LAGGER_HOSTS=(api.hyperliquid.xyz api-ui.hyperliquid.xyz)
LEADER_HOSTS=(fstream.binance.com)

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }

# One TCP handshake, timed in THIS shell: no fork, no exec, so the number is
# the network's, not the process spawn's (a `timeout bash -c` wrapper costs
# 2-3 ms on a small VM and swamped the measurement).
connect_ms() {
  local ip=$1 t0 t1
  t0=$EPOCHREALTIME
  if exec 3<>"/dev/tcp/$ip/443" 2>/dev/null; then
    t1=$EPOCHREALTIME
    exec 3>&-
    awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.3f", (b-a)*1000}'
  fi
}

printf "%-8s %-24s %-16s %8s %8s %8s\n" leg host ip min_ms med_ms max_ms
# Method overhead: the same handshake against this host's own sshd.
times=()
for _ in $(seq "$SAMPLES"); do
  t0=$EPOCHREALTIME
  if exec 3<>/dev/tcp/127.0.0.1/22 2>/dev/null; then
    t1=$EPOCHREALTIME; exec 3>&-
    times+=("$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.3f", (b-a)*1000}')")
  fi
done
if [ ${#times[@]} -gt 0 ]; then
  printf "%-8s %-24s %-16s %8s %8s %8s\n" "--" "(method overhead)" "127.0.0.1:22" "$(printf "%s\n" "${times[@]}" | sort -n | head -1)" "$(printf "%s\n" "${times[@]}" | median)" "$(printf "%s\n" "${times[@]}" | sort -n | tail -1)"
fi
# Each leg's score is its BEST address: the bot races several sockets and
# acts on whichever answers first, so the nearest endpoint is the one that
# decides the leg, not the average of them.
best_leg() {
  local leg=$1; shift
  local best=""
  for h in "$@"; do
    for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do
      times=()
      for _ in $(seq "$SAMPLES"); do
        ms=$(connect_ms "$ip") && [ -n "$ms" ] && times+=("$ms")
        sleep 0.05
      done
      [ ${#times[@]} -gt 0 ] || { printf "%-8s %-24s %-16s %s\n" "$leg" "$h" "$ip" "unreachable"; continue; }
      min=$(printf "%s\n" "${times[@]}" | sort -n | head -1)
      max=$(printf "%s\n" "${times[@]}" | sort -n | tail -1)
      med=$(printf "%s\n" "${times[@]}" | median)
      printf "%-8s %-24s %-16s %8s %8s %8s\n" "$leg" "$h" "$ip" "$min" "$med" "$max"
      if [ -z "$best" ] || awk -v a="$med" -v b="$best" 'BEGIN {exit !(a<b)}'; then best=$med; fi
    done
  done
  echo "$best" > "/tmp/.venue-latency-$leg"
}

best_leg lagger "${LAGGER_HOSTS[@]}"
best_leg leader "${LEADER_HOSTS[@]}"

echo
lag=$(cat /tmp/.venue-latency-lagger 2>/dev/null || echo "")
led=$(cat /tmp/.venue-latency-leader 2>/dev/null || echo "")
if [ -n "$lag" ] && [ -n "$led" ]; then
  awk -v a="$led" -v b="$lag" 'BEGIN {
    printf "best leader (binance) %8s ms\n", a
    printf "best lagger  (hyperliq) %7s ms\n", b
    printf "SUM -- the number to compare between zones: %.3f ms\n", a+b
  }'
fi
rm -f /tmp/.venue-latency-lagger /tmp/.venue-latency-leader
echo
echo "Subtract the method overhead line from each figure. Compare the SUM"
echo "across candidate zones; a difference under ~50 us is noise at 20 samples."

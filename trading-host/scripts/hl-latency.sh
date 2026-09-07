#!/usr/bin/env bash
# Measure TCP connect latency from THIS host to every address Hyperliquid's
# API resolves to, and to the exchange's websocket host. Run it on a
# candidate host to compare availability zones (README "Availability zone"):
#   just latency                       # from the laptop, over ssh
#   bash scripts/hl-latency.sh 40      # on the host, 40 samples per address
# Pure bash (/dev/tcp), no packages: what the venue sees is the TCP handshake,
# and the bot's own scout does the same measurement with more machinery.
set -euo pipefail
SAMPLES="${1:-20}"
HOSTS=(api.hyperliquid.xyz api-ui.hyperliquid.xyz)

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }

printf "%-24s %-16s %8s %8s %8s\n" host ip min_ms med_ms max_ms
for h in "${HOSTS[@]}"; do
  for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do
    times=()
    for _ in $(seq "$SAMPLES"); do
      t0=$EPOCHREALTIME
      if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/443" 2>/dev/null; then
        t1=$EPOCHREALTIME
        times+=("$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.3f", (b-a)*1000}')")
      fi
      sleep 0.05
    done
    [ ${#times[@]} -gt 0 ] || { printf "%-24s %-16s %s\n" "$h" "$ip" "unreachable"; continue; }
    min=$(printf "%s\n" "${times[@]}" | sort -n | head -1)
    max=$(printf "%s\n" "${times[@]}" | sort -n | tail -1)
    med=$(printf "%s\n" "${times[@]}" | median)
    printf "%-24s %-16s %8s %8s %8s\n" "$h" "$ip" "$min" "$med" "$max"
  done
done
echo
echo "Reference: same-AZ AWS Tokyo to the venue's CloudFront edge is well under 1 ms;"
echo "another AZ in the region adds roughly 0.5-1 ms; Hetzner Falkenstein measured ~250 ms."

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

printf "%-24s %-16s %8s %8s %8s\n" host ip min_ms med_ms max_ms
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
  printf "%-24s %-16s %8s %8s %8s\n" "(method overhead)" "127.0.0.1:22" "$(printf "%s\n" "${times[@]}" | sort -n | head -1)" "$(printf "%s\n" "${times[@]}" | median)" "$(printf "%s\n" "${times[@]}" | sort -n | tail -1)"
fi
for h in "${HOSTS[@]}"; do
  for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do
    times=()
    for _ in $(seq "$SAMPLES"); do
      ms=$(connect_ms "$ip") && [ -n "$ms" ] && times+=("$ms")
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
echo "Reference: EC2 Tokyo to the venue's CloudFront edge in Tokyo is a few ms (the edge is outside the VPC);"
echo "Hetzner Falkenstein measured ~250 ms. Subtract the method overhead line."

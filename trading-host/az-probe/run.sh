#!/usr/bin/env bash
# One measurement, start to finish: build a box in every availability zone,
# watch the same Binance stream from all of them at once, report which zone
# sees each update first, then destroy everything.
#
# Run it with `just az-probe` from trading-host/.
#
# Nothing here touches the production stack: this directory has its own VPC
# and its own local terraform state, and the destroy at the end runs from a
# trap, so a failure part way through still takes the instances down.
set -euo pipefail
cd "$(dirname "$0")"

SECONDS_CAPTURE="${1:-120}"
# A short capture is a quick look, so do not spend a minute of the run on
# the reference handshakes it is not waiting for.
SAMPLES_HS=$([ "${SECONDS_CAPTURE%%.*}" -lt 60 ] && echo 10 || echo 30)
STARTED=$(date +%s)
SYMBOLS="${SYMBOLS:-btcusdt,ethusdt,solusdt,xrpusdt,dogeusdt,bnbusdt,adausdt,suiusdt,linkusdt,avaxusdt}"
KEY="${KEY:-$HOME/.ssh/id_ed25519_trading}"
OUT="results-$(date -u +%Y%m%dT%H%M%SZ)"
# SetEnv pins the remote locale instead of forwarding the Mac's. A probe box
# is a raw AMI that never meets the base role, so it has no en_US.UTF-8 and
# would warn on every command; and C is the locale these scripts want anyway,
# since sort -n and awk's decimal separator both follow it.
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o SetEnv=LC_ALL=C)

say() { printf '\n== %s\n' "$*"; }

destroyed=0
cleanup() {
  [ "$destroyed" = 1 ] && return
  destroyed=1
  say "destroying the probe stack"
  terraform destroy -auto-approve -var "ssh_private_key_file=$KEY" || {
    echo "DESTROY FAILED -- instances may still be running. Run:"
    echo "  cd $(pwd) && terraform destroy -var ssh_private_key_file=$KEY"
    exit 1
  }
}
trap cleanup EXIT INT TERM

say "building one instance per zone"
terraform init -input=false >/dev/null
terraform apply -auto-approve -input=false -var "ssh_private_key_file=$KEY"

mapfile -t ZONES < <(terraform output -json probes | python3 -c \
  'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))')
declare -A ADDR
for z in "${ZONES[@]}"; do
  ADDR[$z]=$(terraform output -json probes | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['$z'])")
done
mkdir -p "$OUT"

say "waiting for ssh"
for z in "${ZONES[@]}"; do
  for _ in $(seq 60); do
    ssh "${SSH_OPTS[@]}" "admin@${ADDR[$z]}" true 2>/dev/null && break
    sleep 5
  done
  echo "  $z ${ADDR[$z]} up"
done

say "disciplining the clocks (the cross-zone comparison rests on them)"
for z in "${ZONES[@]}"; do
  ssh "${SSH_OPTS[@]}" "admin@${ADDR[$z]}" 'bash -s' <<'REMOTE' &
set -e
# The Debian AWS image usually ships chrony already pointed at the
# link-local Amazon source. Installing it again costs a minute of apt on
# every box, so only do it when it is genuinely missing.
if ! command -v chronyc >/dev/null; then
  sudo apt-get -qq update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y chrony >/dev/null
fi
# Same source for every zone at the same stratum: that is what makes the
# three arrival clocks comparable at microsecond scale.
if ! grep -rqs 169.254.169.123 /etc/chrony; then
  echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' \
    | sudo tee /etc/chrony/conf.d/aws.conf >/dev/null
  sudo systemctl restart chrony
fi
# Wait exactly as long as sync needs instead of sleeping a fixed 30 s.
sudo chronyc -a makestep >/dev/null 2>&1 || true
chronyc waitsync 12 0.0005 >/dev/null 2>&1 || \
  echo "WARNING: clock not within 500 us of the source on $(hostname)" >&2
REMOTE
done
wait

say "resolving fstream.binance.com from inside the region"
PEERS=$(ssh "${SSH_OPTS[@]}" "admin@${ADDR[${ZONES[0]}]}" \
  "getent ahostsv4 fstream.binance.com | awk '{print \$1}' | sort -u | paste -sd,")
echo "  pinned peers: $PEERS"
echo "$PEERS" > "$OUT/peers.txt"
# Every zone is measured against this ONE list. Letting each box resolve its
# own would compare different servers and tell you nothing about the zone.

say "capturing $SECONDS_CAPTURE s of bookTicker from every zone x peer"
for z in "${ZONES[@]}"; do
  scp "${SSH_OPTS[@]}" -q probe.py "admin@${ADDR[$z]}:/tmp/probe.py"
done
for z in "${ZONES[@]}"; do
  ssh "${SSH_OPTS[@]}" "admin@${ADDR[$z]}" \
    "PEERS='$PEERS' SYMS='$SYMBOLS' SECS='$SECONDS_CAPTURE' bash -s" <<'REMOTE' &
set -e
pids=()
for ip in ${PEERS//,/ }; do
  # Belt and braces with the probe's own alarm: this step blocks the run,
  # so nothing in it may outlast the window by more than a moment.
  timeout -k 5 "$((${SECS%%.*} + 45))" \
    python3 /tmp/probe.py "$ip" "$SECS" "$SYMS" "/tmp/cap_$ip.tsv" 2>>/tmp/probe.err &
  pids+=($!)
done
wait "${pids[@]}" || true
REMOTE
done
wait

say "collecting"
: > "$OUT/skew.tsv"
for z in "${ZONES[@]}"; do
  mkdir -p "$OUT/$z"
  scp "${SSH_OPTS[@]}" -q "admin@${ADDR[$z]}:/tmp/cap_*.tsv" "$OUT/$z/" 2>/dev/null || true
  # Anything a probe complained about: a refused upgrade or a dead address
  # shows up here rather than as a silently missing capture.
  ssh "${SSH_OPTS[@]}" "admin@${ADDR[$z]}" 'cat /tmp/probe.err 2>/dev/null' \
    | sed "s/^/  $z: /" || true
  off=$(ssh "${SSH_OPTS[@]}" "admin@${ADDR[$z]}" \
    "chronyc tracking | awk '/^RMS offset/ {print \$4}'" 2>/dev/null || echo "nan")
  printf '%s\t%s\n' "$z" "$off" >> "$OUT/skew.tsv"
done

say "handshake matrix (TCP connect, for reference)"
# All zones at once: sequentially this was a minute of the run on its own,
# and it is the reference number, not the result.
for z in "${ZONES[@]}"; do
  ssh "${SSH_OPTS[@]}" "admin@${ADDR[$z]}" "PEERS='$PEERS' HS='$SAMPLES_HS' bash -s" \
    > "$OUT/handshake-$z.txt" <<'REMOTE' &
for ip in ${PEERS//,/ }; do
  times=()
  for _ in $(seq "$HS"); do
    t0=$EPOCHREALTIME
    if exec 3<>"/dev/tcp/$ip/443" 2>/dev/null; then
      t1=$EPOCHREALTIME; exec 3>&-
      times+=("$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.3f", (b-a)*1000}')")
    fi
    sleep 0.02
  done
  med=$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}')
  printf '    %-16s %8s ms\n' "$ip" "$med"
done
REMOTE
done
wait
for z in "${ZONES[@]}"; do
  echo "  zone $z"
  cat "$OUT/handshake-$z.txt"
done | tee "$OUT/handshake.txt"

say "result"
python3 analyse.py "$OUT" | tee "$OUT/report.txt"
echo
echo "saved in $(pwd)/$OUT"
printf 'took %dm%02ds, of which %ss was capture\n' \
  $(( ($(date +%s) - STARTED) / 60 )) $(( ($(date +%s) - STARTED) % 60 )) \
  "$SECONDS_CAPTURE"

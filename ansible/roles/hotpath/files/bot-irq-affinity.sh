#!/usr/bin/env bash
# Pin every network interrupt (ENA / eth / virtio queues) to the housekeeping
# CPUs, so none lands on an isolated core under a spinning worker. Managed by
# ansible (trading-bots-host-setup); the CPU list comes from the unit's
# environment. Affinity does not persist, so the unit re-runs this at boot.
set -u
hk="${HOUSEKEEPING_CPUS:?HOUSEKEEPING_CPUS not set}"
for irq in $(grep -E 'ena|eth|virtio.*(input|output)' /proc/interrupts | cut -d: -f1 | tr -d ' '); do
  echo "$hk" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
done
echo "$hk" > /proc/irq/default_smp_affinity_list 2>/dev/null || true

#!/usr/bin/env bash
for i in $(seq 1 20); do
  echo "=== Loop $i $(date) ==="
  ./watchdog.sh || { sleep 120; continue; }
  opencode run --agent researcher "Research pass $(pwd)"
  ./watchdog.sh || continue
  opencode run --agent designer  "Design pass $(pwd)"
  ./watchdog.sh || continue
  opencode run --agent consultant "Consult pass $(pwd)"
  opencode run --agent builder "Continue building $(pwd)"
  grep -qi "ALL DONE" RESEARCH/STATUS.md && echo "PROJECT COMPLETE" && break
done

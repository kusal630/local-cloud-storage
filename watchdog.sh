#!/usr/bin/env bash
AVAIL=$(free -m | awk '/Mem/ {print $7}')
if [ "$AVAIL" -lt 2000 ]; then
  echo "LOW RAM: ${AVAIL}MB — pausing"
  exit 1
fi
exit 0

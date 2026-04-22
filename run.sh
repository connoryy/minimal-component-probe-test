#!/usr/bin/env bash
set -euo pipefail

BT_OUT=/tmp/bt.out
bpftrace /opt/probe.bt > "$BT_OUT" 2>&1 &
BT=$!
while ! grep -q Attaching "$BT_OUT" 2>/dev/null; do sleep 0.1; done

vector --config /etc/vector/vector.yaml > /dev/null 2>&1 &
V=$!

trap 'kill $V $BT 2>/dev/null; wait 2>/dev/null' EXIT
tail -f "$BT_OUT"

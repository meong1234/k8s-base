#!/bin/sh
# A policy probe within ~30s of a Cilium agent restart passes no matter what the
# policy says, because the endpoints' policy has not been regenerated yet.
set -e
MIN=${1:-60}

AGE=$(kubectl -n kube-system get pods -l k8s-app=cilium \
        --sort-by=.status.startTime \
        -o jsonpath='{.items[-1:].status.startTime}' \
      | python3 -c '
import datetime, sys
ts = sys.stdin.read().strip()
if not ts:
    print(-1)
else:
    started = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - started).total_seconds()))
')

if [ "$AGE" -lt 0 ]; then
  echo "    no cilium agent pods found — is the CNI up?"
  exit 1
fi

if [ "$AGE" -lt "$MIN" ]; then
  WAIT=$((MIN - AGE))
  echo "    youngest cilium agent is only ${AGE}s old; sleeping ${WAIT}s so its"
  echo "    endpoint policy is regenerated (otherwise any probe falsely passes)"
  sleep "$WAIT"
else
  echo "    youngest cilium agent has been up ${AGE}s — policy is live, safe to probe"
fi

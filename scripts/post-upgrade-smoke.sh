#!/usr/bin/env bash
# Post-deploy smoke test for the Twenty deployment. Run after every image swap.
#
#   scripts/post-upgrade-smoke.sh [--expected-version vX.Y.Z] [--expected-sha <sha256>]
#
# What it proves: containers up, HTTP healthy locally and publicly, the version the
# running image reports, the patched file byte-identical in server AND worker, the
# provider-factory probe passing 13/13 inside the running server, and no
# opencode session-header rejection in recent worker logs.
#
# What it CANNOT prove: that a real chat turn in the web UI succeeds. An agent has no
# CRM login, so that check stays with the human. Say so instead of implying otherwise.

set -uo pipefail

TWENTY_DIR="${TWENTY_DIR:-/home/ubuntu/twenty}"
FORK_DIR="${FORK_DIR:-/home/ubuntu/twenty-upstream}"
SERVER=twenty-server-1
WORKER=twenty-worker-1
DB=twenty-db-1
REDIS=twenty-redis-1
HEALTH_URL="http://127.0.0.1:3020/healthz"
PUBLIC_URL="https://crm.goku.codes"
DIST="/app/packages/twenty-server/dist/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.js"
PROBE="$FORK_DIR/patches/opencode-session/probe-opencode-session.js"

EXPECTED_VERSION=""
EXPECTED_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expected-version) EXPECTED_VERSION="${2:?}"; shift 2 ;;
    --expected-sha)     EXPECTED_SHA="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
info(){ printf '  ----  %s\n' "$*"; }

echo "== Twenty smoke test =="

echo "-- containers --"
for c in "$SERVER" "$WORKER" "$DB" "$REDIS"; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  if [ "$state" = running ]; then ok "$c running"; else bad "$c is $state"; fi
done
restarts="$(docker inspect -f '{{.RestartCount}}' "$SERVER" 2>/dev/null || echo 0)"
info "$SERVER restart count: $restarts (1 is normal after a boot/recreate)"

echo "-- http --"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$HEALTH_URL" || echo 000)"
[ "$code" = 200 ] && ok "local /healthz 200" || bad "local /healthz returned $code"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$PUBLIC_URL/" || echo 000)"
[ "$code" = 200 ] && ok "public $PUBLIC_URL 200" || bad "public $PUBLIC_URL returned $code"

echo "-- live version --"
live="$(curl -s --max-time 20 "$PUBLIC_URL/client-config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("appVersion",""))' 2>/dev/null)"
info "appVersion reported by the instance: ${live:-unknown}"
if [ -n "$EXPECTED_VERSION" ]; then
  case "$live" in
    *"$EXPECTED_VERSION"*) ok "running $EXPECTED_VERSION as expected" ;;
    *) bad "running '${live:-unknown}', expected $EXPECTED_VERSION" ;;
  esac
fi

echo "-- opencode-session patch in both containers --"
for c in "$SERVER" "$WORKER"; do
  sha="$(docker exec "$c" sha256sum "$DIST" 2>/dev/null | awk '{print $1}')"
  refs="$(docker exec "$c" sh -c "grep -c 'x-opencode-session' '$DIST' 2>/dev/null || echo 0" | tr -d '\r')"
  [ "${refs:-0}" -ge 2 ] && ok "$c: header code present ($refs refs)" || bad "$c: header code missing"
  if [ -n "$EXPECTED_SHA" ]; then
    [ "$sha" = "$EXPECTED_SHA" ] && ok "$c: file sha256 matches" || bad "$c: sha256 $sha != $EXPECTED_SHA"
  else
    info "$c: $sha"
  fi
done

echo "-- functional probe inside the running server --"
if docker cp "$PROBE" "$SERVER:/tmp/probe-opencode-session.js" >/dev/null 2>&1; then
  if docker exec "$SERVER" sh -c "TARGET='$DIST' node /tmp/probe-opencode-session.js" >/tmp/twenty-probe.out 2>&1; then
    ok "probe: $(grep -Eo '^[0-9]+/[0-9]+ passed' /tmp/twenty-probe.out | tail -1)"
  else
    bad "probe failed; see /tmp/twenty-probe.out"
    sed 's/^/        /' /tmp/twenty-probe.out | tail -20
  fi
  docker exec -u 0 "$SERVER" rm -f /tmp/probe-opencode-session.js >/dev/null 2>&1 || true
else
  bad "could not copy the probe into $SERVER"
fi

echo "-- worker log: opencode session rejections since the swap --"
rejections="$(docker logs "$WORKER" --since 30m 2>&1 | grep -ci 'missing x-opencode-session' || true)"
[ "${rejections:-0}" = 0 ] && ok "no 'missing x-opencode-session' in the last 30m" \
  || bad "$rejections x-opencode-session rejection(s) in the worker log in the last 30m"
boot_errors="$(docker logs "$WORKER" --since 30m 2>&1 | grep -ciE 'Invalid prompt|ModelMessage' || true)"
[ "${boot_errors:-0}" = 0 ] && ok "no ModelMessage schema errors in the last 30m" \
  || info "$boot_errors ModelMessage error(s) in the worker log (check whether they predate the swap)"

echo
printf 'result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]

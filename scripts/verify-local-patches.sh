#!/usr/bin/env bash
# Verify, from outside the UI, that every patch this deployment needs is actually
# live in the running containers - and that every retired patch is really gone.
#
#   scripts/verify-local-patches.sh [--expected-sha <sha256>]
#
# Exit code 0 = all REQUIRED patches active and all RETIRED patches absent.
# Reads the container filesystem and the last update state file, never the web UI.

set -uo pipefail

TWENTY_DIR="${TWENTY_DIR:-/home/ubuntu/twenty}"
FORK_DIR="${FORK_DIR:-/home/ubuntu/twenty-upstream}"
SERVER=twenty-server-1
WORKER=twenty-worker-1
STATE_FILE="$TWENTY_DIR/.twenty-update-state.json"

DIST_DIR="/app/packages/twenty-server/dist/engine/metadata-modules/ai/ai-models/services"
FACTORY="$DIST_DIR/sdk-provider-factory.service.js"
TOOL_EXEC="/app/packages/twenty-server/dist/engine/core-modules/tool-provider/services/tool-executor.service.js"
NORMALIZE_DIR="/app/packages/twenty-server/dist/engine/core-modules/tool-provider/output-transforms"

EXPECTED_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expected-sha) EXPECTED_SHA="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
info() { printf '  ----  %s\n' "$*"; }

container_sha() { docker exec "$1" sha256sum "$2" 2>/dev/null | awk '{print $1}'; }
container_count() { docker exec "$1" sh -c "grep -c '$2' '$3' 2>/dev/null || true" 2>/dev/null | tr -d '\r'; }

echo "== Twenty local patch inventory =="
echo "deployment: $TWENTY_DIR"

if [ -f "$STATE_FILE" ]; then
  echo "-- last update state --"
  python3 -c "
import json,sys
s=json.load(open('$STATE_FILE'))
for k in ('phase','updated_at','upstream_tag','mode','image','patched_file_sha256','previous_tag_in_env','database_dump'):
    print(f'  {k}: {s.get(k)}')
" 2>/dev/null || info "state file present but unreadable"
  if [ -z "$EXPECTED_SHA" ]; then
    EXPECTED_SHA="$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('patched_file_sha256') or '')" 2>/dev/null)"
  fi
fi
echo

echo "-- PATCH 1: opencode-session (REQUIRED) --"
for c in "$SERVER" "$WORKER"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then bad "$c not running"; continue; fi
  hdr="$(container_count "$c" 'x-opencode-session' "$FACTORY")"
  # call sites only: the helper definition line does not carry the leading '='
  wraps="$(container_count "$c" '= _withOpencodeSession(config, ' "$FACTORY")"
  sha="$(container_sha "$c" "$FACTORY")"
  [ "${hdr:-0}" -ge 2 ] && ok "$c carries x-opencode-session ($hdr refs)" || bad "$c has no x-opencode-session header code ($hdr refs)"
  [ "${wraps:-0}" = 5 ] && ok "$c wraps 5 provider factories" || bad "$c wraps ${wraps:-0} factories, expected 5"
  if [ -n "$EXPECTED_SHA" ]; then
    [ "$sha" = "$EXPECTED_SHA" ] && ok "$c file sha256 matches the generated artifact" \
      || bad "$c file sha256 $sha != expected $EXPECTED_SHA"
  else
    info "$c file sha256: $sha (no expected sha to compare)"
  fi
done
echo

echo "-- PATCH 2: json-safe-tool-output / Date crash (RETIRED, upstream since v2.40.2) --"
for c in "$SERVER" "$WORKER"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then bad "$c not running"; continue; fi
  local_markers="$(container_count "$c" 'chat-fail-cause\|local patch: json' "$TOOL_EXEC")"
  upstream_util="$(docker exec "$c" sh -c "test -f $NORMALIZE_DIR/normalize-tool-output-to-json-values.util.js && echo yes || echo no" 2>/dev/null | tr -d '\r')"
  [ "${local_markers:-0}" = 0 ] && ok "$c has no local tool-executor patch (retired)" || bad "$c still carries a local tool-executor patch ($local_markers markers)"
  [ "$upstream_util" = yes ] && ok "$c ships the upstream normalizer" || bad "$c has no upstream normalizer utility"
done
echo

echo "-- source patch (repo) --"
SRC="$FORK_DIR/packages/twenty-server/src/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.ts"
if [ -f "$SRC" ]; then
  [ "$(grep -c '= withOpencodeSession(config, ' "$SRC")" = 5 ] && ok "fork tree: 5 wrapped factories" || bad "fork tree: unexpected wrap count"
  grep -q 'x-opencode-session' "$SRC" && ok "fork tree: header constant present" || bad "fork tree: header constant missing"
  info "fork branch: $(git -C "$FORK_DIR" rev-parse --abbrev-ref HEAD) @ $(git -C "$FORK_DIR" rev-parse --short HEAD)"
else
  bad "fork tree not found at $FORK_DIR"
fi
echo

printf 'result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]

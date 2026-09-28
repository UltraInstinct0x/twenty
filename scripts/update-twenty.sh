#!/usr/bin/env bash
# Deterministic Twenty CRM update for this host.
#
#   upstream tag  ->  rebase the local patch commit  ->  build patched image
#   ->  DB dump  ->  deploy server+worker  ->  smoke test  ->  (rollback on failure)
#
# Usage:
#   scripts/update-twenty.sh [options]
#
#   --target twenty/vX.Y.Z   upstream tag (default: newest twenty/v* tag)
#   --mode derived|source    derived = pinned official image + generated dist file (default, seconds)
#                            source  = full build from the fork checkout (heavy, see PATCHES.md)
#   --patch-rev N            local patch revision counter (default 1); bump when the
#                            patch content changes without an upstream version bump
#   --dry-run                print every action, change nothing
#   --no-deploy              prepare + verify the image, do not touch the running stack
#   --pre-upgrade            run `yarn command:prod upgrade` in a one-off container
#                            before swapping (off by default: new schema + old code)
#   --yes                    do not ask for confirmation before deploying
#
# Idempotent: re-running with the same target and patch revision skips the build and
# skips the deploy when the running container already runs the expected image.
#
# Never merges: a rebase conflict aborts the run and leaves the branch untouched.

set -euo pipefail

TWENTY_DIR="${TWENTY_DIR:-/home/ubuntu/twenty}"
FORK_DIR="${FORK_DIR:-/home/ubuntu/twenty-upstream}"
PATCH_BRANCH="${PATCH_BRANCH:-goku/opencode-session-header}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
IMAGE_REPO="${IMAGE_REPO:-twentycrm/twenty}"
BACKUP_DIR="${TWENTY_BACKUP_DIR:-/home/ubuntu/backups/twenty}"
STATE_FILE="$TWENTY_DIR/.twenty-update-state.json"
WORK_DIR="${TWENTY_WORK_DIR:-$TWENTY_DIR/.update-work}"
SERVER=twenty-server-1
WORKER=twenty-worker-1
DB=twenty-db-1
HEALTH_URL="http://127.0.0.1:3020/healthz"
PUBLIC_URL="https://crm.goku.codes"
BOOT_TIMEOUT="${TWENTY_BOOT_TIMEOUT:-1800}"

DIST_REL="packages/twenty-server/dist/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.js"
CONTAINER_DIST="/app/$DIST_REL"
GEN="$FORK_DIR/patches/opencode-session/generate-dist-patch.py"
PROBE="$FORK_DIR/patches/opencode-session/probe-opencode-session.js"
DOCKERFILE="$FORK_DIR/patches/opencode-session/Dockerfile.patched"

MODE=derived
TARGET=""
PATCH_REV=1
DRY_RUN=0
DO_DEPLOY=1
ASSUME_YES=0
PRE_UPGRADE=0

STAMP="$(date +%Y%m%d-%H%M%S)"
log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }
compose() { ( cd "$TWENTY_DIR" && docker compose "$@" ); }

usage() { sed -n '2,26p' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target)     TARGET="${2:?}"; shift 2 ;;
    --mode)       MODE="${2:?}"; shift 2 ;;
    --patch-rev)  PATCH_REV="${2:?}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-deploy)  DO_DEPLOY=0; shift ;;
    --pre-upgrade) PRE_UPGRADE=1; shift ;;
    --yes)        ASSUME_YES=1; shift ;;
    -h|--help)    usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$MODE" in derived|source) ;; *) die "--mode must be derived or source" ;; esac
[ -d "$TWENTY_DIR" ] || die "deployment dir not found: $TWENTY_DIR"
[ -f "$TWENTY_DIR/docker-compose.yml" ] || die "no docker-compose.yml in $TWENTY_DIR"
[ -d "$FORK_DIR/.git" ] || die "fork checkout not found: $FORK_DIR"
command -v docker >/dev/null || die "docker not found"
command -v python3 >/dev/null || die "python3 not found"

# ---------------------------------------------------------------- target tag --
resolve_target() {
  if [ -n "$TARGET" ]; then return 0; fi
  local url
  url="$(git -C "$FORK_DIR" remote get-url "$UPSTREAM_REMOTE")" || die "no '$UPSTREAM_REMOTE' remote in $FORK_DIR"
  TARGET="$(git ls-remote --tags --refs "$url" 'twenty/v*' | awk -F'refs/tags/' '{print $2}' | sort -V | tail -1)"
  [ -n "$TARGET" ] || die "could not resolve the newest upstream tag"
}
VERSION=""

# --------------------------------------------------------------- patch branch --
ensure_tag() {
  if git -C "$FORK_DIR" rev-parse --verify --quiet "refs/tags/$TARGET" >/dev/null; then
    log "tag $TARGET already present locally"
  else
    log "fetching $TARGET from $UPSTREAM_REMOTE"
    run git -C "$FORK_DIR" fetch --depth=1 "$UPSTREAM_REMOTE" "refs/tags/$TARGET:refs/tags/$TARGET"
  fi
}

rebase_patch() {
  log "rebasing $PATCH_BRANCH onto $TARGET"
  if [ "$DRY_RUN" = 0 ]; then
    [ -z "$(git -C "$FORK_DIR" status --porcelain)" ] || die "fork checkout is dirty; commit or stash first"
  fi

  if git -C "$FORK_DIR" merge-base --is-ancestor "refs/tags/$TARGET" "$PATCH_BRANCH" 2>/dev/null; then
    log "$PATCH_BRANCH is already based on $TARGET"
  elif [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] git checkout $PATCH_BRANCH; git rebase $TARGET"
    return 0
  else
    git -C "$FORK_DIR" checkout -q "$PATCH_BRANCH"
    if ! git -C "$FORK_DIR" rebase "$TARGET"; then
      git -C "$FORK_DIR" rebase --abort || true
      die "rebase conflict on $TARGET. Nothing was deployed. Resolve it by hand:
     cd $FORK_DIR && git rebase $TARGET
   then re-run this script."
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] skipping the source-patch assertions on the working tree"
    return 0
  fi

  git -C "$FORK_DIR" checkout -q "$PATCH_BRANCH"
  local src="$FORK_DIR/packages/twenty-server/src/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.ts"
  [ -f "$src" ] || die "patched source file missing after rebase: $src"
  grep -q 'x-opencode-session' "$src" || die "the rebased tree lost the opencode-session patch"
  [ "$(grep -c '= withOpencodeSession(config, ' "$src")" = 5 ] || die "expected 5 wrapped provider factories in the source patch"
  log "source patch present: 5 provider factories wrapped, commit $(git -C "$FORK_DIR" rev-parse --short HEAD)"
}

# -------------------------------------------------------------------- images --
image_present() { docker image inspect "$1" >/dev/null 2>&1; }

image_file_sha() {
  docker run --rm --entrypoint sha256sum "$1" "$CONTAINER_DIST" 2>/dev/null | awk '{print $1}'
}

base_digest_of() {
  local refs
  refs="$(docker image inspect "$1" --format '{{json .RepoDigests}}' 2>/dev/null || echo '[]')"
  python3 -c "
import json,sys
d=json.loads('''$refs''')
print(d[0].split('@')[1] if d else '')
"
}

extract_pristine() {
  local base_ref="$1"
  log "extracting pristine dist from $base_ref"
  run mkdir -p "$WORK_DIR"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  docker run --rm --entrypoint cat "$base_ref" "$CONTAINER_DIST" > "$WORK_DIR/pristine.js" \
    || die "could not extract $CONTAINER_DIST from $base_ref"
  [ -s "$WORK_DIR/pristine.js" ] || die "extracted pristine file is empty"
  log "pristine sha256: $(sha256sum "$WORK_DIR/pristine.js" | awk '{print $1}')"
}

generate_artifact() {
  log "generating the patched dist file"
  run python3 "$GEN" "$WORK_DIR/pristine.js" "$WORK_DIR/sdk-provider-factory.service.js"
  if [ "$DRY_RUN" = 1 ]; then PAT_IMAGE="$IMAGE_REPO:goku-$VERSION-p$PATCH_REV"; EXPECTED_SHA=""; return 0; fi
  EXPECTED_SHA="$(sha256sum "$WORK_DIR/sdk-provider-factory.service.js" | awk '{print $1}')"
  cp "$PROBE" "$WORK_DIR/probe-opencode-session.js"
  log "patched  sha256: $EXPECTED_SHA"
}

build_derived() {
  PAT_IMAGE="$IMAGE_REPO:goku-$VERSION-p$PATCH_REV"
  local base_ref="$IMAGE_REPO:$VERSION"

  if [ "$DRY_RUN" = 0 ]; then
    log "pulling $base_ref"
    docker pull -q "$base_ref" >/dev/null || die "cannot pull $base_ref"
  fi

  extract_pristine "$base_ref"
  generate_artifact

  local base_from="$base_ref"
  if [ "$DRY_RUN" = 0 ]; then
    BASE_DIGEST="$(base_digest_of "$base_ref")"
    if [ -n "$BASE_DIGEST" ]; then base_from="$IMAGE_REPO@$BASE_DIGEST"; fi
  fi

  if image_present "$PAT_IMAGE" && [ "$(image_file_sha "$PAT_IMAGE")" = "$EXPECTED_SHA" ]; then
    log "image $PAT_IMAGE already carries $EXPECTED_SHA - skipping build"
    return 0
  fi

  log "building $PAT_IMAGE (FROM $base_from)"
  run docker build \
    -f "$DOCKERFILE" \
    --build-arg "BASE_IMAGE=$base_from" \
    --build-arg "PATCH_REVISION=$EXPECTED_SHA" \
    -t "$PAT_IMAGE" \
    "$WORK_DIR"

  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  local actual; actual="$(image_file_sha "$PAT_IMAGE")"
  [ "$actual" = "$EXPECTED_SHA" ] || die "built image carries $actual, expected $EXPECTED_SHA"
  log "built $PAT_IMAGE with the expected file"
}

build_source() {
  PAT_IMAGE="$IMAGE_REPO:goku-$VERSION-p$PATCH_REV"
  warn "source mode builds the whole monorepo. The Dockerfile runs the frontend build with
     NODE_OPTIONS=--max-old-space-size=8192; on this host that risks OOM-killing the
     running CRM. Consider the GitHub Actions path in PATCHES.md instead."
  if [ "${ALLOW_HEAVY_BUILD:-0}" != 1 ]; then
    die "refusing to start a heavy build without ALLOW_HEAVY_BUILD=1"
  fi
  log "building $PAT_IMAGE from $FORK_DIR ($TARGET)"
  run docker build \
    --target twenty \
    -f "$FORK_DIR/packages/twenty-docker/twenty/Dockerfile" \
    --build-arg "APP_VERSION=$VERSION" \
    -t "$PAT_IMAGE" \
    "$FORK_DIR"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  grep -q '_withOpencodeSession' <(docker run --rm --entrypoint cat "$PAT_IMAGE" "$CONTAINER_DIST") \
    || die "source build did not produce the patched file"
  EXPECTED_SHA="$(image_file_sha "$PAT_IMAGE")"
}

probe_image() {
  log "probing $PAT_IMAGE (13 assertions, no network)"
  run docker run --rm --user root \
    -v "$WORK_DIR:/probe:ro" \
    --entrypoint sh "$PAT_IMAGE" -c '
      set -e
      cp /probe/sdk-provider-factory.service.js /app/'"$DIST_REL"'.probe
      TARGET=/app/'"$DIST_REL"'.probe node /probe/probe-opencode-session.js
    '
}

# ------------------------------------------------------------------ deployment --
dump_db() {
  mkdir -p "$BACKUP_DIR"
  local out="$BACKUP_DIR/twenty-$STAMP.sql.gz"
  log "dumping the database to $out"
  docker exec "$DB" sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > "$out" \
    || die "database dump failed; not deploying"
  gzip -t "$out" || die "database dump is not a valid gzip stream"
  [ "$(stat -c%s "$out")" -gt 100000 ] || die "database dump looks too small: $out"
  log "dump ok: $(stat -c%s "$out") bytes"
}

tag_previous_image() {
  PREV_TAG_SHORT="goku-prev-$STAMP"
  PREV_IMAGE_ID="$(docker inspect "$SERVER" --format '{{.Image}}')"
  log "protecting the running image as $IMAGE_REPO:$PREV_TAG_SHORT ($PREV_IMAGE_ID)"
  run docker tag "$PREV_IMAGE_ID" "$IMAGE_REPO:$PREV_TAG_SHORT"
}

set_env_tag() {
  local tag="$1"
  if [ "$DRY_RUN" = 1 ]; then echo "   [dry-run] set TAG=$tag in $TWENTY_DIR/.env"; return 0; fi
  cp "$TWENTY_DIR/.env" "$TWENTY_DIR/.env.bak-$STAMP"
  python3 - "$TWENTY_DIR/.env" "$tag" <<'PY'
import re, sys
path, tag = sys.argv[1], sys.argv[2]
text = open(path).read()
line = f"TAG={tag}"
if re.search(r'(?m)^TAG=', text):
    text = re.sub(r'(?m)^TAG=.*$', line, text)
else:
    text = text.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(text)
PY
  log ".env: TAG=$tag (backup .env.bak-$STAMP)"
}

wait_healthy() {
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  log "waiting for the server to answer $HEALTH_URL (boot runs the DB upgrade, this takes minutes)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sf -o /dev/null "$HEALTH_URL"; then
      log "server healthy"
      return 0
    fi
    sleep 15
  done
  return 1
}

write_state() {
  local phase="$1"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  python3 - "$STATE_FILE" <<PY
import json, datetime
state = {
  "phase": "$phase",
  "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "upstream_tag": "$TARGET",
  "version": "$VERSION",
  "patch_revision": "$PATCH_REV",
  "mode": "$MODE",
  "image": "${PAT_IMAGE:-}",
  "patched_file_sha256": "${EXPECTED_SHA:-}",
  "base_image": "${IMAGE_REPO:-}:${VERSION}",
  "base_digest": "${BASE_DIGEST:-}",
  "previous_tag_in_env": "${PREV_TAG_SHORT:-}",
  "previous_image_id": "${PREV_IMAGE_ID:-}",
  "database_dump": "${DUMP_PATH:-}",
  "fork_commit": "$(git -C "$FORK_DIR" rev-parse HEAD 2>/dev/null || echo '')",
}
json.dump(state, open("$STATE_FILE", "w"), indent=2)
PY
  log "state written: $STATE_FILE"
}

rollback() {
  [ -n "${PREV_TAG_SHORT:-}" ] || die "no previous image recorded; cannot roll back automatically"
  warn "rolling back to $IMAGE_REPO:$PREV_TAG_SHORT"
  set_env_tag "$PREV_TAG_SHORT"
  compose up -d server worker || warn "compose up during rollback returned non-zero"
  if wait_healthy; then
    warn "rollback complete: the CRM is back on the previous image"
  else
    warn "rollback brought the previous image up but it never became healthy - investigate now"
  fi
  write_state "rolled-back"
}

# ------------------------------------------------------------------------ main --
log "update plan: target=$TARGET mode=$MODE patch-rev=$PATCH_REV deploy=$DO_DEPLOY dry-run=$DRY_RUN"

resolve_target
VERSION="${TARGET#twenty/}"
case "$VERSION" in v[0-9]*) ;; *) die "unexpected upstream tag shape: $TARGET" ;; esac
log "target version: $VERSION"

ensure_tag
rebase_patch

if [ "$MODE" = derived ]; then build_derived; else build_source; fi
if [ "$DRY_RUN" = 1 ]; then log "dry run complete (nothing changed)"; exit 0; fi

probe_image

PAT_TAG_SHORT="${PAT_IMAGE#*:}"

# Nothing to do if the running containers already run exactly this image.
RUNNING_ID="$(docker inspect "$SERVER" --format '{{.Image}}')"
TARGET_ID="$(docker image inspect "$PAT_IMAGE" --format '{{.Id}}')"
if [ "$RUNNING_ID" = "$TARGET_ID" ] && [ "$DO_DEPLOY" = 1 ]; then
  log "server is already running $PAT_IMAGE - nothing to deploy"
  exit 0
fi

if [ "$DO_DEPLOY" = 0 ]; then
  log "image ready: $PAT_IMAGE ($EXPECTED_SHA). Not deploying (--no-deploy)."
  log "to deploy:   set TAG=$PAT_TAG_SHORT in $TWENTY_DIR/.env, then docker compose up -d server worker"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf 'Deploy %s to %s now? The CRM is down for several minutes during boot. [y/N] ' "$PAT_IMAGE" "$TWENTY_DIR"
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "aborted by the operator" ;; esac
fi

dump_db
DUMP_PATH="$BACKUP_DIR/twenty-$STAMP.sql.gz"
tag_previous_image

if [ "$PRE_UPGRADE" = 1 ]; then
  log "pre-running the DB/workspace upgrade in a one-off container"
  ( cd "$TWENTY_DIR" && TAG="$PAT_TAG_SHORT" docker compose run --rm -T --entrypoint sh server -c 'yarn command:prod upgrade' ) \
    || warn "pre-upgrade step returned non-zero; the boot will run it again"
fi

write_state "deploying"
set_env_tag "$PAT_TAG_SHORT"
log "deploying $PAT_IMAGE"
compose up -d server worker

if ! wait_healthy; then
  warn "the new image did not become healthy within ${BOOT_TIMEOUT}s"
  rollback
  exit 1
fi

if ! bash "$FORK_DIR/scripts/post-upgrade-smoke.sh" --expected-version "$VERSION" --expected-sha "$EXPECTED_SHA"; then
  warn "smoke test failed"
  rollback
  exit 1
fi

write_state "deployed"
log "done: $VERSION on $PAT_IMAGE (patched file $EXPECTED_SHA)"
log "database dump: $DUMP_PATH"
log "rollback command: TWENTY_DIR=$TWENTY_DIR bash $FORK_DIR/scripts/update-twenty.sh --target $TARGET --dry-run   # or set TAG=$PREV_TAG_SHORT in .env and docker compose up -d server worker"

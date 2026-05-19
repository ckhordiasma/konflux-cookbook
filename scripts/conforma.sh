#!/bin/bash

usage() {
  cat <<EOF
Usage: conforma.sh (-a <app> | -s <snapshot> | -i <image>) [options]

Run EC validation against a Konflux snapshot or a single container image.

Options:
  -a, --application APP   Konflux application name (e.g. rhoai-v3-4)
  -i, --image IMAGE       Single container image reference (e.g. quay.io/org/image:tag)
  -f, --filter REGEX      Regex filter on component names (snapshot mode only)
  -x, --exclude PATTERNS  Comma-separated partial names to exclude (snapshot mode only)
                          (default: fbc-fragment,rhai-on-openshift-chart,rhoai-on-xks-chart)
  -s, --snapshot NAME     Snapshot name (default: latest push snapshot).
                          If used without -a, the application is derived from the snapshot.
  -r, --latest-rc    Use the latest released snapshot (requires -a)
  -t, --effective-time DATE  Evaluate policies as of this date (YYYY-MM-DD, default: now)
  -p, --policy FILE       Policy file or k8s ref (default: registry-rhoai-prod.yaml)
  -o, --output FILE       Results output file (default: ec-report-APP-POLICY.yaml)
  -w, --workers N         Concurrent workers (default: 50)
  -k, --pubkey KEY        Public key (default: k8s://openshift-pipelines/public-key)
  -v, --verbose           Enable verbose output
  -h, --help              Show this help

One of -a/--application, -s/--snapshot, or -i/--image is required.

All options can also be set via environment variables:
  APPLICATION, IMAGE, FILTER, EXCLUDE, SNAPSHOT, LATEST_RC, EFFECTIVE_TIME, POLICY_FILE, RESULTS_FILE, WORKERS, PUBKEY, VERBOSE
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--application) APPLICATION="$2"; shift 2 ;;
    -i|--image)       IMAGE="$2"; shift 2 ;;
    -f|--filter)      FILTER="$2"; shift 2 ;;
    -s|--snapshot)    SNAPSHOT="$2"; shift 2 ;;
    -r|--latest-rc) LATEST_RC=true; shift ;;
    -t|--effective-time) EFFECTIVE_TIME="$2"; shift 2 ;;
    -p|--policy)      POLICY_FILE="$2"; shift 2 ;;
    -o|--output)      RESULTS_FILE="$2"; shift 2 ;;
    -w|--workers)     WORKERS="$2"; shift 2 ;;
    -k|--pubkey)      PUBKEY="$2"; shift 2 ;;
    -v|--verbose)     VERBOSE=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

LATEST_RC=${LATEST_RC:-false}

if [ -z "$APPLICATION" ] && [ -z "$IMAGE" ] && [ -z "$SNAPSHOT" ]; then
  echo "ERROR: one of APPLICATION (-a), SNAPSHOT (-s), or IMAGE (-i) is required"
  echo ""
  usage
  exit 1
fi
if [ -n "$IMAGE" ] && { [ -n "$APPLICATION" ] || [ -n "$SNAPSHOT" ]; }; then
  echo "ERROR: IMAGE (-i) cannot be combined with APPLICATION (-a) or SNAPSHOT (-s)"
  echo ""
  usage
  exit 1
fi
if [ "$LATEST_RC" = "true" ] && [ -z "$APPLICATION" ]; then
  echo "ERROR: --latest-rc requires APPLICATION (-a)"
  echo ""
  usage
  exit 1
fi
if [ "$LATEST_RC" = "true" ] && [ -n "$SNAPSHOT" ]; then
  echo "ERROR: --latest-rc and --snapshot are mutually exclusive"
  echo ""
  usage
  exit 1
fi
PUBKEY=${PUBKEY:-k8s://openshift-pipelines/public-key}

VERBOSE=${VERBOSE:-false}
POLICY_FILE=${POLICY_FILE:-registry-rhoai-prod.yaml}
POLICY_STEM=${POLICY_FILE##*/}
POLICY_STEM=${POLICY_STEM%.*}

log() {
  if [ "$VERBOSE" = "true" ]; then
    echo "$@"
  fi
}

WORKERS=${WORKERS:-50}
VERBOSE_FLAG=""
if [ "$VERBOSE" = "true" ]; then
  VERBOSE_FLAG="--verbose"
fi

EFFECTIVE_TIME_FLAG=""
TIME_SUFFIX=""
if [ -n "$EFFECTIVE_TIME" ]; then
  EFFECTIVE_TIME_FLAG="--effective-time ${EFFECTIVE_TIME}T00:00:00Z"
  TIME_SUFFIX="-${EFFECTIVE_TIME}"
  echo "Effective time: ${EFFECTIVE_TIME}"
fi

if [ -n "$IMAGE" ]; then
  # Single image mode
  IMAGE_SHORT=${IMAGE##*/}
  IMAGE_SHORT=${IMAGE_SHORT%%@*}
  IMAGE_SHORT=${IMAGE_SHORT%%:*}
  RESULTS_FILE=${RESULTS_FILE:-ec-report-${IMAGE_SHORT}-${POLICY_STEM}${TIME_SUFFIX}.yaml}

  COMMAND="ec validate image --ignore-rekor true --image $IMAGE --public-key $PUBKEY --policy $POLICY_FILE --info --output yaml --timeout 30m0s $EFFECTIVE_TIME_FLAG $VERBOSE_FLAG"

  HEADER="# ec command: $COMMAND
# image: $IMAGE"

  echo "=== Running EC validation ==="
  echo "Image: $IMAGE"
  echo "$COMMAND"
  SECONDS=0
  { echo "$HEADER"; $COMMAND; } | tee $RESULTS_FILE
  EC_EXIT=$?
  DURATION=$SECONDS

  echo ""
  echo "=== Summary ==="
  echo "Image:      $IMAGE"
  echo "Duration:   $((DURATION / 60))m $((DURATION % 60))s"
  echo "Exit code:  $EC_EXIT"
else
  # Snapshot mode
  echo "=== Fetching snapshot ==="
  SECONDS=0
  if [ "$LATEST_RC" = "true" ]; then
    # Find the latest successful release via Release CRs
    LATEST_RC_JSON=$(oc get releases -l "appstudio.openshift.io/application=$APPLICATION" --sort-by=.metadata.creationTimestamp -o json \
      | jq -r '[.items[] | select(.status.conditions[]? | .type == "Released" and .reason == "Succeeded")] | last | "\(.metadata.name)\t\(.spec.snapshot)"')
    RELEASE_NAME=$(echo "$LATEST_RC_JSON" | cut -f1)
    SNAPSHOT=$(echo "$LATEST_RC_JSON" | cut -f2)
    if [ -z "$SNAPSHOT" ] || [ "$SNAPSHOT" = "null" ]; then
      echo "ERROR: no successful releases found for application '$APPLICATION'"
      exit 1
    fi
    echo "Release: $RELEASE_NAME"
    echo "Latest release snapshot: $SNAPSHOT (${SECONDS}s)"
  elif [ -z "$SNAPSHOT" ]; then
    SNAPSHOT=$(oc get snapshots -l "pac.test.appstudio.openshift.io/event-type in (push,incoming),appstudio.openshift.io/application=$APPLICATION" --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
    echo "Snapshot: $SNAPSHOT (${SECONDS}s)"
  else
    echo "Snapshot: $SNAPSHOT (${SECONDS}s)"
  fi

  WORK_DIR=$(mktemp -d)
  echo "Work dir: $WORK_DIR"

  SNAPSHOT_FILE=$WORK_DIR/snapshot.json

  echo "=== Downloading snapshot JSON ==="
  SECONDS=0
  JQ_FILTER='.spec.components |= [.[] | select(.name | test("fbc-fragment") | not)]'
  if [ -n "$FILTER" ]; then
    JQ_FILTER="$JQ_FILTER | .spec.components |= [.[] | select(.name | test(\"$FILTER\"))]"
  fi
  oc get snapshot $SNAPSHOT -o json | jq "$JQ_FILTER" > $SNAPSHOT_FILE
  COMPONENT_COUNT=$(jq '.spec.components | length' "$SNAPSHOT_FILE")
  if [ -n "$FILTER" ]; then
    echo "Components: $COMPONENT_COUNT matching /$FILTER/ (${SECONDS}s)"
  else
    echo "Components: $COMPONENT_COUNT (${SECONDS}s)"
  fi

  SNAPSHOT_APP=$(jq -r '.spec.application' "$SNAPSHOT_FILE")
  if [ -z "$APPLICATION" ]; then
    APPLICATION=$SNAPSHOT_APP
    echo "Application (from snapshot): $APPLICATION"
  elif [ "$SNAPSHOT_APP" != "$APPLICATION" ]; then
    echo "ERROR: Snapshot application '$SNAPSHOT_APP' does not match APPLICATION='$APPLICATION'"
    exit 1
  fi

  FILTER_SUFFIX=""
  if [ -n "$FILTER" ]; then
    FILTER_SUFFIX="-filtered"
  fi
  RESULTS_FILE=${RESULTS_FILE:-ec-report-${APPLICATION}-${POLICY_STEM}${FILTER_SUFFIX}${TIME_SUFFIX}.yaml}

  COMMAND="ec validate image --ignore-rekor true --workers $WORKERS --file-path $SNAPSHOT_FILE --public-key $PUBKEY --policy $POLICY_FILE --info --output yaml --timeout 30m0s $EFFECTIVE_TIME_FLAG $VERBOSE_FLAG"

  HEADER="# ec command: $COMMAND
# snapshot: $SNAPSHOT
# excluded: $EXCLUDE"
  if [ -n "$FILTER" ]; then
    COMPONENT_NAMES=$(jq -r '.spec.components[].name' "$SNAPSHOT_FILE" | sort | sed 's/^/# - /')
    HEADER="$HEADER
# filter: $FILTER
# components ($COMPONENT_COUNT):
$COMPONENT_NAMES"
  fi

  echo "=== Running EC validation ==="
  echo "$COMMAND"
  SECONDS=0
  { echo "$HEADER"; $COMMAND; } | tee $RESULTS_FILE
  EC_EXIT=$?
  DURATION=$SECONDS

  echo ""
  echo "=== Summary ==="
  echo "Components: $COMPONENT_COUNT"
  echo "Workers:    $WORKERS"
  echo "Duration:   $((DURATION / 60))m $((DURATION % 60))s"
  echo "Exit code:  $EC_EXIT"
fi

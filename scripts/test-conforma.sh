#!/bin/bash

usage() {
  cat <<EOF
Usage: test-conforma.sh (-a <app> | -i <image>) [options]

Run EC validation against a Konflux snapshot or a single container image.

Options:
  -a, --application APP   Konflux application name (e.g. rhoai-v3-4)
  -i, --image IMAGE       Single container image reference (e.g. quay.io/org/image:tag)
  -s, --snapshot NAME     Snapshot name (default: latest push snapshot)
  -p, --policy FILE       Policy file or k8s ref (default: registry-rhoai-prod.yaml)
  -o, --output FILE       Results output file (default: ec-report-APP-POLICY.yaml)
  -w, --workers N         Concurrent workers (default: 50)
  -k, --pubkey KEY        Public key (default: k8s://openshift-pipelines/public-key)
  -v, --verbose           Enable verbose output
  -h, --help              Show this help

Either -a/--application or -i/--image is required.

All options can also be set via environment variables:
  APPLICATION, IMAGE, SNAPSHOT, POLICY_FILE, RESULTS_FILE, WORKERS, PUBKEY, VERBOSE
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--application) APPLICATION="$2"; shift 2 ;;
    -i|--image)       IMAGE="$2"; shift 2 ;;
    -s|--snapshot)    SNAPSHOT="$2"; shift 2 ;;
    -p|--policy)      POLICY_FILE="$2"; shift 2 ;;
    -o|--output)      RESULTS_FILE="$2"; shift 2 ;;
    -w|--workers)     WORKERS="$2"; shift 2 ;;
    -k|--pubkey)      PUBKEY="$2"; shift 2 ;;
    -v|--verbose)     VERBOSE=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ -z "$APPLICATION" ] && [ -z "$IMAGE" ]; then
  echo "ERROR: either APPLICATION (-a) or IMAGE (-i) is required"
  echo ""
  usage
  exit 1
fi
if [ -n "$APPLICATION" ] && [ -n "$IMAGE" ]; then
  echo "ERROR: specify either APPLICATION (-a) or IMAGE (-i), not both"
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

if [ -n "$IMAGE" ]; then
  # Single image mode
  IMAGE_SHORT=${IMAGE##*/}
  IMAGE_SHORT=${IMAGE_SHORT%%@*}
  IMAGE_SHORT=${IMAGE_SHORT%%:*}
  RESULTS_FILE=${RESULTS_FILE:-ec-report-${IMAGE_SHORT}-${POLICY_STEM}.yaml}

  COMMAND="ec validate image --ignore-rekor true --image $IMAGE --public-key $PUBKEY --policy $POLICY_FILE --info --output yaml --timeout 30m0s $VERBOSE_FLAG"

  echo "=== Running EC validation ==="
  echo "Image: $IMAGE"
  echo "$COMMAND"
  SECONDS=0
  $COMMAND | tee $RESULTS_FILE
  EC_EXIT=$?
  DURATION=$SECONDS

  echo ""
  echo "=== Summary ==="
  echo "Image:      $IMAGE"
  echo "Duration:   $((DURATION / 60))m $((DURATION % 60))s"
  echo "Exit code:  $EC_EXIT"
else
  # Snapshot mode
  RESULTS_FILE=${RESULTS_FILE:-ec-report-${APPLICATION}-${POLICY_STEM}.yaml}

  echo "=== Fetching snapshot ==="
  SECONDS=0
  if [ -z "$SNAPSHOT" ]; then
    SNAPSHOT=$(oc get snapshots -l "pac.test.appstudio.openshift.io/event-type in (push, Push),appstudio.openshift.io/application=$APPLICATION" --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
  fi
  echo "Snapshot: $SNAPSHOT (${SECONDS}s)"

  WORK_DIR=$(mktemp -d)
  echo "Work dir: $WORK_DIR"

  SNAPSHOT_FILE=$WORK_DIR/snapshot.json

  echo "=== Downloading snapshot JSON ==="
  SECONDS=0
  oc get snapshot $SNAPSHOT -o json | jq '.spec.components |= [.[] | select(.name | test("fbc-fragment") | not)]' > $SNAPSHOT_FILE
  COMPONENT_COUNT=$(jq '.spec.components | length' "$SNAPSHOT_FILE")
  echo "Components: $COMPONENT_COUNT (${SECONDS}s)"

  SNAPSHOT_APP=$(jq -r '.spec.application' "$SNAPSHOT_FILE")
  if [ "$SNAPSHOT_APP" != "$APPLICATION" ]; then
    echo "ERROR: Snapshot application '$SNAPSHOT_APP' does not match APPLICATION='$APPLICATION'"
    exit 1
  fi

  COMMAND="ec validate image --ignore-rekor true --workers $WORKERS --file-path $SNAPSHOT_FILE --public-key $PUBKEY --policy $POLICY_FILE --info --output yaml --timeout 30m0s $VERBOSE_FLAG"

  echo "=== Running EC validation ==="
  echo "$COMMAND"
  SECONDS=0
  $COMMAND | tee $RESULTS_FILE
  EC_EXIT=$?
  DURATION=$SECONDS

  echo ""
  echo "=== Summary ==="
  echo "Components: $COMPONENT_COUNT"
  echo "Workers:    $WORKERS"
  echo "Duration:   $((DURATION / 60))m $((DURATION % 60))s"
  echo "Exit code:  $EC_EXIT"
fi

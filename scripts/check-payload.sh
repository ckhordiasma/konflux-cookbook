#!/bin/bash

CHECK_PAYLOAD_IMAGE=${CHECK_PAYLOAD_IMAGE:-check-payload:local}
CHECK_PAYLOAD_REPO=${CHECK_PAYLOAD_REPO:-https://github.com/openshift/check-payload.git}

usage() {
  cat <<EOF
Usage: check-payload.sh -i <image> [options]
       check-payload.sh --install

Run check-payload FIPS compliance scan against a container image.

Pulls the image with skopeo, unpacks it with umoci, and runs
check-payload scan local — all inside a container. No --privileged,
no podman-in-podman, no VM SSH required.

Options:
  -i, --image IMAGE           Container image reference (required)
                              Registry: quay.io/org/image@sha256:abc123
                              Local:    localhost/my-image:test (auto-detected)
  -c, --config FILE           Custom check-payload config.toml file
  -o, --output-file FILE      Write report to file on the host
  -f, --output-format FMT     Output format: table, csv, markdown, html (default: table)
      --filter-files LIST     Comma-separated files to skip
      --filter-dirs LIST      Comma-separated directories to skip
  -p, --print-exceptions      Print TOML exception rules for failures
  -v, --verbose               Enable verbose output
      --install               Build the check-payload container image (one-time setup)
  -h, --help                  Show this help

All options can also be set via environment variables:
  IMAGE, CONFIG_FILE, OUTPUT_FILE, OUTPUT_FORMAT, FILTER_FILES, FILTER_DIRS,
  PRINT_EXCEPTIONS, VERBOSE, CHECK_PAYLOAD_IMAGE, CHECK_PAYLOAD_REPO
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--image)            IMAGE="$2"; shift 2 ;;
    -c|--config)           CONFIG_FILE="$2"; shift 2 ;;
    -o|--output-file)      OUTPUT_FILE="$2"; shift 2 ;;
    -f|--output-format)    OUTPUT_FORMAT="$2"; shift 2 ;;
    --filter-files)        FILTER_FILES="$2"; shift 2 ;;
    --filter-dirs)         FILTER_DIRS="$2"; shift 2 ;;
    -p|--print-exceptions) PRINT_EXCEPTIONS=true; shift ;;
    -v|--verbose)          VERBOSE=true; shift ;;
    --install)             INSTALL=true; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# --- Install mode ---

if [ "$INSTALL" = "true" ]; then
  echo "=== Building check-payload container ==="
  TMPDIR=$(mktemp -d)
  trap "rm -rf $TMPDIR" EXIT
  git clone --depth 1 "$CHECK_PAYLOAD_REPO" "$TMPDIR/check-payload" 2>&1
  podman build --platform linux/amd64 \
    -f "$TMPDIR/check-payload/Dockerfile.upstream" \
    -t "$CHECK_PAYLOAD_IMAGE" \
    "$TMPDIR/check-payload" 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to build check-payload container"
    exit 1
  fi
  echo ""
  echo "check-payload container built as $CHECK_PAYLOAD_IMAGE"
  [ -z "$IMAGE" ] && exit 0
fi

# --- Validate inputs ---

if [ -z "$IMAGE" ]; then
  echo "ERROR: IMAGE (-i) is required"
  echo ""
  usage
  exit 1
fi

if ! podman image exists "$CHECK_PAYLOAD_IMAGE" 2>/dev/null; then
  echo "ERROR: check-payload container image not found: $CHECK_PAYLOAD_IMAGE"
  echo "Run: $0 --install"
  exit 1
fi

VERBOSE=${VERBOSE:-false}
PRINT_EXCEPTIONS=${PRINT_EXCEPTIONS:-false}
OUTPUT_FORMAT=${OUTPUT_FORMAT:-table}

# Strip tag from tag@sha256: references (skopeo doesn't support both)
if echo "$IMAGE" | grep -q ':.*@sha256:'; then
  ORIGINAL_IMAGE="$IMAGE"
  IMAGE=$(echo "$IMAGE" | sed 's/:[^@]*@/@/')
  echo "WARNING: skopeo does not support tag+digest references"
  echo "  Stripped tag: $ORIGINAL_IMAGE"
  echo "  Using:        $IMAGE"
  echo ""
fi

# --- Detect local vs registry image ---
# Images with a dot in the first path component are registry references
# (e.g., quay.io/..., registry.access.redhat.com/...).
# Images without a dot are local (e.g., my-image:test, localhost/my-image:test).

IS_LOCAL=false
IMAGE_HOST=$(echo "$IMAGE" | cut -d'/' -f1)
if ! echo "$IMAGE_HOST" | grep -q '\.'; then
  if podman image exists "$IMAGE" 2>/dev/null; then
    IS_LOCAL=true
  fi
fi

# --- Assemble check-payload flags ---

SCAN_FLAGS=""
if [ "$VERBOSE" = "true" ]; then
  SCAN_FLAGS="$SCAN_FLAGS --verbose"
fi
if [ "$PRINT_EXCEPTIONS" = "true" ]; then
  SCAN_FLAGS="$SCAN_FLAGS --print-exceptions"
fi
if [ -n "$OUTPUT_FORMAT" ]; then
  SCAN_FLAGS="$SCAN_FLAGS --output-format $OUTPUT_FORMAT"
fi
if [ -n "$FILTER_FILES" ]; then
  SCAN_FLAGS="$SCAN_FLAGS --filter-files $FILTER_FILES"
fi
if [ -n "$FILTER_DIRS" ]; then
  SCAN_FLAGS="$SCAN_FLAGS --filter-dirs $FILTER_DIRS"
fi

# --- Assemble volume mounts ---

VOLUME_MOUNTS=""

if [ -n "$CONFIG_FILE" ]; then
  CONFIG_FILE=$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")
  VOLUME_MOUNTS="$VOLUME_MOUNTS -v $CONFIG_FILE:/check-payload-config.toml:ro"
  SCAN_FLAGS="$SCAN_FLAGS --config /check-payload-config.toml"
fi

if [ -n "$OUTPUT_FILE" ]; then
  OUTPUT_FILE=$(cd "$(dirname "$OUTPUT_FILE")" 2>/dev/null && pwd)/$(basename "$OUTPUT_FILE")
fi

AUTH_JSON="${XDG_RUNTIME_DIR:-}/containers/auth.json"
if [ -f "$AUTH_JSON" ]; then
  VOLUME_MOUNTS="$VOLUME_MOUNTS -v $AUTH_JSON:/run/containers/0/auth.json:ro"
elif [ -f "$HOME/.docker/config.json" ]; then
  VOLUME_MOUNTS="$VOLUME_MOUNTS -v $HOME/.docker/config.json:/run/containers/0/auth.json:ro"
fi

# --- Export local image if needed ---

CLEANUP_TAR=""
if [ "$IS_LOCAL" = "true" ]; then
  echo "=== Exporting local image ==="
  SAVE_DIR="$HOME/.cache/check-payload"
  mkdir -p "$SAVE_DIR"
  SAVE_PATH="$SAVE_DIR/image.tar"
  podman save --format oci-archive -o "$SAVE_PATH" "$IMAGE" 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to export local image: $IMAGE"
    exit 1
  fi
  VOLUME_MOUNTS="$VOLUME_MOUNTS -v $SAVE_PATH:/tmp/input.tar:ro"
  SKOPEO_SRC="oci-archive:/tmp/input.tar"
  CLEANUP_TAR="$SAVE_PATH"
else
  SKOPEO_SRC="docker://$IMAGE"
fi

# --- Run scan ---

echo "=== Running check-payload FIPS scan ==="
echo "Image: $IMAGE"
if [ "$IS_LOCAL" = "true" ]; then
  echo "Source: local podman storage"
fi
echo ""

SECONDS=0
if [ -n "$OUTPUT_FILE" ]; then
  podman run --platform linux/amd64 --rm --entrypoint bash \
    $VOLUME_MOUNTS \
    "$CHECK_PAYLOAD_IMAGE" -c "
      skopeo copy --remove-signatures \
        $SKOPEO_SRC \
        oci:/tmp/image:scan 2>&1 &&
      umoci unpack --image /tmp/image:scan /tmp/unpacked 2>&1 &&
      /check-payload scan local --path /tmp/unpacked/rootfs $SCAN_FLAGS
    " | tee "$OUTPUT_FILE"
  SCAN_EXIT=${PIPESTATUS[0]}
else
  podman run --platform linux/amd64 --rm --entrypoint bash \
    $VOLUME_MOUNTS \
    "$CHECK_PAYLOAD_IMAGE" -c "
      skopeo copy --remove-signatures \
        $SKOPEO_SRC \
        oci:/tmp/image:scan 2>&1 &&
      umoci unpack --image /tmp/image:scan /tmp/unpacked 2>&1 &&
      /check-payload scan local --path /tmp/unpacked/rootfs $SCAN_FLAGS
    "
  SCAN_EXIT=$?
fi
DURATION=$SECONDS

# --- Cleanup ---

if [ -n "$CLEANUP_TAR" ]; then
  rm -f "$CLEANUP_TAR"
fi

echo ""
echo "=== Summary ==="
echo "Image:     $IMAGE"
echo "Duration:  $((DURATION / 60))m $((DURATION % 60))s"
echo "Exit code: $SCAN_EXIT"

exit $SCAN_EXIT

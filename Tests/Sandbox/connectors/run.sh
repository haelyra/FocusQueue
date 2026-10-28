#!/bin/sh
# Reproducible Tier 1 (rootless Podman) run of the connector setup scenarios.
#
#   Tests/Sandbox/connectors/run.sh [--out DIR] [--direct-only]
#
# 1. Builds localhost/ecc-sandbox:focus-queue-connectors on top of the ECC
#    Tier 1 base image when it is missing.
# 2. Stages a sanitized copy of only Scripts/ and Tests/Sandbox/connectors/
#    (no .git, no home directory, no credentials).
# 3. Runs the ECC manifest through `ecc-sandbox run --local-only`, which routes
#    to rootless Podman, mounts the staging copy read-only, disables the
#    network, and returns a sealed report with a layer diff.
# 4. Repeats the scenarios with the same isolation flags through plain
#    podman create/start/exec/diff/rm to keep the full JSON detail, which the
#    ECC report truncates to a step tail.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
image=${FOCUS_QUEUE_CONNECTOR_IMAGE:-localhost/ecc-sandbox:focus-queue-connectors}
base=${ECC_SANDBOX_BASE_IMAGE:-localhost/ecc-sandbox:ubuntu-lts}
podman=${PODMAN:-podman}
out=""
direct_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --direct-only) direct_only=1; shift ;;
    *) echo "Error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || out=$(mktemp -d "${TMPDIR:-/tmp}/fq-connector-sandbox.XXXXXX")
mkdir -p "$out"

if [ "$("$podman" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" != "true" ]; then
  echo "Error: rootless Podman is required (podman machine start)." >&2
  exit 2
fi
if ! "$podman" image inspect "$base" >/dev/null 2>&1; then
  echo "Error: ECC Tier 1 base image $base is missing. Build it from the ECC checkout:" >&2
  echo "  podman build --file images/sandbox/Containerfile.ubuntu --tag $base images/sandbox" >&2
  exit 2
fi
if ! "$podman" image inspect "$image" >/dev/null 2>&1; then
  "$podman" build --build-arg "BASE_IMAGE=$base" --file "$here/Containerfile" --tag "$image" "$here" >&2
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/fq-connector-stage.XXXXXX")
container="fq-connector-sandbox-$$"
cleanup() {
  "$podman" rm --force --ignore "$container" >/dev/null 2>&1 || true
  rm -rf "$stage"
}
trap cleanup EXIT INT TERM
mkdir -p "$stage/Tests/Sandbox"
cp -R "$repo/Scripts" "$stage/Scripts"
cp -R "$here" "$stage/Tests/Sandbox/connectors"
find "$stage" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
chmod -R a+rX "$stage"

status=0
if [ "$direct_only" -eq 0 ]; then
  if command -v ecc-sandbox >/dev/null 2>&1; then
    (cd "$stage" && ECC_SANDBOX_IMAGE="$image" ecc-sandbox run Tests/Sandbox/connectors/sandbox.yaml --local-only) \
      > "$out/ecc-report.json" || status=$?
    echo "ECC Tier 1 report: $out/ecc-report.json (exit $status)" >&2
  else
    echo "ecc-sandbox is not installed; skipping the ECC-routed run (see README)." >&2
  fi
fi

# Same isolation as the ECC Podman adapter: all capabilities dropped, no
# network, read-only source, uid 1000, private /tmp, bounded resources.
"$podman" create --name "$container" --cap-drop ALL --pids-limit 256 --cpus 1 --memory 512m \
  --tmpfs /tmp:rw,nosuid,nodev,exec,size=256m --volume "$stage:/workspace/source:ro" \
  --workdir /workspace --user 1000:1000 --hostname ecc-sandbox --network none \
  --security-opt no-new-privileges "$image" sleep infinity >/dev/null
"$podman" start "$container" >/dev/null
direct=0
"$podman" exec --env FOCUS_QUEUE_CONNECTOR_SANDBOX=1 "$container" \
  python3 /workspace/source/Tests/Sandbox/connectors/scenarios.py --scripts /workspace/source/Scripts \
  > "$out/scenarios.json" || direct=$?
"$podman" diff "$container" > "$out/container-diff.txt" || true
"$podman" image inspect --format '{{.Id}}' "$image" > "$out/image-id.txt"
echo "Scenario detail: $out/scenarios.json (exit $direct)" >&2
python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print("connector scenarios: %d passed, %d failed" % (data["passed"], data["failed"]))
for item in data["scenarios"]:
    if not item["passed"]:
        print("FAIL", item["scenario"], [c["check"] for c in item["checks"] if not c["passed"]])
' "$out/scenarios.json" >&2 || true
[ "$status" -eq 0 ] && [ "$direct" -eq 0 ]

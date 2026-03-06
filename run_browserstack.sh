#!/usr/bin/env bash
# =============================================================================
# run_browserstack.sh
#
# Builds the APK, uploads app + Maestro test suite to BrowserStack,
# executes the build on a real device, and polls until completion.
#
# Usage:
#   export BROWSERSTACK_USERNAME="your_username"
#   export BROWSERSTACK_ACCESS_KEY="your_access_key"
#   ./run_browserstack.sh
#
# Optional overrides (env vars):
#   BS_DEVICE      Target device (default: "Google Pixel 7-13.0")
#   BS_PROJECT     Project name on BrowserStack dashboard (default: "BrowserMaestroTesting")
#   SKIP_BUILD     Set to "true" to skip ./gradlew assembleDebug
#   VERBOSE        Set to "true" to print raw API responses for debugging
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${BLUE}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK_PATH="${SCRIPT_DIR}/app/build/outputs/apk/debug/app-debug.apk"
MAESTRO_DIR="${SCRIPT_DIR}/.maestro"
BS_BASE_URL="https://api-cloud.browserstack.com"
BS_DEVICE="${BS_DEVICE:-Google Pixel 7-13.0}"
BS_PROJECT="${BS_PROJECT:-BrowserMaestroTesting}"
SKIP_BUILD="${SKIP_BUILD:-false}"
VERBOSE="${VERBOSE:-false}"
POLL_INTERVAL=15  # seconds between status checks

# Flows to execute (paths relative to the parent folder inside the zip)
EXECUTE_FLOWS=("01_launch_app.yaml" "02_open_and_interact.yaml")

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}BrowserStack Maestro Runner${RESET}"
echo -e "────────────────────────────────────────"

[[ -z "${BROWSERSTACK_USERNAME:-}" ]] && die "BROWSERSTACK_USERNAME is not set. Export it before running."
[[ -z "${BROWSERSTACK_ACCESS_KEY:-}" ]] && die "BROWSERSTACK_ACCESS_KEY is not set. Export it before running."

command -v curl >/dev/null 2>&1 || die "'curl' is required but not installed."
command -v jq   >/dev/null 2>&1 || die "'jq' is required. Install with: brew install jq"
command -v zip  >/dev/null 2>&1 || die "'zip' is required but not installed."

[[ -d "${MAESTRO_DIR}" ]] || die "Maestro flows directory not found: ${MAESTRO_DIR}"
[[ -n "$(ls "${MAESTRO_DIR}"/*.yaml 2>/dev/null)" ]] || die "No .yaml files found in ${MAESTRO_DIR}"

BS_AUTH="${BROWSERSTACK_USERNAME}:${BROWSERSTACK_ACCESS_KEY}"

log "Device:  ${BS_DEVICE}"
log "Project: ${BS_PROJECT}"
log "Flows:   $(ls "${MAESTRO_DIR}"/*.yaml | xargs -n1 basename | tr '\n' ' ')"

# ── Step 1: Build APK ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 1/5: Building debug APK${RESET}"

if [[ "${SKIP_BUILD}" == "true" ]]; then
    warn "SKIP_BUILD=true — skipping Gradle build."
    [[ -f "${APK_PATH}" ]] || die "APK not found at ${APK_PATH}. Build it first or unset SKIP_BUILD."
else
    log "Running ./gradlew assembleDebug ..."
    cd "${SCRIPT_DIR}"
    ./gradlew assembleDebug --quiet || die "Gradle build failed."
    [[ -f "${APK_PATH}" ]] || die "APK not found at ${APK_PATH} after build."
fi

APK_SIZE=$(du -sh "${APK_PATH}" | cut -f1)
ok "APK ready (${APK_SIZE}): ${APK_PATH}"

# ── Step 2: Upload APK ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 2/5: Uploading app to BrowserStack${RESET}"
log "Uploading APK ..."

APP_RESPONSE=$(curl --silent --fail \
    -u "${BS_AUTH}" \
    -X POST "${BS_BASE_URL}/app-automate/maestro/v2/app" \
    -F "file=@${APK_PATH}" \
    -F "custom_id=BrowserMaestroApp") || die "APK upload request failed. Check your credentials."

APP_URL=$(echo "${APP_RESPONSE}" | jq -r '.app_url // empty')
[[ "${APP_URL}" == bs://* ]] || die "APK upload failed. Response:\n${APP_RESPONSE}"

APP_ID=$(echo "${APP_RESPONSE}" | jq -r '.app_id')
ok "App uploaded — app_url: ${APP_URL}"
log "Expires: $(echo "${APP_RESPONSE}" | jq -r '.expiry')"

# ── Step 3: Package + Upload test suite ───────────────────────────────────────
echo ""
echo -e "${BOLD}Step 3/5: Packaging and uploading Maestro test suite${RESET}"

# BrowserStack requires ALL flow files inside a single parent folder in the zip.
# Structure: flows/01_launch_app.yaml, flows/02_open_and_interact.yaml
TMPDIR_TS=$(mktemp -d)
trap 'rm -rf "${TMPDIR_TS}"' EXIT

PARENT_FOLDER="${TMPDIR_TS}/flows"
mkdir -p "${PARENT_FOLDER}"
cp "${MAESTRO_DIR}"/*.yaml "${PARENT_FOLDER}/"

ZIP_PATH="${TMPDIR_TS}/maestro_tests.zip"
(cd "${TMPDIR_TS}" && zip -r "${ZIP_PATH}" flows/ -x "*.DS_Store" >/dev/null)

log "Zip contents:"
unzip -l "${ZIP_PATH}" | grep "\.yaml" | awk '{print "  " $NF}'
log "Uploading test suite ..."

SUITE_RESPONSE=$(curl --silent --fail \
    -u "${BS_AUTH}" \
    -X POST "${BS_BASE_URL}/app-automate/maestro/v2/test-suite" \
    -F "file=@${ZIP_PATH}" \
    -F "custom_id=BrowserMaestroSuite") || die "Test suite upload request failed."

SUITE_URL=$(echo "${SUITE_RESPONSE}" | jq -r '.test_suite_url // empty')
[[ "${SUITE_URL}" == bs://* ]] || die "Test suite upload failed. Response:\n${SUITE_RESPONSE}"

ok "Test suite uploaded — test_suite_url: ${SUITE_URL}"
log "Expires: $(echo "${SUITE_RESPONSE}" | jq -r '.expiry')"

# ── Step 4: Execute build ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 4/5: Triggering BrowserStack build${RESET}"

# Build the execute JSON array from EXECUTE_FLOWS
EXECUTE_JSON=$(printf '%s\n' "${EXECUTE_FLOWS[@]}" | jq -R . | jq -s .)

BUILD_PAYLOAD=$(jq -n \
    --arg  app     "${APP_URL}" \
    --arg  suite   "${SUITE_URL}" \
    --arg  project "${BS_PROJECT}" \
    --arg  device  "${BS_DEVICE}" \
    --argjson execute "${EXECUTE_JSON}" \
    '{
        app:              $app,
        testSuite:        $suite,
        project:          $project,
        devices:          [$device],
        execute:          $execute,
        deviceLogs:       "true",
        networkLogs:      "true",
        debugscreenshots: true
    }')

log "Payload: $(echo "${BUILD_PAYLOAD}" | jq -c .)"

BUILD_RESPONSE=$(curl --silent \
    -u "${BS_AUTH}" \
    -X POST "${BS_BASE_URL}/app-automate/maestro/v2/android/build" \
    -H "Content-Type: application/json" \
    -d "${BUILD_PAYLOAD}")
[[ $VERBOSE == "true" ]] && warn "Raw build response: ${BUILD_RESPONSE}"

BUILD_ID=$(echo "${BUILD_RESPONSE}" | jq -r '.build_id // empty')
[[ -n "${BUILD_ID}" ]] || die "Failed to start build. Response:\n${BUILD_RESPONSE}"

ok "Build started — build_id: ${BUILD_ID}"
echo ""
log "Dashboard: https://app-automate.browserstack.com/builds/${BUILD_ID}"

# ── Step 5: Poll for build completion ─────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 5/5: Waiting for build to complete${RESET}"
log "Polling every ${POLL_INTERVAL}s (Ctrl+C to stop polling — build will keep running)"

FINAL_STATUS=""
STATUS_RESPONSE=""
DOTS=0

while true; do
    STATUS_RESPONSE=$(curl --silent --fail \
        -u "${BS_AUTH}" \
        -X GET "${BS_BASE_URL}/app-automate/maestro/v2/builds/${BUILD_ID}") || {
        warn "Status check failed — retrying in ${POLL_INTERVAL}s ..."
        sleep "${POLL_INTERVAL}"
        continue
    }

    CURRENT_STATUS=$(echo "${STATUS_RESPONSE}" | jq -r '.status // "unknown"')

    case "${CURRENT_STATUS}" in
        running|queued)
            DOTS=$(( (DOTS + 1) % 4 ))
            SPINNER=$(printf '%0.s.' $(seq 1 $DOTS))
            echo -ne "\r  ${YELLOW}⏳ ${CURRENT_STATUS}${SPINNER}         ${RESET}"
            sleep "${POLL_INTERVAL}"
            ;;
        passed)
            echo ""
            FINAL_STATUS="passed"
            break
            ;;
        failed|error|timeout|timedout)
            echo ""
            FINAL_STATUS="${CURRENT_STATUS}"
            break
            ;;
        *)
            warn "Unknown status '${CURRENT_STATUS}' — continuing to poll ..."
            sleep "${POLL_INTERVAL}"
            ;;
    esac
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════${RESET}"

if [[ "${FINAL_STATUS}" == "passed" ]]; then
    echo -e "${GREEN}${BOLD}✅  Build PASSED${RESET}"
else
    echo -e "${RED}${BOLD}❌  Build $(echo "${FINAL_STATUS}" | tr '[:lower:]' '[:upper:]')${RESET}"
fi

echo -e "${BOLD}Build ID:  ${RESET}${BUILD_ID}"
echo -e "${BOLD}Dashboard: ${RESET}https://app-automate.browserstack.com/builds/${BUILD_ID}"
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo ""

# Per-device / per-session summary
echo "${STATUS_RESPONSE}" | jq -r '
    .devices[]? |
    "📱 \(.device) (Android \(.os_version))",
    (.sessions[]? |
        "   Session \(.id[0:8])…  status=\(.status)  " +
        "passed=\(.testcases.status.passed // 0)  " +
        "failed=\(.testcases.status.failed // 0)  " +
        "skipped=\(.testcases.status.skipped // 0)")
' 2>/dev/null || true

# On failure, dump the full raw status response to help diagnose the root cause
if [[ "${FINAL_STATUS}" != "passed" ]]; then
    echo ""
    echo -e "${YELLOW}── Full build status (for debugging) ──────────────────${RESET}"
    echo "${STATUS_RESPONSE}" | jq . 2>/dev/null || echo "${STATUS_RESPONSE}"
    echo -e "${YELLOW}────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "${YELLOW}Tip: run with VERBOSE=true ./run_browserstack.sh for raw API responses${RESET}"
fi

echo ""
[[ "${FINAL_STATUS}" == "passed" ]] && exit 0 || exit 1

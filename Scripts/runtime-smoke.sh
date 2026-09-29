#!/usr/bin/env bash
set -euo pipefail

# Verifies that an extracted Runtime artifact can actually be used by DSH Studio.
#
# The argument is an artifact root (manifest.json, node/, harness/), which is
# what build-runtime.sh passes after extracting the archive it just produced, so
# the checks run against the published bytes rather than against the staging
# tree. No account and no API quota are needed, and nothing outside the registry
# is contacted: the one network step is installing the plugin market pin the
# manifest publishes into a scratch profile, which
# DSH_RUNTIME_SMOKE_SKIP_PLUGIN_MARKET=1 turns off. Harness protocol changes
# still fail the build on purpose.

RUNTIME_ROOT="${1:-}"
[ -n "$RUNTIME_ROOT" ] || { printf 'runtime-smoke: runtime root is required\n' >&2; exit 1; }
[ -d "$RUNTIME_ROOT" ] || { printf 'runtime-smoke: root does not exist: %s\n' "$RUNTIME_ROOT" >&2; exit 1; }
RUNTIME_ROOT="$(cd "$RUNTIME_ROOT" && pwd)"

fail() {
    printf 'runtime-smoke: %s\n' "$1" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"

MANIFEST="$RUNTIME_ROOT/manifest.json"
[ -f "$MANIFEST" ] || fail "manifest.json is missing from the Runtime"

# The packaged Node is the only toolchain this test trusts: the host Node is not
# pinned and must not be able to change the outcome.
NODE_CANDIDATES=("$RUNTIME_ROOT"/node/*/bin/node)
[ "${#NODE_CANDIDATES[@]}" -eq 1 ] || fail "expected exactly one packaged Node, found ${#NODE_CANDIDATES[@]}"
NODE_EXECUTABLE="${NODE_CANDIDATES[0]}"
[ -x "$NODE_EXECUTABLE" ] || fail "packaged Node is not executable: $NODE_EXECUTABLE"

manifest_value() {
    "$NODE_EXECUTABLE" -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const value = manifest[process.argv[2]];
if (value === undefined || value === null) process.exit(1);
process.stdout.write(String(value));
' "$MANIFEST" "$1"
}

ARCHITECTURE="$(manifest_value architecture)" || fail "manifest.json is missing architecture"
RUNTIME_VERSION="$(manifest_value runtimeVersion)" || fail "manifest.json is missing runtimeVersion"
NODE_VERSION="$(manifest_value nodeVersion)" || fail "manifest.json is missing nodeVersion"
HARNESS_VERSION="$(manifest_value harnessVersion)" || fail "manifest.json is missing harnessVersion"
PNPM_VERSION="$(manifest_value pnpmVersion)" || fail "manifest.json is missing pnpmVersion"

case "$ARCHITECTURE" in
    darwin-arm64) EXPECTED_CPU="arm64" ;;
    darwin-x64) EXPECTED_CPU="x86_64" ;;
    *) fail "unsupported Runtime architecture in manifest: $ARCHITECTURE" ;;
esac

[ "$NODE_EXECUTABLE" = "$RUNTIME_ROOT/node/$ARCHITECTURE/bin/node" ] || fail \
    "packaged Node is not at the path DSH Studio expects: node/$ARCHITECTURE/bin/node"

HARNESS_ROOT="$RUNTIME_ROOT/harness/$ARCHITECTURE/$HARNESS_VERSION"
HARNESS_ENTRY="$HARNESS_ROOT/node_modules/@deepseek-ai/dsh/lib/bin.js"
PNPM_EXECUTABLE="$HARNESS_ROOT/node_modules/.bin/pnpm"
PTY_BINARY="$HARNESS_ROOT/node_modules/node-pty/prebuilds/$ARCHITECTURE/pty.node"
SPAWN_HELPER="$HARNESS_ROOT/node_modules/node-pty/prebuilds/$ARCHITECTURE/spawn-helper"

[ -x "$NODE_EXECUTABLE" ] || fail "Node is not executable"
[ -f "$HARNESS_ENTRY" ] || fail "Harness entry is missing"
[ -x "$PNPM_EXECUTABLE" ] || fail "pnpm shim is not executable"
[ -f "$PTY_BINARY" ] || fail "node-pty binary is missing"
[ -x "$SPAWN_HELPER" ] || fail "node-pty helper is not executable"

# The x64 Runtime is built on an Apple Silicon runner, where a wrongly built
# binary still runs under Rosetta. Ask the Mach-O headers directly instead. This
# needs macOS; every check above is structural and therefore runs anywhere.
command -v lipo >/dev/null 2>&1 || fail "lipo is required to verify the packaged architecture"

assert_architecture() {
    local file="$1" architectures
    architectures="$(lipo -archs "$file" 2>/dev/null)" || fail "not a Mach-O binary: $file"
    case " $architectures " in
        *" $EXPECTED_CPU "*) ;;
        *) fail "$file is built for [$architectures], expected $EXPECTED_CPU" ;;
    esac
}

assert_architecture "$NODE_EXECUTABLE"
assert_architecture "$PTY_BINARY"
assert_architecture "$SPAWN_HELPER"

ACTUAL_NODE_VERSION="$("$NODE_EXECUTABLE" --version | tr -d '[:space:]')"
[ "$ACTUAL_NODE_VERSION" = "v$NODE_VERSION" ] || {
    printf 'runtime-smoke: expected Node v%s, got %s\n' "$NODE_VERSION" "$ACTUAL_NODE_VERSION" >&2
    exit 1
}

ACTUAL_PNPM_VERSION="$("$PNPM_EXECUTABLE" --version 2>/dev/null || true)"
ACTUAL_PNPM_VERSION="$(printf '%s' "$ACTUAL_PNPM_VERSION" | tr -d '[:space:]')"
[ "$ACTUAL_PNPM_VERSION" = "$PNPM_VERSION" ] || {
    printf 'runtime-smoke: expected pnpm %s, got %s\n' "$PNPM_VERSION" "$ACTUAL_PNPM_VERSION" >&2
    exit 1
}

# Native modules must load in the packaged Runtime: a wrong architecture or a
# wrong NODE_MODULE_VERSION only fails when the module is dlopen'd, which is far
# too late once the artifact is published.
require_module() {
    local module="$1"
    if ! (cd "$HARNESS_ROOT" && "$NODE_EXECUTABLE" -e "require('$module')" >/dev/null 2>&1); then
        fail "native module failed to load with the packaged Node: $module"
    fi
}

require_module node-pty
if [ -d "$HARNESS_ROOT/node_modules/fs-ext" ]; then
    require_module fs-ext
fi

# node-pty alone is not enough: the terminal feature depends on spawn-helper
# actually starting a process.
if ! (cd "$HARNESS_ROOT" && "$NODE_EXECUTABLE" -e '
const pty = require("node-pty");
const child = pty.spawn("/bin/echo", ["runtime-smoke-pty"], { name: "xterm-color", cols: 80, rows: 24 });
let output = "";
const finish = (code) => { clearTimeout(timer); try { child.kill(); } catch {} process.exit(code); };
const timer = setTimeout(() => finish(1), 15000);
child.onData((data) => {
  output += data;
  if (output.includes("runtime-smoke-pty")) finish(0);
});
child.onExit(() => finish(output.includes("runtime-smoke-pty") ? 0 : 1));
'); then
    fail "node-pty could not spawn a process"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-smoke.XXXXXX")"
LOG_FILE="$TEMP_ROOT/harness.log"
RESPONSE_FILE="$TEMP_ROOT/health.json"
COOKIE_JAR="$TEMP_ROOT/cookies.txt"
MARKET_LOG="$TEMP_ROOT/plugin-market.log"
# Keep the Harness away from the real user profile so a developer machine cannot
# mask a broken default and the Harness cannot touch real user data.
SMOKE_HOME="$TEMP_ROOT/home"
DSH_HOME="$TEMP_ROOT/dsh-home"
mkdir -p "$SMOKE_HOME" "$DSH_HOME"

# Installs the plugin market pin this Runtime publishes, exactly the way DSH
# Studio does it (`plugin --profile web add <package>@<version> --save-exact`),
# so the boot below loads the market the app will load. A Runtime that publishes
# no pin is skipped: the client then falls back to its own compiled pin.
run_plugin_market_phase() {
    local pin_fields market_package market_version market_integrity
    pin_fields="$("$NODE_EXECUTABLE" -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const pin = manifest.pluginMarket;
process.stdout.write(pin ? [pin.package || "", pin.version || "", pin.integrity || ""].join("\t") : "\t\t");
' "$MANIFEST")"
    IFS=$'\t' read -r market_package market_version market_integrity <<< "$pin_fields"

    if [ -z "$market_package" ]; then
        printf 'runtime-smoke: the Runtime publishes no plugin market pin; skipping the market check\n'
        return 0
    fi
    if [ "${DSH_RUNTIME_SMOKE_SKIP_PLUGIN_MARKET:-0}" = "1" ]; then
        printf 'runtime-smoke: plugin market check skipped by request\n'
        return 0
    fi

    local registry
    registry="$(manifest_value registry 2>/dev/null || true)"
    [ -n "$registry" ] || registry="https://registry.npmjs.org"
    registry="${registry%/}/"

    printf 'runtime-smoke: installing %s@%s into a scratch profile\n' "$market_package" "$market_version"
    if ! (
        cd "$TEMP_ROOT"
        PATH="$(dirname "$NODE_EXECUTABLE"):$(dirname "$PNPM_EXECUTABLE"):$PATH" \
        HOME="$SMOKE_HOME" \
        DSH_HOME="$DSH_HOME" \
        DSH_TELEMETRY_DISABLED=1 \
        CI=1 \
        npm_config_registry="$registry" \
        NPM_CONFIG_REGISTRY="$registry" \
        npm_config_audit=false \
        npm_config_fund=false \
        npm_config_ignore_scripts=true \
        NPM_CONFIG_IGNORE_SCRIPTS=true \
            "$NODE_EXECUTABLE" "$HARNESS_ENTRY" plugin --profile web add \
            "$market_package@$market_version" --save-exact \
            >"$MARKET_LOG" 2>&1
    ); then
        printf 'runtime-smoke: installing the pinned plugin market failed\n' >&2
        sed -n '1,80p' "$MARKET_LOG" >&2 || true
        return 1
    fi

    "$NODE_EXECUTABLE" - "$DSH_HOME/profiles/web" "$market_package" "$market_version" "$market_integrity" <<'NODE'
const fs = require("fs");
const path = require("path");

const [profileRoot, packageName, version, integrity] = process.argv.slice(2);
const fail = (message) => {
  process.stderr.write(`runtime-smoke: ${message}\n`);
  process.exit(1);
};

const profileManifest = JSON.parse(fs.readFileSync(path.join(profileRoot, "package.json"), "utf8"));
const spec = (profileManifest.dependencies || {})[packageName];
if (spec !== version) fail(`the profile pins ${spec || "nothing"} instead of ${packageName}@${version}`);

const installedRoot = path.join(profileRoot, "node_modules", packageName);
const installed = JSON.parse(fs.readFileSync(path.join(installedRoot, "package.json"), "utf8"));
if (installed.version !== version) fail(`${packageName} installed ${installed.version}, expected ${version}`);
if (!installed.main || !fs.existsSync(path.join(installedRoot, installed.main))) {
  fail(`${packageName}@${version} does not expose the entry point the market needs`);
}

const lock = fs.readFileSync(path.join(profileRoot, "pnpm-lock.yaml"), "utf8");
if (!lock.includes(`${packageName}@${version}`)) fail(`pnpm-lock.yaml does not pin ${packageName}@${version}`);
if (!lock.includes(integrity)) fail(`pnpm-lock.yaml does not pin the published integrity of ${packageName}@${version}`);

const peers = installed.peerDependencies || {};
const declared = peers["@deepseek-ai/dsh-settings"] || peers["@deepseek-ai/dsh"];
process.stdout.write(
  `runtime-smoke: plugin market ready: ${packageName}@${version}` +
  (declared ? ` (declares Harness ${declared})\n` : "\n"));
NODE
    return $?
}

# Returns 0 when the Harness exits on SIGTERM, non-zero when it had to be
# escalated to SIGKILL.
stop_harness() {
    [ -n "${HARNESS_PID:-}" ] || return 0
    kill -0 "$HARNESS_PID" 2>/dev/null || return 0
    kill -TERM "$HARNESS_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$HARNESS_PID" 2>/dev/null || return 0
        sleep 0.5
    done
    return 1
}

force_stop_harness() {
    [ -n "${HARNESS_PID:-}" ] || return 0
    kill -0 "$HARNESS_PID" 2>/dev/null || return 0
    kill -KILL "$HARNESS_PID" 2>/dev/null || true
    return 0
}

cleanup() {
    if ! stop_harness; then
        force_stop_harness
    fi
    if [ -n "${HARNESS_PID:-}" ]; then
        wait "$HARNESS_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

# The market is installed first so the boot below exercises the profile DSH
# Studio will actually run: a pinned market that breaks the Harness would fail
# here instead of on a user's machine.
run_plugin_market_phase || exit 1

# The Harness needs the packaged Node and pnpm first on PATH for its own
# shebangs; it runs directly in the background so signals reach it and not an
# intermediate shell.
cd "$TEMP_ROOT"
PATH="$(dirname "$NODE_EXECUTABLE"):$(dirname "$PNPM_EXECUTABLE"):$PATH" \
HOME="$SMOKE_HOME" \
XDG_CONFIG_HOME="$SMOKE_HOME/.config" \
XDG_CACHE_HOME="$SMOKE_HOME/.cache" \
XDG_DATA_HOME="$SMOKE_HOME/.local/share" \
DSH_HOME="$DSH_HOME" \
DSH_TELEMETRY_DISABLED=1 \
    "$NODE_EXECUTABLE" "$HARNESS_ENTRY" web --host 127.0.0.1 --port 0 --no-open \
    >"$LOG_FILE" 2>&1 &
HARNESS_PID=$!

READY_URL=""
HEALTHY=0
for _ in $(seq 1 120); do
    READY_URL="$(sed -n 's/.*\(http:\/\/127\.0\.0\.1:[0-9][0-9]*\/?token=[^[:space:]]*\).*/\1/p' "$LOG_FILE" | tail -n 1 || true)"
    if [ -n "$READY_URL" ]; then
        READY_BASE_URL="$(printf '%s' "$READY_URL" | sed 's#/?token=.*##')"
        if curl -fsS \
            --connect-timeout 5 --max-time 20 \
            -c "$COOKIE_JAR" \
            "$READY_URL" >/dev/null && \
            curl -fsS -X POST \
            --connect-timeout 5 --max-time 30 \
            -b "$COOKIE_JAR" \
            -H 'Content-Type: application/json' \
            --data '{"type":"client-request","rpcId":"runtime-smoke","method":"settings/describe","payload":{"args":{}}}' \
            "$READY_BASE_URL/api/settings/describe" > "$RESPONSE_FILE"; then
            if "$NODE_EXECUTABLE" -e '
const fs = require("fs");
const response = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!response.result || response.result.ok !== true) process.exit(1);
' "$RESPONSE_FILE"; then
                HEALTHY=1
                break
            fi
        fi
    fi
    if ! kill -0 "$HARNESS_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

if [ "$HEALTHY" -ne 1 ]; then
    printf 'runtime-smoke: Harness did not pass settings/describe\n' >&2
    sed -n '1,240p' "$LOG_FILE" >&2 || true
    exit 1
fi

kill -0 "$HARNESS_PID" 2>/dev/null || {
    printf 'runtime-smoke: Harness exited immediately after a successful probe\n' >&2
    exit 1
}

# DSH Studio stops the Runtime with SIGTERM when the app quits, so a Harness
# that ignores it would leave the app unable to shut down cleanly.
if ! stop_harness; then
    printf 'runtime-smoke: Harness did not exit within 10s of SIGTERM\n' >&2
    sed -n '1,120p' "$LOG_FILE" >&2 || true
    exit 1
fi
wait "$HARNESS_PID" 2>/dev/null || true
HARNESS_PID=""

printf 'Runtime smoke passed: %s / Harness %s / Node %s / pnpm %s / %s\n' \
    "$RUNTIME_VERSION" "$HARNESS_VERSION" "$NODE_VERSION" "$PNPM_VERSION" "$ARCHITECTURE"

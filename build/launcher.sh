#!/bin/sh
# dsh portable launcher (Linux / macOS).
#
# Sits next to the bundled `node` binary and `dsh-pkg/` package directory:
#
#   dsh-portable-linux-x64/
#   ├── dsh          <- this script (make it executable)
#   ├── node         <- bundled Node.js for this platform
#   └── dsh-pkg/     <- the dsh package (platform-correct node_modules)
#
# Usage: ./dsh web | ./dsh <dsh args...>
# Web mode (no args, `web`, or `--profile web`) mirrors the Windows exe:
#   * single-instance lock per data root (prevents two servers corrupting
#     the same session logs)
#   * startup update check against the GitHub release
#   * opens the browser once the `dsh web: http://...` line appears
set -e

VERSION="0.1.0-rc.8"
REPO="MM071022/dsh-portable"
DEFAULT_PORT="3080"

# --- locate self + siblings --------------------------------------------------
SELF="$0"
case "$SELF" in
    */*) ;;
    *) SELF="$(command -v "$SELF" 2>/dev/null || printf '%s' "$SELF")" ;;
esac
BASE="$(cd "$(dirname "$SELF")" && pwd)"
NODE="$BASE/node"
DSH_DIR="$BASE/dsh-pkg"
ENTRY="$DSH_DIR/lib/bin.js"

if [ ! -x "$NODE" ]; then
    echo "dsh: bundled node binary not found or not executable: $NODE" >&2
    exit 1
fi
if [ ! -f "$ENTRY" ]; then
    echo "dsh: dsh entry not found: $ENTRY" >&2
    exit 1
fi

# --- platform + data root ----------------------------------------------------
OS="$(uname -s)"
case "$OS" in
    Darwin) OSNAME="darwin" ;;
    Linux)  OSNAME="linux" ;;
    *)
        echo "dsh: unsupported OS: $OS (this build is for Linux/macOS)" >&2
        exit 1
        ;;
esac

DATA_ROOT="$HOME/.dsh"
mkdir -p "$DATA_ROOT"

# --- helpers -----------------------------------------------------------------
open_browser() {
    if [ "$OSNAME" = "darwin" ]; then
        open "$1" >/dev/null 2>&1 || true
    else
        (xdg-open "$1" >/dev/null 2>&1 || true) &
    fi
}

# Exit 0 only when the port serves a page that identifies itself as dsh.
dsh_web_open() {
    "$NODE" -e 'const h=require("http"),r=h.get({host:"127.0.0.1",port:process.argv[1],path:"/",timeout:700},x=>{let b="";x.setEncoding("utf8");x.on("data",c=>{if(b.length<65536)b+=c});x.on("end",()=>process.exit(/dsh|deepseek harness/i.test(b)?0:1))});r.on("timeout",()=>r.destroy());r.on("error",()=>process.exit(1))' "$1" >/dev/null 2>&1
}

find_port() {
    prev=""
    for a in "$@"; do
        if [ "$prev" = "--port" ] && printf '%s' "$a" | grep -qE '^[0-9]+$'; then
            printf '%s' "$a"
            return 0
        fi
        prev="$a"
    done
    printf '%s' "$DEFAULT_PORT"
}

check_update() {
    if command -v curl >/dev/null 2>&1; then
        latest="$(curl -fsSL --max-time 4 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" || true
        [ -n "$latest" ] || return 0
        latest_v="${latest#v}"
        if [ "$latest_v" != "$VERSION" ]; then
            printf '\n  dsh-portable %s is available (you are on %s)\n  download: https://github.com/%s/releases/latest\n\n' "$latest_v" "$VERSION" "$REPO"
        fi
    fi
}

# --- web-mode detection ------------------------------------------------------
webmode=0
if [ "$#" -eq 0 ] || [ "$1" = "web" ]; then
    webmode=1
elif [ "$1" = "--profile" ] && [ "$2" = "web" ]; then
    webmode=1
fi

if [ "$webmode" -eq 0 ]; then
    exec "$NODE" "$ENTRY" "$@"
fi

# --- web mode ----------------------------------------------------------------
port="$(find_port "$@")"
if [ "$port" != "0" ] && dsh_web_open "$port"; then
    open_browser "http://127.0.0.1:$port"
    exit 0
fi

# Single-instance lock: a lock directory is atomic on POSIX; a stale lock (dead
# pid) is recovered automatically.
LOCK="$DATA_ROOT/.instance-lock"
acquired=0
if mkdir "$LOCK" 2>/dev/null; then
    acquired=1
elif [ -f "$LOCK/pid" ]; then
    lockpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -z "$lockpid" ] || ! kill -0 "$lockpid" 2>/dev/null; then
        rm -rf "$LOCK"
        if mkdir "$LOCK" 2>/dev/null; then
            acquired=1
        fi
    fi
fi
if [ "$acquired" -eq 0 ]; then
    echo "dsh: another dsh web instance is already running for this data directory ($DATA_ROOT); stop it before starting another (running two servers corrupts session history)." >&2
    exit 1
fi
printf '%s' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

check_update

# Start the server through a FIFO so output stays visible without losing the
# Node process exit status (a plain POSIX pipeline reports the reader's status).
opened=0
stream_dir="$(mktemp -d)"
stream="$stream_dir/output"
mkfifo "$stream"
child_pid=""
cleanup() {
    if [ -n "$child_pid" ]; then kill "$child_pid" 2>/dev/null || true; fi
    rm -rf "$LOCK" "$stream_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

"$NODE" "$ENTRY" "$@" >"$stream" 2>&1 &
child_pid=$!
while IFS= read -r line; do
    printf '%s\n' "$line"
    if [ "$opened" -eq 0 ]; then
        case "$line" in
            *"http://"*)
                url="${line#*http://}"
                url="http://${url%%[[:space:]]*}"
                open_browser "$url"
                opened=1
                ;;
        esac
    fi
done <"$stream"

if wait "$child_pid"; then status=0; else status=$?; fi
child_pid=""
exit "$status"

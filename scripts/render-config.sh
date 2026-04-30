#!/bin/sh
# render-config.sh — merge CORPLINK_* environment variables into
# /config/config.json, preserving fields that corplink-rs generates at
# runtime (device_id, public_key, private_key, state, ...).
#
# Design:
#   1. Read existing config.json (or start with {}).
#   2. Build a JSON "overrides" object from the CORPLINK_* env vars.
#      - Strings go in as JSON strings.
#      - Booleans accept true/false/1/0/yes/no (case-insensitive).
#      - Arrays (currently only vpn_disallowed_routes) are comma-separated.
#      - Literal "null" (case-insensitive) becomes JSON null for any type.
#      - Empty env var ("") is treated as UNSET and skipped — so
#        `docker run -e FOO=` cannot blow away user state.
#   3. Merge: `existing * overrides` using jq's `*` operator
#      (overrides win, missing keys are kept from existing).
#
# Idempotent: running with the same env vars twice is a no-op on disk.
# Safe: if config.json exists but is not valid JSON we refuse to touch it.

set -eu

CONFIG_DIR="${CORPLINK_CONFIG_DIR:-/config}"
CONFIG_FILE="${CONFIG_DIR}/config.json"

mkdir -p "$CONFIG_DIR"

# ----------------------------------------------------------------------------
# Helper: is any CORPLINK_* env var set to a non-empty value?
# ----------------------------------------------------------------------------
any_env_set() {
    env | grep -qE '^CORPLINK_[A-Z0-9_]+=.' && return 0 || return 1
}

if [ ! -e "$CONFIG_FILE" ] && ! any_env_set; then
    echo "[render-config] no config.json and no CORPLINK_* env vars; will wait for user."
    exit 0
fi

# ----------------------------------------------------------------------------
# Load or seed existing config.
# ----------------------------------------------------------------------------
if [ -e "$CONFIG_FILE" ]; then
    if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "[render-config] ERROR: $CONFIG_FILE is not valid JSON; refusing to modify." >&2
        exit 1
    fi
    EXISTING_FILE="$CONFIG_FILE"
else
    EXISTING_FILE="$(mktemp)"
    echo '{}' > "$EXISTING_FILE"
    TRAP_TMPS="$EXISTING_FILE"
fi

# ----------------------------------------------------------------------------
# Build overrides.json from env vars.
#
# We start with {} and progressively pipe it through jq invocations.  Each
# call is small, typed via --arg / --argjson, and we never build a single
# giant shell expression — so there is no sed/awk/quoting fragility.
# ----------------------------------------------------------------------------
OVERRIDES="$(mktemp)"
TRAP_TMPS="${TRAP_TMPS:-}${TRAP_TMPS:+ }$OVERRIDES"
# shellcheck disable=SC2064
trap "rm -f $TRAP_TMPS" EXIT
echo '{}' > "$OVERRIDES"

# Lowercase a string using tr (POSIX, works in busybox ash).
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Add a string field.
add_str() {
    _env="$1"; _key="$2"
    eval "_val=\${$_env-__UNSET__}"
    [ "$_val" = "__UNSET__" ] && return 0
    [ -z "$_val" ] && return 0

    if [ "$(_lc "$_val")" = "null" ]; then
        jq --arg k "$_key" '.[$k] = null' "$OVERRIDES" > "$OVERRIDES.new"
    else
        jq --arg k "$_key" --arg v "$_val" '.[$k] = $v' "$OVERRIDES" > "$OVERRIDES.new"
    fi
    mv "$OVERRIDES.new" "$OVERRIDES"
}

# Add a boolean field.
add_bool() {
    _env="$1"; _key="$2"
    eval "_val=\${$_env-__UNSET__}"
    [ "$_val" = "__UNSET__" ] && return 0
    [ -z "$_val" ] && return 0

    case "$(_lc "$_val")" in
        true|1|yes)  _jv=true ;;
        false|0|no)  _jv=false ;;
        null)        _jv=null ;;
        *)
            echo "[render-config] WARN: $_env=$_val is not a boolean; skipping" >&2
            return 0
            ;;
    esac
    jq --arg k "$_key" --argjson v "$_jv" '.[$k] = $v' "$OVERRIDES" > "$OVERRIDES.new"
    mv "$OVERRIDES.new" "$OVERRIDES"
}

# Add a string-array field from a comma-separated env value.
add_csv_array() {
    _env="$1"; _key="$2"
    eval "_val=\${$_env-__UNSET__}"
    [ "$_val" = "__UNSET__" ] && return 0
    [ -z "$_val" ] && return 0

    if [ "$(_lc "$_val")" = "null" ]; then
        jq --arg k "$_key" '.[$k] = null' "$OVERRIDES" > "$OVERRIDES.new"
    else
        # Build the JSON array via jq so we don't hand-escape strings.
        _arr_json="$(printf '%s' "$_val" | jq -R '
            split(",")
            | map(gsub("^\\s+|\\s+$"; ""))
            | map(select(length > 0))
        ')"
        jq --arg k "$_key" --argjson v "$_arr_json" '.[$k] = $v' "$OVERRIDES" > "$OVERRIDES.new"
    fi
    mv "$OVERRIDES.new" "$OVERRIDES"
}

# --- user-controlled fields (in the order of corplink-rs's Config struct) ---
add_str  CORPLINK_COMPANY_NAME          company_name
add_str  CORPLINK_USERNAME              username
add_str  CORPLINK_PASSWORD              password
add_str  CORPLINK_PLATFORM              platform
add_str  CORPLINK_CODE                  code
add_str  CORPLINK_SERVER                server
add_str  CORPLINK_DEVICE_NAME           device_name
add_str  CORPLINK_INTERFACE_NAME        interface_name
add_str  CORPLINK_VPN_SERVER_NAME       vpn_server_name
add_str  CORPLINK_VPN_SELECT_STRATEGY   vpn_select_strategy
add_str  CORPLINK_ROUTE_MODE            route_mode

add_bool CORPLINK_DEBUG_WG              debug_wg
add_bool CORPLINK_USE_VPN_DNS           use_vpn_dns
add_bool CORPLINK_AUTO_SETUP_ROUTES     auto_setup_routes

add_csv_array CORPLINK_VPN_DISALLOWED_ROUTES vpn_disallowed_routes

# ----------------------------------------------------------------------------
# Merge existing * overrides. `*` in jq is a deep/recursive merge where the
# right-hand side wins on conflicts — exactly what we want.  Fields that
# corplink-rs generated (device_id, public_key, private_key, state, ...) are
# not in overrides, so they survive untouched.
# ----------------------------------------------------------------------------
NEW_FILE="$(mktemp)"
jq -s '.[0] * .[1]' "$EXISTING_FILE" "$OVERRIDES" > "$NEW_FILE"

# ----------------------------------------------------------------------------
# Only rewrite if the canonicalized JSON actually changed — keeps mtime stable
# across container restarts.
# ----------------------------------------------------------------------------
if [ -e "$CONFIG_FILE" ] && \
   [ "$(jq -cS . "$NEW_FILE")" = "$(jq -cS . "$CONFIG_FILE")" ]; then
    echo "[render-config] config unchanged"
else
    # Pretty print, atomic replace.
    jq . "$NEW_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo "[render-config] wrote $CONFIG_FILE"
fi

rm -f "$NEW_FILE"

# ----------------------------------------------------------------------------
# Log what we ended up with, redacted.
# ----------------------------------------------------------------------------
jq '
      .password    = (if .password    then "***redacted***" else .password    end)
    | .private_key = (if .private_key then "***redacted***" else .private_key end)
    | .code        = (if .code        then "***redacted***" else .code        end)
' "$CONFIG_FILE" | sed 's/^/[render-config]  /'

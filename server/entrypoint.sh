#!/bin/sh
# Container entrypoint.
#
# The brief requires that `docker compose up` be the only setup step, but the
# server must not ship with a hardcoded admin key -- a fallback would mean every
# deployment that forgot to set ADMIN_KEY shared a published secret on an
# endpoint that can change a dose.
#
# Both are satisfied here: if ADMIN_KEY is supplied it is used as-is, otherwise
# a strong random key is generated, persisted so it survives a restart, and
# printed so the operator can use it.

set -eu

ADMIN_KEY_FILE="${VETIFI_ADMIN_KEY_FILE:-/srv/keys/.admin_key}"

if [ -n "${ADMIN_KEY:-}" ]; then
    echo "[entrypoint] Using ADMIN_KEY from the environment."
    export ADMIN_KEY
elif [ -f "$ADMIN_KEY_FILE" ]; then
    ADMIN_KEY="$(cat "$ADMIN_KEY_FILE")"
    export ADMIN_KEY
    echo "[entrypoint] Using the previously generated ADMIN_KEY from $ADMIN_KEY_FILE."
else
    ADMIN_KEY="$(python -c 'import secrets;print(secrets.token_urlsafe(32))')"
    export ADMIN_KEY
    mkdir -p "$(dirname "$ADMIN_KEY_FILE")"
    printf '%s' "$ADMIN_KEY" > "$ADMIN_KEY_FILE"
    chmod 600 "$ADMIN_KEY_FILE"
    echo ""
    echo "  ======================================================================"
    echo "  ADMIN_KEY was not set, so one has been generated for this deployment."
    echo "  It is stored at $ADMIN_KEY_FILE and reused on restart."
    echo ""
    echo "      $ADMIN_KEY"
    echo ""
    echo "  Keep it safe. It authorises publishing dataset versions."
    echo "  ======================================================================"
    echo ""
fi

exec "$@"
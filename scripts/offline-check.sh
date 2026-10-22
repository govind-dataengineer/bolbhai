#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BENCHMARK=${BOLBHAI_BENCHMARK_PATH:-"$ROOT/.build/release/bolbhai-benchmark"}
[ -x /usr/bin/sandbox-exec ] || { printf 'sandbox-exec is unavailable; perform the documented network-disconnected check manually.\n' >&2; exit 1; }
[ -x "$BENCHMARK" ] || { printf 'Build first with scripts/build-app.sh.\n' >&2; exit 1; }
PROFILE="$ROOT/Packaging/OfflineVerification.sb"
# A denied socket, rather than an ordinary timeout, verifies the profile is active.
/usr/bin/sandbox-exec -f "$PROFILE" /usr/bin/python3 - <<'PY'
import errno, socket
connection = socket.socket()
connection.settimeout(2)
try:
    connection.connect(("1.1.1.1", 80))
except OSError as error:
    if error.errno != errno.EPERM:
        raise SystemExit(f"Offline guard did not return EPERM: {error}")
    print("PASS external TCP denied by offline verification profile")
else:
    raise SystemExit("FAIL offline profile allowed external TCP")
finally:
    connection.close()
PY
# Only this process tree receives the profile. Network settings are unchanged.
exec /usr/bin/sandbox-exec -f "$PROFILE" "$BENCHMARK" "$@"

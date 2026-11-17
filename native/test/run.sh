#!/bin/sh
# End-to-end test of nd2cn-dashd against a stand-in for the CMU service bus.
#   sh native/test/run.sh [host|arm] [scenario] [seconds] [coolant]
# host: native/dashd-host; arm: app/nd2cn-dashd under qemu-arm (the binary
# that goes into the car). Scenarios: see mockcar.py. coolant: the raw value
# in the fake shared memory database (default 132, which is what the
# smdb-read stand-in answers; anything else makes the two disagree).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
what=${1:-host}; scenario=${2:-idle}; secs=${3:-6}; coolraw=${4:-132}
work=$(mktemp -d "${TMPDIR:-/tmp}/dashd-test.XXXXXX")
trap 'kill $dpid $mpid $bpid 2>/dev/null; rm -rf "$work"' EXIT INT TERM
sed "s|@SOCKET@|$work/bus.sock|" "$here/bus.conf.in" > "$work/bus.conf"
dbus-daemon --config-file="$work/bus.conf" --nofork --nopidfile 2> "$work/bus.log" &
bpid=$!
i=0; while [ ! -S "$work/bus.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
python3 "$here/mockcar.py" "$work/bus.sock" $((secs + 3)) "$scenario" 2> "$work/mock.log" &
mpid=$!
sleep 0.7
mkdir -p "$work/shm"
python3 "$here/mkimage.py" "$here/smdb/vdm_vdt_current_data.xml" "$work/shm/smdb_vdm_vdt_current_data" \
    --set EngClnt_Te_Actl="$coolraw" --set EngineSpeed=408 > /dev/null || echo "mkimage failed"
export DASH_SHM_DIR="$work/shm"
export DASH_BUS="$work/bus.sock" DASH_RUN_DIR="$work/run" DASH_CONF="$work/none.conf" DASH_SMDB_READ="$here/smdb-read-stub.sh"
if [ "$what" = "arm" ]; then
    qemu-arm "$root/app/nd2cn-dashd" selftest
    qemu-arm "$root/app/nd2cn-dashd" run -v 2> "$work/dashd.log" &
else
    "$root/native/dashd-host" selftest
    "$root/native/dashd-host" run -v 2> "$work/dashd.log" &
fi
dpid=$!
sleep 1.2
echo "--- before the page opens (heartbeat):"; cat "$work/run/dashboard.json"
python3 "$here/reader.py" "$work/run/dashboard.json" "$secs"
echo "--- daemon log:"; cat "$work/dashd.log"
kill $dpid; wait $dpid 2>/dev/null
# shellcheck disable=SC2012
echo "--- after stop: $(ls -A "$work/run" | tr '\n' ' ')"
[ -s "$work/mock.log" ] && { echo "--- mock errors:"; head -5 "$work/mock.log"; }
exit 0

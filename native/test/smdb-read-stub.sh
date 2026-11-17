#!/bin/sh
# Stand-in for /jci/smdb/smdb-read: same output shape ("NAME (int, 4): VALUE"),
# and slow like the real one.
while [ $# -gt 0 ]; do
    case "$1" in -e) key=$2; shift ;; esac
    shift
done
sleep 0.3
case "$key" in
    EngClnt_Te_Actl)    v=132 ;;
    EngineSpeed)        v=408 ;;
    AccelPedalPosition) v=0 ;;
    SteeringWheel)      v=32766 ;;
    *) echo "Entry '$key' not found."; exit 1 ;;
esac
echo "$key (int, 4): $v"

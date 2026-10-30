#!/bin/sh
# dual-rM: long-poll from the xochitl patch (socket-activated, 127.0.0.1:7782).
# Answers with the waiting command, or holds the request until one is posted (ring on $D/bell).
# A request left over from a killed xochitl is ended by RuntimeMaxSec.
. /home/root/dualrm/dualrm-lib.sh
IFS= read -r req
drain_headers
mkfifos
[ -s "$D/cmd" ] || read -r _ < "$D/bell"
http_reply "$(cat "$D/cmd" 2>/dev/null)"

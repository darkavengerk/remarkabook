#!/bin/sh
# dual-rM: one event or command answer from the xochitl patch (socket-activated, 127.0.0.1:7781).
#   GET /ev?DOC%20<uuid>|-          a document was opened / closed here
#   GET /ev?PAGE%20<uuid> <pc> <cp> page count / current page changed
#   GET /ev?PEN%20<json>            tool settings changed
#   GET /ev?SCROLL%20<uuid> <pg> <y> notebook page scrolled (scene y at the top of the view)
#   GET /ev?SLEEP / WAKE            this tablet goes to sleep / woke up
#   GET /ev?RESP%20<nonce> <text>   answer to the command in $D/cmd
. /home/root/dualrm/dualrm-lib.sh
IFS= read -r req
drain_headers
q=${req#GET /ev?}; q=${q%% HTTP/*}
msg=$(urldecode "$q")
out=""
case "$msg" in
    RESP\ *)
        r=${msg#RESP }
        c=$(cat "$D/cmd" 2>/dev/null)
        [ "${c%% *}" = "${r%% *}" ] && : > "$D/cmd"
        printf '%s\n' "$r" > "$D/response.tmp" && mv "$D/response.tmp" "$D/response"
        out="EV $msg" ;;
    "DOC -")
        out="EV DOC -" ;;
    DOC\ *)
        u=${msg#DOC }
        out="EV DOC $u $(doc_type "$u") $(doc_path "$u")" ;;
    PAGE\ *|PEN\ *|SCROLL\ *|SLEEP|WAKE)
        out="EV $msg" ;;
esac
# hand on before answering, so events stay in order (the patch sends them one at a time)
[ -n "$out" ] && reader_alive && printf '%s\n' "$out" > "$D/events"
http_reply ok

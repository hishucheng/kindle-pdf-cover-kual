#!/bin/sh

. /mnt/us/extensions/pdf-cover/bin/common.sh

if [ -s "$STATUS" ]; then
    display_result "$(tail -1 "$STATUS")"
else
    display_result "尚无运行记录"
fi

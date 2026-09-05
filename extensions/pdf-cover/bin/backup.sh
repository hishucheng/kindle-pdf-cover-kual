#!/bin/sh

. /mnt/us/extensions/pdf-cover/bin/common.sh

if ! check_requirements; then
    set_status "$CHECK_ERROR"
    exit 1
fi
if make_backup; then
    set_status "cc.db 已备份：$(basename "$BACKUP_PATH")"
    exit 0
fi

set_status "cc.db 备份失败，未做任何修改"
exit 1

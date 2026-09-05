#!/bin/sh

. /mnt/us/extensions/pdf-cover/bin/common.sh

if check_requirements; then
    detect_thumbnail_size
    set_status "兼容性检查通过（${RT_SOURCE}），封面尺寸 ${THUMB_W}x${THUMB_H}"
    exit 0
fi

set_status "$CHECK_ERROR"
exit 1

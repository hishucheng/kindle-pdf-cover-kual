#!/bin/sh

. /mnt/us/extensions/pdf-cover/bin/common.sh

if ! mkdir "$LOCK" 2>/dev/null; then
    set_status "已有扫描任务正在运行"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

if ! check_requirements; then
    set_status "$CHECK_ERROR"
    exit 1
fi
if ! make_backup; then
    set_status "备份失败，扫描已安全取消"
    exit 1
fi

detect_thumbnail_size
query=/tmp/pdf-cover-helper.$$.rows
sqlite3 -separator '|' "$DB" ".timeout 5000" \
    "SELECT p_uuid,p_location,coalesce(p_thumbnail,'') FROM entries WHERE lower(p_mimeType)='application/pdf' AND p_location IS NOT NULL AND p_location<>'' AND coalesce(p_isDownloading,0)=0;" > "$query" 2>>"$LOG"
if [ $? -ne 0 ]; then
    rm -f "$query"
    set_status "读取 cc.db 失败，未做任何修改"
    exit 1
fi

found=0
created=0
skipped=0
failed=0
mkdir -p "$THUMBS"

while IFS='|' read -r uuid pdf current; do
    [ -n "$uuid" ] || continue
    [ -f "$pdf" ] || continue
    found=$((found + 1))
    if [ -n "$current" ] && [ -s "$current" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    case "$uuid" in *[!A-Za-z0-9_-]*) failed=$((failed + 1)); continue ;; esac
    size_before=$(stat -c %s "$pdf" 2>/dev/null || echo 0)
    [ "$size_before" -gt 1024 ] 2>/dev/null || { failed=$((failed + 1)); continue; }
    sleep 2
    size_after=$(stat -c %s "$pdf" 2>/dev/null || echo 0)
    [ "$size_before" = "$size_after" ] || { skipped=$((skipped + 1)); continue; }

    thumb="$THUMBS/thumbnail_pdfcover_${uuid}.jpg"
    bmp="/tmp/pdf-cover-${uuid}.pgm"
    jpg="${thumb}.tmp"
    rm -f "$bmp" "$jpg"

    if ! "$BASE/bin/render.sh" "$pdf" "$bmp" "$THUMB_W" "$THUMB_H" >>"$LOG" 2>&1 ||
       ! /usr/bin/cjpeg -quality 88 -grayscale -optimize -outfile "$jpg" "$bmp" >>"$LOG" 2>&1; then
        rm -f "$bmp" "$jpg"
        failed=$((failed + 1))
        log "render failed: $pdf"
        continue
    fi
    rm -f "$bmp"
    chmod 664 "$jpg" 2>/dev/null || true
    mv "$jpg" "$thumb"

    if sqlite3 "$DB" ".timeout 5000" "BEGIN IMMEDIATE; UPDATE entries SET p_thumbnail='$thumb' WHERE p_uuid='$uuid'; COMMIT;" >>"$LOG" 2>&1; then
        created=$((created + 1))
        log "cover installed: $pdf -> $thumb"
    else
        rm -f "$thumb"
        failed=$((failed + 1))
        log "database update failed: $pdf"
    fi
done < "$query"
rm -f "$query"

set_status "扫描完成：PDF $found，本次新增 $created，已有 $skipped，失败 $failed"
[ "$failed" -eq 0 ]

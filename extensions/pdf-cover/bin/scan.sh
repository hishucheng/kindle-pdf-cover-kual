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
    "SELECT p_uuid,p_location,coalesce(p_thumbnail,''),coalesce(p_mimeType,'') FROM entries WHERE p_location IS NOT NULL AND p_location<>'' AND lower(p_location) LIKE '%.pdf' AND coalesce(p_isDownloading,0)=0;" > "$query" 2>>"$LOG"
if [ $? -ne 0 ]; then
    rm -f "$query"
    set_status "读取 cc.db 失败，未做任何修改"
    exit 1
fi

found=0
created=0
skipped=0
failed=0
adjusted=0
mkdir -p "$THUMBS"

while IFS='|' read -r uuid pdf current mime; do
    [ -n "$uuid" ] || continue
    [ -f "$pdf" ] || continue
    found=$((found + 1))
    # 已有有效缩略图时的处理：
    #   - 非 K7：直接跳过（保持旧行为，兼容逻辑仅用于 K7 旧 Home）。
    #   - K7 且 MIME 已是兼容值：已达标，跳过。
    #   - K7 但 MIME 仍是 application/pdf：旧 CoverRenderer 会无条件丢弃
    #     p_thumbnail，只改 MIME 不够，需整行重渲染 RGB 并伪装 MIME。
    skip_row=0
    if [ -n "$current" ] && [ -s "$current" ]; then
        if [ "$LEGACY_PDF_COVER" -eq 1 ]; then
            if [ "$mime" = "$LEGACY_PDF_MIME" ]; then
                skip_row=1
            else
                log "legacy re-render needed (mime=$mime): $pdf"
            fi
        else
            skip_row=1
        fi
    fi
    if [ "$skip_row" -eq 1 ]; then
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
    if [ "$LEGACY_PDF_COVER" -eq 1 ]; then
        bmp="/tmp/pdf-cover-${uuid}.ppm"
        render_mode=rgb
        cjpeg_mode=""
    else
        bmp="/tmp/pdf-cover-${uuid}.pgm"
        render_mode=gray
        cjpeg_mode=-grayscale
    fi
    jpg="${thumb}.tmp"
    rm -f "$bmp" "$jpg"

    if ! "$BASE/bin/render.sh" "$pdf" "$bmp" "$THUMB_W" "$THUMB_H" "$render_mode" >>"$LOG" 2>&1 ||
       ! /usr/bin/cjpeg -quality 88 $cjpeg_mode -optimize -outfile "$jpg" "$bmp" >>"$LOG" 2>&1; then
        rm -f "$bmp" "$jpg"
        failed=$((failed + 1))
        log "render failed: $pdf"
        continue
    fi
    rm -f "$bmp"
    chmod 664 "$jpg" 2>/dev/null || true
    mv "$jpg" "$thumb"

    target_mime=application/pdf
    if [ "$LEGACY_PDF_COVER" -eq 1 ]; then target_mime=$LEGACY_PDF_MIME; fi
    if sqlite3 "$DB" ".timeout 5000" "BEGIN IMMEDIATE; UPDATE entries SET p_thumbnail='$thumb', p_mimeType='$target_mime' WHERE p_uuid='$uuid'; COMMIT;" >>"$LOG" 2>&1; then
        created=$((created + 1))
        log "cover installed: $pdf -> $thumb"
    else
        rm -f "$thumb"
        failed=$((failed + 1))
        log "database update failed: $pdf"
    fi
done < "$query"
rm -f "$query"

if [ "$LEGACY_PDF_COVER" -eq 1 ]; then
    lipc-set-prop com.lab126.coverArtService refreshCoverArt 1 >/dev/null 2>&1 || true
    if [ "$created" -gt 0 ] || [ "$adjusted" -gt 0 ]; then
        set_status "K7 COVERS: PDF $found NEW $created FIX $adjusted FAIL $failed - HOME RELOAD"
        reload_legacy_home
    else
        set_status "K7 COVERS: PDF $found NEW 0 FIX 0 FAIL $failed"
    fi
else
    set_status "扫描完成：PDF $found，本次新增 $created，已有 $skipped，失败 $failed"
fi
[ "$failed" -eq 0 ]

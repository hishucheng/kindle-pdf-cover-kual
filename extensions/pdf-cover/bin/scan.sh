#!/bin/sh

. /mnt/us/extensions/pdf-cover/bin/common.sh

FORCE_REBUILD=0
if [ "${1:-}" = "--force" ]; then
    FORCE_REBUILD=1
fi

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
rebuilt=0
mkdir -p "$THUMBS"

while IFS='|' read -r uuid pdf current mime; do
    [ -n "$uuid" ] || continue
    [ -f "$pdf" ] || continue
    found=$((found + 1))

    # 已有有效缩略图时的处理：
    #   - 普通扫描：非 K7 直接跳过；K7 仅在 MIME 仍不兼容时重渲染并修正。
    #   - --force：不跳过已有封面，全部重新从 PDF 第一页生成。
    skip_row=0
    had_current=0
    repair_row=0
    if [ -n "$current" ] && [ -s "$current" ]; then
        had_current=1
        if [ "$LEGACY_PDF_COVER" -eq 1 ] && [ "$mime" != "$LEGACY_PDF_MIME" ]; then
            repair_row=1
            log "legacy re-render needed (mime=$mime): $pdf"
        elif [ "$FORCE_REBUILD" -eq 0 ]; then
            skip_row=1
        else
            log "forced rebuild: $pdf"
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
    old_thumb_backup=""
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

    # 强制重建/兼容修复时，现有封面可能正好就是目标路径。
    # 先留一份临时副本；若后续写库失败，恢复旧图，避免留下失效的 p_thumbnail。
    if [ "$had_current" -eq 1 ] && [ "$current" = "$thumb" ] && [ -s "$thumb" ]; then
        old_thumb_backup="${thumb}.bak.$$"
        if ! cp "$thumb" "$old_thumb_backup" 2>>"$LOG"; then
            rm -f "$jpg"
            failed=$((failed + 1))
            log "thumbnail backup failed: $thumb"
            continue
        fi
    fi
    if ! mv "$jpg" "$thumb" 2>>"$LOG"; then
        rm -f "$jpg" "$old_thumb_backup"
        failed=$((failed + 1))
        log "thumbnail install failed: $thumb"
        continue
    fi

    target_mime=application/pdf
    if [ "$LEGACY_PDF_COVER" -eq 1 ]; then target_mime=$LEGACY_PDF_MIME; fi
    if sqlite3 "$DB" ".timeout 5000" "BEGIN IMMEDIATE; UPDATE entries SET p_thumbnail='$thumb', p_mimeType='$target_mime' WHERE p_uuid='$uuid'; COMMIT;" >>"$LOG" 2>&1; then
        rm -f "$old_thumb_backup"
        if [ "$repair_row" -eq 1 ]; then
            adjusted=$((adjusted + 1))
            log "cover repaired: $pdf -> $thumb"
        elif [ "$FORCE_REBUILD" -eq 1 ] && [ "$had_current" -eq 1 ]; then
            rebuilt=$((rebuilt + 1))
            log "cover rebuilt: $pdf -> $thumb"
        else
            created=$((created + 1))
            log "cover installed: $pdf -> $thumb"
        fi
    else
        if [ -n "$old_thumb_backup" ] && [ -s "$old_thumb_backup" ]; then
            mv "$old_thumb_backup" "$thumb" 2>/dev/null || true
        else
            rm -f "$thumb"
        fi
        failed=$((failed + 1))
        log "database update failed: $pdf"
    fi
done < "$query"
rm -f "$query"

changes=$((created + adjusted + rebuilt))
if [ "$LEGACY_PDF_COVER" -eq 1 ]; then
    lipc-set-prop com.lab126.coverArtService refreshCoverArt 1 >/dev/null 2>&1 || true
    if [ "$FORCE_REBUILD" -eq 1 ]; then
        if [ "$changes" -gt 0 ]; then
            set_status "K7 REBUILD: PDF $found NEW $created FIX $adjusted REDO $rebuilt FAIL $failed - HOME RELOAD"
            reload_legacy_home
        else
            set_status "K7 REBUILD: PDF $found NEW 0 FIX 0 REDO 0 FAIL $failed"
        fi
    elif [ "$changes" -gt 0 ]; then
        set_status "K7 COVERS: PDF $found NEW $created FIX $adjusted FAIL $failed - HOME RELOAD"
        reload_legacy_home
    else
        set_status "K7 COVERS: PDF $found NEW 0 FIX 0 FAIL $failed"
    fi
elif [ "$FORCE_REBUILD" -eq 1 ]; then
    set_status "重建完成：PDF $found，新建 $created，重建 $rebuilt，失败 $failed"
else
    set_status "扫描完成：PDF $found，本次新增 $created，已有 $skipped，失败 $failed"
fi
[ "$failed" -eq 0 ]

#!/bin/sh

. /mnt/us/extensions/pdf-cover/bin/common.sh

if ! mkdir "$LOCK" 2>/dev/null; then
    set_status "已有任务正在运行"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

[ -s "$DB" ] && [ -x /usr/bin/sqlite3 ] || {
    set_status "缺少 cc.db 或 sqlite3，恢复已取消"
    exit 1
}

if ! make_backup; then
    set_status "备份失败，恢复已安全取消"
    exit 1
fi

count=$(sqlite3 "$DB" "SELECT count(*) FROM entries WHERE p_location IS NOT NULL AND lower(p_location) LIKE '%.pdf' AND p_mimeType='$LEGACY_PDF_MIME';" 2>/dev/null)
case "$count" in *[!0-9]*|'') count=0 ;; esac

if sqlite3 "$DB" ".timeout 5000" "BEGIN IMMEDIATE; UPDATE entries SET p_mimeType='application/pdf' WHERE p_location IS NOT NULL AND lower(p_location) LIKE '%.pdf' AND p_mimeType='$LEGACY_PDF_MIME'; COMMIT;" >>"$LOG" 2>&1; then
    lipc-set-prop com.lab126.coverArtService refreshCoverArt 1 >/dev/null 2>&1 || true
    detect_cover_compat_mode
    if [ "$LEGACY_PDF_COVER" -eq 1 ]; then
        set_status "K7 PDF MIME RESTORED: $count - HOME RELOAD"
        [ "$count" -gt 0 ] && reload_legacy_home
    else
        set_status "PDF 类型标记已恢复：$count 本；请重启 Kindle"
    fi
    exit 0
fi

set_status "恢复失败，数据库未完整更新"
exit 1

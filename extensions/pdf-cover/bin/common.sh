#!/bin/sh

BASE=/mnt/us/extensions/pdf-cover
DB=/var/local/cc.db
THUMBS=/mnt/us/system/thumbnails
DATA="$BASE/data"
BACKUPS="$DATA/backups"
LOG="$DATA/pdf-cover.log"
STATUS="$DATA/last-status.txt"
LOCK=/tmp/pdf-cover-helper.lock

mkdir -p "$DATA" "$BACKUPS" 2>/dev/null || true

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

notify() {
    message=$1
    # Some firmwares do not expose com.lab126.system/toaster. Keep it as a
    # best-effort first choice; display_result() below is the visible fallback.
    lipc-set-prop com.lab126.system toaster "$message" >/dev/null 2>&1
}

display_result() {
    message=$1
    notify "$message" && return 0
    # KUAL exits before result commands. eips is available across the target
    # Kindle generations and remains readable until the framework refreshes.
    if command -v eips >/dev/null 2>&1; then
        eips 1 2 "$message" >/dev/null 2>&1 || true
        eips '' >/dev/null 2>&1 || true
    fi
}

set_status() {
    printf '%s\n' "$1" > "$STATUS"
    log "$1"
    display_result "$1"
}

# 选择可用的渲染运行时。优先内置独立运行时(armv7 老机型,不依赖 KOReader);
# 若内置运行时在当前固件上无法执行(如 kindlehf/armhf 等新代际缺少旧解释器),
# 自动借用已安装的 KOReader 运行时(/mnt/us/koreader)。
resolve_runtime() {
    RT_DIR=""
    RT_HEADER=""
    RT_SOURCE=""
    # 依次尝试包内自带运行时(armv7/kindlehf/…)。能跑起来的即为可用。
    for cand in "$BASE"/runtime/*/; do
        [ -d "$cand" ] || continue
        if [ -x "$cand/luajit" ] && [ -s "$cand/libs/libwrap-mupdf.so" ] \
            && [ -s "$cand/lua/mupdf_h.lua" ] \
            && "$cand/luajit" -v >/dev/null 2>&1; then
            RT_DIR="${cand%/}"
            RT_HEADER="$RT_DIR/lua/mupdf_h.lua"
            RT_SOURCE="内置独立运行时($(basename "${cand%/}"))"
            return 0
        fi
    done
    # 兜底:借用已安装的 KOReader 运行时(仅当设备装有 KOReader/觅阅时)。
    if [ -x /mnt/us/koreader/luajit ] && [ -s /mnt/us/koreader/libs/libwrap-mupdf.so ] \
        && [ -s /mnt/us/koreader/ffi/mupdf_h.lua ] \
        && /mnt/us/koreader/luajit -v >/dev/null 2>&1; then
        RT_DIR="/mnt/us/koreader"
        RT_HEADER="$RT_DIR/ffi/mupdf_h.lua"
        RT_SOURCE="KOReader 运行时(/mnt/us/koreader)"
        return 0
    fi
    return 1
}

check_requirements() {
    missing=""
    if ! resolve_runtime; then
        CHECK_ERROR="缺少可用渲染运行时:内置 armv7 运行时无法执行,且未找到可用的 KOReader 运行时(/mnt/us/koreader)"
        return 1
    fi
    [ -s "$DB" ] || missing="$missing cc.db"
    [ -x /usr/bin/sqlite3 ] || missing="$missing sqlite3"
    [ -x /usr/bin/cjpeg ] || missing="$missing cjpeg"
    [ -x /usr/bin/djpeg ] || missing="$missing djpeg"
    [ -s "$RT_HEADER" ] || missing="$missing 渲染头文件($RT_HEADER)"
    [ -s "$RT_DIR/libs/libwrap-mupdf.so" ] || missing="$missing MuPDF($RT_DIR/libs)"
    if [ -n "$missing" ]; then
        CHECK_ERROR="缺少:$missing"
        return 1
    fi

    columns=$(sqlite3 "$DB" "pragma table_info(entries);" 2>/dev/null | cut -d '|' -f 2)
    for required in p_uuid p_location p_mimeType p_thumbnail p_isDownloading; do
        printf '%s\n' "$columns" | grep -qx "$required" || missing="$missing $required"
    done
    if [ -n "$missing" ]; then
        CHECK_ERROR="cc.db 字段不兼容:$missing"
        return 1
    fi
    return 0
}

make_backup() {
    stamp=$(date '+%Y%m%d-%H%M%S')
    target="$BACKUPS/cc.db.$stamp"
    if sqlite3 "$DB" ".timeout 5000" ".backup '$target.tmp'" >/dev/null 2>&1; then
        mv "$target.tmp" "$target"
        chmod 664 "$target" 2>/dev/null || true
        BACKUP_PATH=$target
        return 0
    fi
    rm -f "$target.tmp"
    return 1
}

detect_thumbnail_size() {
    THUMB_W=221
    THUMB_H=315
    candidate=$(sqlite3 "$DB" "select p_thumbnail from entries where p_thumbnail is not null and p_thumbnail<>'' limit 50;" 2>/dev/null |
        while IFS= read -r path; do [ -s "$path" ] && { printf '%s\n' "$path"; break; }; done)
    [ -n "$candidate" ] || return 0
    dimensions=$(/usr/bin/djpeg -verbose -outfile /dev/null "$candidate" 2>&1 |
        sed -n 's/.* \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' | head -1)
    width=${dimensions%% *}
    height=${dimensions##* }
    case "$width:$height" in
        *[!0-9:]*|:|*:0|0:*) return 0 ;;
    esac
    if [ "$width" -ge 100 ] 2>/dev/null && [ "$width" -le 800 ] 2>/dev/null &&
       [ "$height" -ge 100 ] 2>/dev/null && [ "$height" -le 1000 ] 2>/dev/null; then
        THUMB_W=$width
        THUMB_H=$height
    fi
}

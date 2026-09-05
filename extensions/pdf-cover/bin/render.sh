#!/bin/sh

BASE=/mnt/us/extensions/pdf-cover
. "$BASE/bin/common.sh"

if ! resolve_runtime; then
    echo "no usable PDF render runtime found" >&2
    exit 1
fi

export PDF_COVER_RUNTIME="$RT_DIR"
export PDF_COVER_MUPDF_H="$RT_HEADER"
export LD_LIBRARY_PATH="$RT_DIR/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$RT_DIR" || exit 1
exec ./luajit "$BASE/bin/render_pdf_cover.lua" "$@"

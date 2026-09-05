#!/usr/bin/env luajit

-- Minimal first-page renderer. It talks directly to KOReader's MuPDF wrapper,
-- but uses only the plugin-owned runtime; KOReader itself is not required.
local ffi = require("ffi")

local input = assert(arg[1], "missing PDF input")
local output = assert(arg[2], "missing PGM output")
local target_w = tonumber(arg[3]) or 221
local target_h = tonumber(arg[4]) or 315
local runtime = assert(os.getenv("PDF_COVER_RUNTIME"), "missing runtime path")

dofile(os.getenv("PDF_COVER_MUPDF_H") or (runtime .. "/lua/mupdf_h.lua"))
ffi.cdef[[void *malloc(size_t); void free(void *);]]

local W = ffi.load(runtime .. "/libs/libwrap-mupdf.so")
local C = ffi.C
local VERSION = "1.27.2"
local ctx, doc, page, pix, dev, samples

local function fail(message)
    local detail = ctx ~= nil and ffi.string(W.mupdf_error_message(ctx)) or ""
    error(message .. (detail ~= "" and (": " .. detail) or ""))
end

local function cleanup()
    if dev ~= nil then W.fz_drop_device(ctx, dev); dev = nil end
    if pix ~= nil then W.fz_drop_pixmap(ctx, pix); pix = nil end
    if page ~= nil then W.fz_drop_page(ctx, page); page = nil end
    if doc ~= nil then W.fz_drop_document(ctx, doc); doc = nil end
    if ctx ~= nil then W.fz_drop_context(ctx); ctx = nil end
end

local ok, err = xpcall(function()
    ctx = W.fz_new_context_imp(nil, nil, 32 * 1024 * 1024, VERSION)
    if ctx == nil then fail("cannot create MuPDF context") end
    W.fz_install_external_font_funcs(ctx)
    W.fz_register_document_handlers(ctx)

    doc = W.mupdf_open_document(ctx, input)
    if doc == nil then fail("cannot open PDF") end
    if W.mupdf_count_pages(ctx, doc) < 1 then fail("PDF has no pages") end
    page = W.mupdf_load_page(ctx, doc, 0)
    if page == nil then fail("cannot load first page") end

    local bounds = ffi.new("fz_rect")
    W.mupdf_fz_bound_page(ctx, page, bounds)
    local source_w = bounds.x1 - bounds.x0
    local source_h = bounds.y1 - bounds.y0
    if source_w <= 0 or source_h <= 0 then fail("invalid first-page size") end

    local scale = math.min(target_w / source_w, target_h / source_h)
    local draw_w = source_w * scale
    local draw_h = source_h * scale
    local matrix = ffi.new("fz_matrix")
    matrix.a, matrix.b, matrix.c, matrix.d = scale, 0, 0, scale
    matrix.e = (target_w - draw_w) / 2 - bounds.x0 * scale
    matrix.f = (target_h - draw_h) / 2 - bounds.y0 * scale

    samples = ffi.new("unsigned char[?]", target_w * target_h)
    ffi.fill(samples, target_w * target_h, 255)
    pix = W.mupdf_new_pixmap_with_data(
        ctx, W.fz_device_gray(ctx), target_w, target_h, nil, 0,
        target_w, samples)
    if pix == nil then fail("cannot allocate cover bitmap") end
    W.fz_clear_pixmap_with_value(ctx, pix, 255)

    dev = W.mupdf_new_draw_device(ctx, nil, pix)
    if dev == nil then fail("cannot create draw device") end
    if not W.mupdf_run_page(ctx, page, dev, matrix, nil) then fail("cannot render first page") end
    if not W.mupdf_close_device(ctx, dev) then fail("cannot finish rendering") end
    W.fz_drop_device(ctx, dev); dev = nil

    local file = assert(io.open(output, "wb"))
    file:write(string.format("P5\n%d %d\n255\n", target_w, target_h))
    file:write(ffi.string(samples, target_w * target_h))
    file:close()
end, debug.traceback)

cleanup()
if not ok then
    os.remove(output)
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end

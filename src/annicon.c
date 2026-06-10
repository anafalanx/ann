/*
 * annicon.c -- the HICON -> RGBA -> Tk photo pipeline + C-side LRU cache
 * (DESIGN §9.7). All extraction happens here in C; Tcl only names a photo image
 * and a spec, so the UI never touches HICONs or pixel formats.
 *
 *   annicon::fill <photoName> <spec> <size>   -> "hit" | "miss" (extracted now)
 *   annicon::stats                            -> dict {hits misses evictions entries}
 *
 * spec forms:
 *   <path>          file/.lnk/.exe path -> IShellItemImageFactory::GetImage,
 *                   falling back to SHGetFileInfo(SHGFI_ICON)
 *   aumid:<AUMID>   packaged app -> IShellItemImageFactory on shell:AppsFolder\<AUMID>
 *   hwnd:<n>        a live window's own icon (WM_GETICON / class icon, copied)
 *   stock:<name>    a Windows stock icon: app | folder | doc | shield | pc
 *
 * Pixel-format rules (the §9.7 traps, confirmed against the vendored manual page
 * c-api/Tk_FindPhoto.md):
 *   - GetDIBits with a top-down 32bpp BI_RGB header (negative biHeight) -> BGRA;
 *     swap B<->R for RGBA.
 *   - icons with no alpha channel get alpha synthesized from the AND mask, or
 *     they would render fully transparent.
 *   - IShellItemImageFactory returns PREMULTIPLIED alpha -> un-premultiply.
 *   - Tk_PhotoPutBlock with pixelSize=4, offset={0,1,2,3} (alpha offset MUST be
 *     < pixelSize or Tk forces the image opaque), TK_PHOTO_COMPOSITE_SET.
 *
 * Memory discipline (§9.7): raw RGBA blobs live in a C LRU keyed by spec|size
 * (ANN_ICON_CACHE_MAX entries, ~4 KB each at 32px); Tk photo images exist only
 * for the visible row slots, refilled from this cache.
 *
 * Compiled INTO ann.exe (ANN_STATIC_ICON) and as a dev stubs .dll (needs BOTH
 * tclstub and tkstub: USE_TCL_STUBS + USE_TK_STUBS).
 */

#include <tcl.h>
#include <tk.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#undef WIN32_LEAN_AND_MEAN
#include <stdio.h>
#include <string.h>

/* IShellItemImageFactory -- define the IID locally (mingw's libuuid may not
 * export it); {bcc18b79-ba16-442f-80c4-8a59c30c463b} */
static const GUID ANN_IID_IShellItemImageFactory =
    { 0xbcc18b79, 0xba16, 0x442f, { 0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b } };

/* ---- LRU cache ------------------------------------------------------------ */
#define ANN_ICON_CACHE_MAX 512

typedef struct {
    char *key;                  /* Tcl_Alloc'd "spec|size", NULL = free slot */
    unsigned char *rgba;        /* Tcl_Alloc'd w*h*4 */
    int w, h;
    unsigned long lastUse;
} IconEnt;

static IconEnt gCache[ANN_ICON_CACHE_MAX];
static unsigned long gTick = 0;
static long gHits = 0, gMisses = 0, gEvict = 0;

static IconEnt *cache_find(const char *key) {
    for (int i = 0; i < ANN_ICON_CACHE_MAX; i++) {
        if (gCache[i].key && strcmp(gCache[i].key, key) == 0) {
            gCache[i].lastUse = ++gTick;
            return &gCache[i];
        }
    }
    return NULL;
}

static IconEnt *cache_put(const char *key, unsigned char *rgba, int w, int h) {
    int slot = -1; unsigned long oldest = (unsigned long) -1;
    for (int i = 0; i < ANN_ICON_CACHE_MAX; i++) {
        if (!gCache[i].key) { slot = i; break; }
        if (gCache[i].lastUse < oldest) { oldest = gCache[i].lastUse; slot = i; }
    }
    IconEnt *e = &gCache[slot];
    if (e->key) {               /* evict */
        Tcl_Free(e->key); Tcl_Free((char *) e->rgba); gEvict++;
    }
    e->key = (char *) Tcl_Alloc(strlen(key) + 1);
    strcpy(e->key, key);
    e->rgba = rgba; e->w = w; e->h = h; e->lastUse = ++gTick;
    return e;
}

/* ---- HBITMAP/HICON -> RGBA ------------------------------------------------- */

/* 32bpp top-down BGRA pull from an HBITMAP; returns Tcl_Alloc'd buffer or NULL. */
static unsigned char *bitmap_to_bgra(HBITMAP bmp, int *pw, int *ph) {
    BITMAP bm;
    if (!GetObjectW(bmp, sizeof bm, &bm) || bm.bmWidth <= 0 || bm.bmHeight <= 0) return NULL;
    int w = bm.bmWidth, h = bm.bmHeight;
    if (w > 512 || h > 512) return NULL;                  /* sanity bound */
    BITMAPINFO bi; memset(&bi, 0, sizeof bi);
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;                            /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    unsigned char *px = (unsigned char *) Tcl_Alloc((size_t) w * h * 4);
    HDC dc = GetDC(NULL);
    int got = GetDIBits(dc, bmp, 0, (UINT) h, px, &bi, DIB_RGB_COLORS);
    ReleaseDC(NULL, dc);
    if (got != h) { Tcl_Free((char *) px); return NULL; }
    *pw = w; *ph = h;
    return px;
}

/* BGRA -> RGBA in place */
static void swap_br(unsigned char *px, int n) {
    for (int i = 0; i < n; i++) {
        unsigned char b = px[i * 4 + 0];
        px[i * 4 + 0] = px[i * 4 + 2];
        px[i * 4 + 2] = b;
    }
}

/* HICON -> RGBA (Tcl_Alloc'd). Synthesizes alpha from the AND mask when the
 * color bitmap carries none. Never destroys the icon (caller owns it). */
static unsigned char *icon_to_rgba(HICON icon, int *pw, int *ph) {
    ICONINFO ii;
    if (!GetIconInfo(icon, &ii)) return NULL;
    unsigned char *px = NULL;
    int w = 0, h = 0;
    if (ii.hbmColor) {
        px = bitmap_to_bgra(ii.hbmColor, &w, &h);
        if (px) {
            int n = w * h, hasAlpha = 0;
            for (int i = 0; i < n; i++) if (px[i * 4 + 3] != 0) { hasAlpha = 1; break; }
            if (!hasAlpha && ii.hbmMask) {
                /* derive alpha from the 1bpp AND mask: mask bit 0 = opaque */
                int stride = ((w + 31) / 32) * 4;
                unsigned char *mask = (unsigned char *) Tcl_Alloc((size_t) stride * h);
                struct { BITMAPINFOHEADER hdr; RGBQUAD pal[2]; } mbi;
                memset(&mbi, 0, sizeof mbi);
                mbi.hdr.biSize = sizeof(BITMAPINFOHEADER);
                mbi.hdr.biWidth = w; mbi.hdr.biHeight = -h;
                mbi.hdr.biPlanes = 1; mbi.hdr.biBitCount = 1; mbi.hdr.biCompression = BI_RGB;
                HDC dc = GetDC(NULL);
                int got = GetDIBits(dc, ii.hbmMask, 0, (UINT) h, mask, (BITMAPINFO *) &mbi, DIB_RGB_COLORS);
                ReleaseDC(NULL, dc);
                if (got == h) {
                    for (int y = 0; y < h; y++)
                        for (int x = 0; x < w; x++) {
                            int bit = (mask[y * stride + (x >> 3)] >> (7 - (x & 7))) & 1;
                            px[(y * w + x) * 4 + 3] = bit ? 0 : 255;
                        }
                } else {
                    for (int i = 0; i < n; i++) px[i * 4 + 3] = 255;   /* opaque fallback */
                }
                Tcl_Free((char *) mask);
            }
            swap_br(px, n);
        }
    }
    if (ii.hbmColor) DeleteObject(ii.hbmColor);
    if (ii.hbmMask)  DeleteObject(ii.hbmMask);
    if (!px) return NULL;
    *pw = w; *ph = h;
    return px;
}

/* IShellItemImageFactory path: parse name -> GetImage (premultiplied BGRA HBITMAP)
 * -> un-premultiply -> RGBA. parseName is UTF-16. */
static unsigned char *shellitem_to_rgba(const wchar_t *parseName, int size, int *pw, int *ph) {
    IShellItemImageFactory *fac = NULL;
    if (SHCreateItemFromParsingName(parseName, NULL, &ANN_IID_IShellItemImageFactory,
                                    (void **) &fac) != S_OK || !fac) return NULL;
    SIZE sz = { size, size };
    HBITMAP bmp = NULL;
    HRESULT hr = fac->lpVtbl->GetImage(fac, sz, SIIGBF_RESIZETOFIT | SIIGBF_BIGGERSIZEOK, &bmp);
    fac->lpVtbl->Release(fac);
    if (FAILED(hr) || !bmp) return NULL;
    int w = 0, h = 0;
    unsigned char *px = bitmap_to_bgra(bmp, &w, &h);
    DeleteObject(bmp);
    if (!px) return NULL;
    /* un-premultiply (GetImage returns PARGB), then B<->R */
    int n = w * h;
    for (int i = 0; i < n; i++) {
        unsigned a = px[i * 4 + 3];
        if (a > 0 && a < 255) {
            for (int c = 0; c < 3; c++) {
                unsigned v = (unsigned) px[i * 4 + c] * 255u / a;
                px[i * 4 + c] = (unsigned char) (v > 255 ? 255 : v);
            }
        }
    }
    swap_br(px, n);
    *pw = w; *ph = h;
    return px;
}

static unsigned char *stock_to_rgba(const char *name, int size, int *pw, int *ph) {
    SHSTOCKICONID id = SIID_APPLICATION;
    if      (strcmp(name, "folder") == 0) id = SIID_FOLDER;
    else if (strcmp(name, "doc") == 0)    id = SIID_DOCNOASSOC;
    else if (strcmp(name, "shield") == 0) id = SIID_SHIELD;
    else if (strcmp(name, "pc") == 0)     id = SIID_DESKTOPPC;
    SHSTOCKICONINFO sii; memset(&sii, 0, sizeof sii);
    sii.cbSize = sizeof sii;
    UINT flags = SHGSI_ICON | (size > 16 ? SHGSI_LARGEICON : SHGSI_SMALLICON);
    if (FAILED(SHGetStockIconInfo(id, flags, &sii)) || !sii.hIcon) return NULL;
    unsigned char *px = icon_to_rgba(sii.hIcon, pw, ph);
    DestroyIcon(sii.hIcon);
    return px;
}

static unsigned char *hwnd_to_rgba(HWND hwnd, int *pw, int *ph) {
    if (!IsWindow(hwnd)) return NULL;
    HICON ic = NULL;
    LRESULT r = 0;
    /* the window's own icon; never destroy what the window owns -> CopyIcon */
    if (SendMessageTimeoutW(hwnd, WM_GETICON, ICON_SMALL2, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 80, (PDWORD_PTR) &r) && r)
        ic = (HICON) r;
    if (!ic && SendMessageTimeoutW(hwnd, WM_GETICON, ICON_BIG, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 80, (PDWORD_PTR) &r) && r)
        ic = (HICON) r;
    if (!ic) ic = (HICON) GetClassLongPtrW(hwnd, GCLP_HICONSM);
    if (!ic) ic = (HICON) GetClassLongPtrW(hwnd, GCLP_HICON);
    if (!ic) return NULL;
    HICON copy = CopyIcon(ic);
    if (!copy) return NULL;
    unsigned char *px = icon_to_rgba(copy, pw, ph);
    DestroyIcon(copy);
    return px;
}

/* path -> RGBA: IShellItemImageFactory first (crisp, works for .lnk/.exe/files),
 * SHGetFileInfo(SHGFI_ICON) as the documented fallback (owned HICON). */
static unsigned char *path_to_rgba(const char *path, int size, int *pw, int *ph) {
    int wn = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wn <= 0 || wn > 4096) return NULL;
    wchar_t *wp = (wchar_t *) Tcl_Alloc((size_t) wn * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wp, wn);
    unsigned char *px = shellitem_to_rgba(wp, size, pw, ph);
    if (!px) {
        SHFILEINFOW sfi; memset(&sfi, 0, sizeof sfi);
        UINT flags = SHGFI_ICON | (size > 16 ? SHGFI_LARGEICON : SHGFI_SMALLICON);
        if (SHGetFileInfoW(wp, 0, &sfi, sizeof sfi, flags) && sfi.hIcon) {
            px = icon_to_rgba(sfi.hIcon, pw, ph);
            DestroyIcon(sfi.hIcon);                        /* owned -> must destroy */
        }
    }
    Tcl_Free((char *) wp);
    return px;
}

/* Resample RGBA into a size x size box, LETTERBOXED (aspect preserved, margins
 * transparent — a 16:9 video thumbnail must not be squashed square) and frees
 * the input. The shell hands back system metric sizes (e.g. 64px "large" at
 * 150% DPI); rows need one uniform size. */
static unsigned char *resample(unsigned char *src, int sw, int sh, int size) {
    if (sw == size && sh == size) return src;
    unsigned char *dst = (unsigned char *) Tcl_Alloc((size_t) size * size * 4);
    memset(dst, 0, (size_t) size * size * 4);              /* transparent margins */
    double scale = ((double) size / sw < (double) size / sh)
                 ? (double) size / sw : (double) size / sh;
    int dw = (int)(sw * scale + 0.5); if (dw < 1) dw = 1; if (dw > size) dw = size;
    int dh = (int)(sh * scale + 0.5); if (dh < 1) dh = 1; if (dh > size) dh = size;
    int ox = (size - dw) / 2, oy = (size - dh) / 2;
    for (int y = 0; y < dh; y++) {
        double fy = (dh > 1) ? ((double) y * (sh - 1) / (dh - 1)) : 0;
        int y0 = (int) fy; int y1 = (y0 + 1 < sh) ? y0 + 1 : y0;
        double ty = fy - y0;
        for (int x = 0; x < dw; x++) {
            double fx = (dw > 1) ? ((double) x * (sw - 1) / (dw - 1)) : 0;
            int x0 = (int) fx; int x1 = (x0 + 1 < sw) ? x0 + 1 : x0;
            double tx = fx - x0;
            for (int c = 0; c < 4; c++) {
                double v00 = src[(y0 * sw + x0) * 4 + c], v01 = src[(y0 * sw + x1) * 4 + c];
                double v10 = src[(y1 * sw + x0) * 4 + c], v11 = src[(y1 * sw + x1) * 4 + c];
                double v = v00 * (1 - tx) * (1 - ty) + v01 * tx * (1 - ty)
                         + v10 * (1 - tx) * ty + v11 * tx * ty;
                dst[((oy + y) * size + (ox + x)) * 4 + c] = (unsigned char) (v + 0.5);
            }
        }
    }
    Tcl_Free((char *) src);
    return dst;
}

/* ---- extraction dispatch ---------------------------------------------------- */
static unsigned char *extract(const char *spec, int size, int *pw, int *ph) {
    if (strncmp(spec, "aumid:", 6) == 0) {
        char parse[1200];
        snprintf(parse, sizeof parse, "shell:AppsFolder\\%s", spec + 6);
        int wn = MultiByteToWideChar(CP_UTF8, 0, parse, -1, NULL, 0);
        if (wn <= 0 || wn > 1200) return NULL;
        wchar_t wparse[1200];
        MultiByteToWideChar(CP_UTF8, 0, parse, -1, wparse, 1200);
        return shellitem_to_rgba(wparse, size, pw, ph);
    }
    if (strncmp(spec, "stock:", 6) == 0) return stock_to_rgba(spec + 6, size, pw, ph);
    if (strncmp(spec, "hwnd:", 5) == 0) {
        Tcl_WideInt hv = 0;
        if (sscanf(spec + 5, "%lld", (long long *) &hv) != 1) return NULL;
        return hwnd_to_rgba((HWND)(intptr_t) hv, pw, ph);
    }
    return path_to_rgba(spec, size, pw, ph);
}

/* ---- commands ---------------------------------------------------------------- */
static int ensure_com(void) {
    static int done = 0;
    if (!done) {
        HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
        (void) hr;              /* S_FALSE / RPC_E_CHANGED_MODE are fine: COM is up */
        done = 1;
    }
    return 1;
}

/* annicon::fill photoName spec size ?-cached?
 *   default: fill from cache or EXTRACT now (can touch shell/COM — caller should
 *            keep this off the keystroke path);
 *   -cached: fill ONLY from cache; returns "nocache" without extracting, so a
 *            render pass stays inside the §6.6 budget and defers misses. */
static int Icon_Fill(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 4 || objc > 5) { Tcl_WrongNumArgs(ip, 1, objv, "photoName spec size ?-cached?"); return TCL_ERROR; }
    const char *photoName = Tcl_GetString(objv[1]);
    const char *spec = Tcl_GetString(objv[2]);
    int size;
    if (Tcl_GetIntFromObj(ip, objv[3], &size) != TCL_OK) return TCL_ERROR;
    if (size < 8 || size > 256) { Tcl_SetObjResult(ip, Tcl_NewStringObj("bad size", -1)); return TCL_ERROR; }
    int cachedOnly = (objc == 5 && strcmp(Tcl_GetString(objv[4]), "-cached") == 0);

    Tk_PhotoHandle photo = Tk_FindPhoto(ip, photoName);
    if (photo == NULL) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("no photo image \"%s\"", photoName));
        return TCL_ERROR;
    }

    /* a spec longer than the key buffer could silently collide (same path at two
     * sizes!) — don't cache it at all, just serve the stock icon */
    char key[1300];
    int keyok = (snprintf(key, sizeof key, "%s|%d", spec, size) < (int) sizeof key);

    IconEnt *e = keyok ? cache_find(key) : NULL;
    int hit = (e != NULL);
    unsigned char *loose = NULL;       /* uncached pixels (oversize key / hwnd fail) */
    int lw = 0, lh = 0;
    if (!e) {
        if (cachedOnly) { Tcl_SetObjResult(ip, Tcl_NewStringObj("nocache", -1)); return TCL_OK; }
        ensure_com();
        int w = 0, h = 0;
        unsigned char *px = keyok ? extract(spec, size, &w, &h) : NULL;
        int failed = (px == NULL);
        if (!px) {
            px = stock_to_rgba("doc", size, &w, &h);
            if (!px) { Tcl_SetObjResult(ip, Tcl_NewStringObj("icon extraction failed", -1)); return TCL_ERROR; }
        }
        px = resample(px, w, h, size);                     /* uniform row size */
        /* never cache a FAILURE for live-window specs: a transient WM_GETICON
         * timeout must not pin the generic icon to that hwnd forever */
        int dontCache = !keyok || (failed && strncmp(spec, "hwnd:", 5) == 0);
        if (dontCache) {
            loose = px; lw = size; lh = size;
        } else {
            e = cache_put(key, px, size, size);
        }
        gMisses++;
    } else {
        gHits++;
    }
    if (loose) {
        Tk_PhotoImageBlock lb;
        lb.pixelPtr = loose; lb.width = lw; lb.height = lh;
        lb.pitch = lw * 4; lb.pixelSize = 4;
        lb.offset[0] = 0; lb.offset[1] = 1; lb.offset[2] = 2; lb.offset[3] = 3;
        int rc = TCL_OK;
        if (Tk_PhotoSetSize(ip, photo, lw, lh) != TCL_OK) rc = TCL_ERROR;
        if (rc == TCL_OK) {
            Tk_PhotoBlank(photo);
            rc = Tk_PhotoPutBlock(ip, photo, &lb, 0, 0, lw, lh, TK_PHOTO_COMPOSITE_SET);
        }
        Tcl_Free((char *) loose);
        if (rc != TCL_OK) return TCL_ERROR;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("miss", -1));
        return TCL_OK;
    }

    /* push into the named photo: the §9.7-safe layout */
    Tk_PhotoImageBlock block;
    block.pixelPtr  = e->rgba;
    block.width     = e->w;
    block.height    = e->h;
    block.pitch     = e->w * 4;
    block.pixelSize = 4;
    block.offset[0] = 0; block.offset[1] = 1; block.offset[2] = 2; block.offset[3] = 3;
    if (Tk_PhotoSetSize(ip, photo, e->w, e->h) != TCL_OK) return TCL_ERROR;
    Tk_PhotoBlank(photo);
    if (Tk_PhotoPutBlock(ip, photo, &block, 0, 0, e->w, e->h,
                         TK_PHOTO_COMPOSITE_SET) != TCL_OK) return TCL_ERROR;

    Tcl_SetObjResult(ip, Tcl_NewStringObj(hit ? "hit" : "miss", -1));
    return TCL_OK;
}

static int Icon_Stats(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    int entries = 0;
    for (int i = 0; i < ANN_ICON_CACHE_MAX; i++) if (gCache[i].key) entries++;
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("hits", -1),      Tcl_NewWideIntObj(gHits));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("misses", -1),    Tcl_NewWideIntObj(gMisses));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("evictions", -1), Tcl_NewWideIntObj(gEvict));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("entries", -1),   Tcl_NewIntObj(entries));
    Tcl_SetObjResult(ip, d);
    return TCL_OK;
}

int Annicon_Init(Tcl_Interp *ip) {
#ifdef USE_TCL_STUBS
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
#endif
#ifdef USE_TK_STUBS
    if (Tk_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
#endif
    Tcl_CreateNamespace(ip, "::annicon", NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annicon::fill",  Icon_Fill,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annicon::stats", Icon_Stats, NULL, NULL);
    Tcl_PkgProvideEx(ip, "annicon", "0.1", NULL);
    return TCL_OK;
}

/*
 * annindex.c -- discovery + the single-writer indexer + the filesystem watcher
 * (DESIGN §3.2, §7.1, §7.2, §8).
 *
 * Catalog sources, merged by the ONE writer connection:
 *   (a) Start-Menu .lnk shortcuts -> IShellLink/IPersistFile (GetPath SLGP_RAWPATH;
 *       never IShellLink::Resolve, §7.1) with an mtime cache so an unchanged .lnk
 *       is not re-resolved on rescan.
 *   (b) Packaged (UWP/Store) apps via FOLDERID_AppsFolder -> AUMID.
 *   (c) Files & folders under the watched roots (default Desktop/Documents/
 *       Downloads; configurable via annindex::set_roots), depth- and count-capped.
 *   (d) The fixed system-command list (§8), seeded as kind='system_cmd'.
 * Every full scan stamps rows with a scan generation and PRUNES rows of these
 * kinds whose generation is stale, so deleted apps/files disappear.
 *
 * Threads:
 *   INDEXER  owns the writer connection; waits on {stop, work=full-rescan,
 *            usage-queue, file-event-queue}. All SQLite writes happen here.
 *   WATCHER  ReadDirectoryChangesW over an IOCP for each watched root (+ the
 *            config file's directory, non-recursive); debounces ~200 ms; feeds
 *            TARGETED file events to the indexer (delete/upsert single paths) or
 *            requests a full rescan on overflow; config-file changes notify the
 *            GUI directly (hot reload, §11.2).
 * Handshake policy (review findings): every wait result is checked; handles are
 * NEVER closed while a thread might still use them — a handshake timeout wedges
 * the subsystem (one-time leak, restart refused) instead of corrupting state.
 *
 * This is the ONE translation unit that defines INITGUID (DESIGN §4.3).
 *
 * Commands:
 *   annindex::scan <dbpath>                  -> sync discovery (refused while the
 *                                               async indexer runs); stats dict
 *   annindex::start <dbpath> <notifyProc> ?configPath configNotifyProc?
 *   annindex::rescan | stop | active | stats
 *   annindex::record_usage <catalog_id>      -> queue a launch for frecency
 *   annindex::set_roots <list>               -> watched roots (rescan + rewatch)
 *   annindex::get_roots
 *   annindex::tune <halflife_days>           -> frecency decay used on writes
 */

#define INITGUID
#include <initguid.h>
#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>      /* pulls knownfolders.h (FOLDERID_*) — do NOT include it
                          * again: with INITGUID active it has no guard against
                          * re-emitting the GUID definitions. */
#include <shobjidl.h>
#include <shlguid.h>     /* BHID_EnumItems, CLSID_ShellLink */
#include <objbase.h>
#include "sqlite3.h"
#include "ann_norm.h"
#include "ann_schema.h"
#include "ann_fuzzy.h"   /* ANN_FREC_LAMBDA default for the frecency decay */
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <time.h>

/* ---- limits ---------------------------------------------------------------- */
#define ANN_ROOTS_MAX   16
#define ANN_PRIO_MAX    8          /* priority locations (DESIGN §7.2 amendment) */
#define ANN_PRIO_DEPTH  6          /* tier 0: user areas, every file type */
#define ANN_PRIO_BUDGET 30000
#define ANN_BULK_DEPTH  10         /* tier 1: throttled remainder of each root */
#define ANN_BULK_BUDGET 120000
#define ANN_USAGE_QMAX  256
#define ANN_FILEQ_MAX   512
#define ANN_WATCH_BUF   (60 * 1024)

/* ---- scan stats ------------------------------------------------------------ */
typedef struct {
    int lnk_found, lnk_resolved, lnk_cached, uwp_found, files_found, errors;
    int files_prio, files_bulk;    /* tier split of files_found */
    int capped_prio, capped_bulk;  /* 1 = budget exhausted (logged, never silent) */
    int bulk_done, bulk_aborted;   /* bulk walk completed / yielded to new work */
    int bulk_ms;                   /* wall time of the bulk phase */
    int phase;                     /* live: 0 idle, 1 priority scan, 2 background walk */
} Stats;

/* Tier-1 deny list: directory NAMES never entered nor indexed during the bulk
 * walk (and dropped at the watcher). Case-insensitive component match. */
static const char *const ANN_DENY_DIR[] = {
    "windows", "windows.old", "programdata", "$recycle.bin",
    "system volume information", "recovery", "perflogs", "temp", "tmp",
    "cache", "caches", "node_modules", "__pycache__",
};
/* Tier-1 allow list: only startable/openable FILE types are worth a row when
 * walking a whole disk (folders always index, subject to the deny list).
 * Tier 0 (user areas) keeps indexing every file type. */
static const char *const ANN_ALLOW_EXT[] = {
    "exe", "lnk", "bat", "cmd", "msc", "msi", "url", "appref-ms",
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
    "rtf", "txt", "md", "csv",
    "jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "heic",
    "mp3", "wav", "flac", "m4a", "ogg",
    "mp4", "mkv", "mov", "avi", "webm", "wmv",
    "zip", "7z", "rar", "iso",
};

static int deny_dir_name(const char *lowname) {
    for (size_t i = 0; i < sizeof ANN_DENY_DIR / sizeof *ANN_DENY_DIR; i++)
        if (strcmp(lowname, ANN_DENY_DIR[i]) == 0) return 1;
    return 0;
}
/* any path COMPONENT on the deny list? (watcher pre-filter + event guard) */
static int has_denied_component(const char *path) {
    char comp[128];
    size_t ci = 0;
    for (const char *p = path; ; p++) {
        if (*p == '\\' || *p == '/' || *p == 0) {
            if (ci > 0 && ci < sizeof comp) {
                comp[ci] = 0;
                if (deny_dir_name(comp)) return 1;
            }
            ci = 0;
            if (*p == 0) return 0;
        } else if (ci < sizeof comp - 1) {
            comp[ci++] = (char) tolower((unsigned char) *p);
        } else {
            ci = sizeof comp;     /* oversized component: never matches */
        }
    }
}
static int allow_ext(const char *name) {
    const char *dot = strrchr(name, '.');
    if (!dot || !dot[1]) return 0;
    char e[12]; size_t n = strlen(dot + 1);
    if (n >= sizeof e) return 0;
    for (size_t i = 0; i <= n; i++) e[i] = (char) tolower((unsigned char) dot[1 + i]);
    for (size_t i = 0; i < sizeof ANN_ALLOW_EXT / sizeof *ANN_ALLOW_EXT; i++)
        if (strcmp(e, ANN_ALLOW_EXT[i]) == 0) return 1;
    return 0;
}

/* ---- shared state (one lock for stats/roots/queues) ------------------------ */
static CRITICAL_SECTION gLock;
static int gLockInit = 0;
static Stats gLastStats;
static double gFrecLambda = ANN_FREC_LAMBDA;   /* annindex::tune (M8) */

static char *gRoots[ANN_ROOTS_MAX];            /* UTF-8, Tcl_Alloc'd; under gLock */
static int   gRootsPrio[ANN_ROOTS_MAX];       /* 1 = tier 0 (fast/first), per folder */
static int   gRootsSet = 0;                    /* set_roots called (even empty list):
                                                * an explicit EMPTY list means "scan
                                                * no files", never "use defaults" */
static int   gRootsN = 0;

static sqlite3_int64 gUsageQ[ANN_USAGE_QMAX];  /* under gLock */
static int gUsageN = 0;

typedef struct { char *path; int remove; } FileEv; /* path Tcl_Alloc'd; under gLock */
static FileEv gFileQ[ANN_FILEQ_MAX];
static int gFileQN = 0;

/* ---- small string helpers --------------------------------------------------- */
static char *wide_to_utf8(const wchar_t *w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *s = (char *) Tcl_Alloc(n > 0 ? n : 1);
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    else s[0] = 0;
    return s;
}
static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = (wchar_t *) Tcl_Alloc((size_t)(n > 0 ? n : 1) * sizeof(wchar_t));
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    else w[0] = 0;
    return w;
}
/* heap "dir\name" join — never truncates, never leaves garbage (findings #2/#16) */
static wchar_t *path_join(const wchar_t *dir, const wchar_t *name) {
    size_t a = wcslen(dir), b = wcslen(name);
    if (a + b + 2 > 32000) return NULL;
    wchar_t *p = (wchar_t *) Tcl_Alloc((a + b + 2) * sizeof(wchar_t));
    memcpy(p, dir, a * sizeof(wchar_t));
    p[a] = L'\\';
    memcpy(p + a + 1, name, (b + 1) * sizeof(wchar_t));
    return p;
}

static sqlite3_int64 filetime_to_unix(const FILETIME *ft) {
    ULARGE_INTEGER u; u.LowPart = ft->dwLowDateTime; u.HighPart = ft->dwHighDateTime;
    return (sqlite3_int64)((u.QuadPart - 116444736000000000ULL) / 10000000ULL);
}

/* ---- writer (the ONE writing connection) ------------------------------------ */
typedef struct {
    sqlite3 *db;
    sqlite3_stmt *up, *getm, *touch, *del;
    sqlite3_int64 gen;          /* current scan generation (stamped into updated_at) */
} Writer;

static int writer_open(Writer *w, const char *path) {
    memset(w, 0, sizeof *w);
    if (sqlite3_open_v2(path, &w->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK)
        return 0;
    sqlite3_busy_timeout(w->db, 3000);
    sqlite3_exec(w->db, "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA foreign_keys=ON;", NULL, NULL, NULL);
    if (sqlite3_exec(w->db, ANN_SCHEMA_SQL, NULL, NULL, NULL) != SQLITE_OK) return 0;
    {   /* migrate a pre-tier DB in place (preserves frecency); on a current DB
         * the only possible failure is "duplicate column name" — ignored */
        char *err = NULL;
        if (sqlite3_exec(w->db, "ALTER TABLE catalog ADD COLUMN tier INTEGER NOT NULL DEFAULT 0",
                         NULL, NULL, &err) != SQLITE_OK) sqlite3_free(err);
    }
    sqlite3_prepare_v2(w->db,
        "INSERT INTO catalog(path,display_name,kind,launch_kind,target,search_text,keywords,enabled,updated_at,source_mtime,tier)"
        " VALUES(?1,?2,?3,?4,?5,?6,?7,1,?9,?8,?10)"
        " ON CONFLICT(path) DO UPDATE SET display_name=excluded.display_name,kind=excluded.kind,"
        " launch_kind=excluded.launch_kind,target=excluded.target,search_text=excluded.search_text,"
        " keywords=excluded.keywords,enabled=1,updated_at=excluded.updated_at,source_mtime=excluded.source_mtime,"
        " tier=excluded.tier",
        -1, &w->up, NULL);
    sqlite3_prepare_v2(w->db, "SELECT source_mtime FROM catalog WHERE path=?1", -1, &w->getm, NULL);
    /* the touch deliberately avoids search_text: catalog_au2 (OF search_text)
     * stays silent, so a warm rescan costs no trigram-index churn */
    sqlite3_prepare_v2(w->db, "UPDATE catalog SET updated_at=?2, tier=?3 WHERE path=?1", -1, &w->touch, NULL);
    sqlite3_prepare_v2(w->db, "DELETE FROM catalog WHERE path=?1 AND kind IN ('file','folder')", -1, &w->del, NULL);
    w->gen = (sqlite3_int64) time(NULL);
    return w->up && w->getm && w->touch && w->del;
}
static void writer_close(Writer *w) {
    if (w->up)    sqlite3_finalize(w->up);
    if (w->getm)  sqlite3_finalize(w->getm);
    if (w->touch) sqlite3_finalize(w->touch);
    if (w->del)   sqlite3_finalize(w->del);
    if (w->db)    sqlite3_close(w->db);
    memset(w, 0, sizeof *w);
}
static sqlite3_int64 writer_mtime(Writer *w, const char *path) {
    sqlite3_int64 m = -1;
    sqlite3_reset(w->getm);
    sqlite3_bind_text(w->getm, 1, path, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(w->getm) == SQLITE_ROW) m = sqlite3_column_int64(w->getm, 0);
    return m;
}
/* keep a cache-hit row in the current generation so the prune spares it */
static void writer_touch(Writer *w, const char *path, int tier) {
    sqlite3_reset(w->touch);
    sqlite3_bind_text(w->touch, 1, path, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(w->touch, 2, w->gen);
    sqlite3_bind_int(w->touch, 3, tier);
    sqlite3_step(w->touch);
}
/* returns 1 ok / 0 failed (caller counts errors) */
static int writer_upsert_tier(Writer *w, const char *path, const char *name, const char *kind,
                              const char *lk, const char *target, const char *kw,
                              sqlite3_int64 mtime, int tier);
static int writer_upsert(Writer *w, const char *path, const char *name, const char *kind,
                         const char *lk, const char *target, const char *kw, sqlite3_int64 mtime) {
    return writer_upsert_tier(w, path, name, kind, lk, target, kw, mtime, 0);
}
static int writer_upsert_tier(Writer *w, const char *path, const char *name, const char *kind,
                              const char *lk, const char *target, const char *kw,
                              sqlite3_int64 mtime, int tier) {
    size_t rawcap = strlen(name) + (target ? strlen(target) : 0) + (kw ? strlen(kw) : 0) + 4;
    char *raw = (char *) Tcl_Alloc(rawcap);
    snprintf(raw, rawcap, "%s %s %s", name, target ? target : "", kw ? kw : "");
    int ncap = (int) rawcap * 4 + 8;
    char *st = (char *) Tcl_Alloc(ncap);
    ann_normalize(raw, st, ncap);
    Tcl_Free(raw);
    sqlite3_reset(w->up);
    sqlite3_bind_text(w->up, 1, path, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(w->up, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(w->up, 3, kind, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(w->up, 4, lk, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(w->up, 5, target ? target : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(w->up, 6, st, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(w->up, 7, kw ? kw : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(w->up, 8, mtime);
    sqlite3_bind_int64(w->up, 9, w->gen);
    sqlite3_bind_int(w->up, 10, tier);
    int rc = sqlite3_step(w->up);
    Tcl_Free(st);
    return rc == SQLITE_DONE;
}

/* ---- async thread state (declared early: the scan polls gStop) -------------- */
static Tcl_ThreadId gGui = NULL;
static Tcl_Interp  *gInterp = NULL;
static Tcl_Obj     *gNotify = NULL;        /* catalog-updated callback */
static Tcl_Obj     *gNotifyCfg = NULL;     /* config-changed callback */
static Tcl_ThreadId gIdxThread = NULL;
static HANDLE gStop = NULL, gWork = NULL, gUsage = NULL, gFileEvt = NULL,
              gReady = NULL, gDone = NULL;
static char   gDbPath[1024];
static char   gCfgPath[1024];              /* "" = no config watch */
static int    gReadyOk = 0;
static int    gWedged = 0;

/* watcher thread state */
static Tcl_ThreadId gWatchThread = NULL;
static HANDLE gWatchIocp = NULL, gWatchDone = NULL;
static int gWatchActive = 0;

static int stop_requested(void) {
    return gStop != NULL && WaitForSingleObject(gStop, 0) == WAIT_OBJECT_0;
}

/* ---- (a) Start-Menu .lnk discovery ------------------------------------------ */
static void resolve_and_upsert_lnk(Writer *w, const wchar_t *wpath, sqlite3_int64 mtime, Stats *st) {
    char *path = wide_to_utf8(wpath);

    /* basename without extension -> display name */
    const wchar_t *base = wcsrchr(wpath, L'\\');
    base = base ? base + 1 : wpath;
    wchar_t name[260]; wcsncpy(name, base, 259); name[259] = 0;
    wchar_t *dot = wcsrchr(name, L'.'); if (dot) *dot = 0;
    char *uname = wide_to_utf8(name);

    /* mtime cache: unchanged .lnk -> skip the COM resolve, keep it in this gen */
    if (writer_mtime(w, path) == mtime) {
        writer_touch(w, path, 0);
        st->lnk_cached++;
        Tcl_Free(path); Tcl_Free(uname);
        return;
    }

    char *target = NULL;
    IShellLinkW *sl = NULL;
    if (CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                         &IID_IShellLinkW, (void **) &sl) == S_OK) {
        IPersistFile *pf = NULL;
        if (sl->lpVtbl->QueryInterface(sl, &IID_IPersistFile, (void **) &pf) == S_OK) {
            if (pf->lpVtbl->Load(pf, wpath, STGM_READ) == S_OK) {
                wchar_t tbuf[MAX_PATH]; WIN32_FIND_DATAW fd;
                /* SLGP_RAWPATH: do NOT trigger Distributed Link Tracking (no net block) */
                if (sl->lpVtbl->GetPath(sl, tbuf, MAX_PATH, &fd, SLGP_RAWPATH) == S_OK && tbuf[0]) {
                    target = wide_to_utf8(tbuf);
                }
            }
            pf->lpVtbl->Release(pf);
        }
        sl->lpVtbl->Release(sl);
    }

    if (writer_upsert(w, path, uname, "shortcut", "path", target, "", mtime)) st->lnk_resolved++;
    else st->errors++;
    Tcl_Free(path); Tcl_Free(uname);
    if (target) Tcl_Free(target);
}

static void walk_lnks(Writer *w, const wchar_t *dir, Stats *st, int depth) {
    if (depth > 8 || stop_requested()) return;
    wchar_t *pat = path_join(dir, L"*");
    if (!pat) { st->errors++; return; }
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    Tcl_Free((char *) pat);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.cFileName[0] == L'.' &&
            (fd.cFileName[1] == 0 || (fd.cFileName[1] == L'.' && fd.cFileName[2] == 0))) continue;
        wchar_t *full = path_join(dir, fd.cFileName);
        if (!full) { st->errors++; continue; }
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            walk_lnks(w, full, st, depth + 1);
        } else {
            size_t n = wcslen(fd.cFileName);
            if (n > 4 && _wcsicmp(fd.cFileName + n - 4, L".lnk") == 0) {
                st->lnk_found++;
                resolve_and_upsert_lnk(w, full, filetime_to_unix(&fd.ftLastWriteTime), st);
            }
        }
        Tcl_Free((char *) full);
    } while (FindNextFileW(h, &fd) && !stop_requested());
    FindClose(h);
}

static void scan_start_menu(Writer *w, Stats *st) {
    const KNOWNFOLDERID *folders[2] = { &FOLDERID_CommonStartMenu, &FOLDERID_StartMenu };
    for (int i = 0; i < 2; i++) {
        PWSTR dir = NULL;
        if (SHGetKnownFolderPath(folders[i], 0, NULL, &dir) == S_OK && dir) {
            walk_lnks(w, dir, st, 0);
        }
        if (dir) CoTaskMemFree(dir);
    }
}

/* ---- (b) packaged-app discovery via FOLDERID_AppsFolder --------------------- */
static void scan_apps_folder(Writer *w, Stats *st) {
    IShellItem *folder = NULL;
    if (SHGetKnownFolderItem(&FOLDERID_AppsFolder, KF_FLAG_DEFAULT, NULL,
                             &IID_IShellItem, (void **) &folder) != S_OK || !folder) return;
    IEnumShellItems *en = NULL;
    if (folder->lpVtbl->BindToHandler(folder, NULL, &BHID_EnumItems,
                                      &IID_IEnumShellItems, (void **) &en) == S_OK && en) {
        IShellItem *it = NULL; ULONG got = 0;
        while (!stop_requested() && en->lpVtbl->Next(en, 1, &it, &got) == S_OK && got == 1 && it) {
            PWSTR wname = NULL, waumid = NULL;
            it->lpVtbl->GetDisplayName(it, SIGDN_NORMALDISPLAY, &wname);
            /* parent-relative parsing name of an AppsFolder child == its AUMID
             * (mingw lacks the SDK alias SIGDN_PARENTRELATIVEFORPARSING; same value) */
            it->lpVtbl->GetDisplayName(it, SIGDN_PARENTRELATIVEPARSING, &waumid);
            /* Packaged apps have an AUMID like "Pkg_hash!App" (contains '!');
             * desktop apps here are covered by their .lnk, so skip them (dedup). */
            if (wname && waumid && wcschr(waumid, L'!')) {
                char *name = wide_to_utf8(wname);
                char *aumid = wide_to_utf8(waumid);
                if (writer_upsert(w, aumid, name, "uwp", "aumid", NULL, "", 0)) st->uwp_found++;
                else st->errors++;
                Tcl_Free(name); Tcl_Free(aumid);
            }
            if (wname) CoTaskMemFree(wname);
            if (waumid) CoTaskMemFree(waumid);
            it->lpVtbl->Release(it);
            it = NULL;
        }
        en->lpVtbl->Release(en);
    }
    folder->lpVtbl->Release(folder);
}

/* ---- (c) files & folders under the watched roots (DESIGN §7.2) -------------- */
static int prio_snapshot(char *out[ANN_PRIO_MAX]);   /* fwd: the defaults reuse it */

/* Snapshot the scan-folder list WITH each folder's user-set priority flag
 * (1 = tier 0: fast/first/all types; 0 = tier 1: slow/last/throttled). When
 * nothing was ever set, the defaults are the seven startable-item locations,
 * priority ON — ordinary entries the user may delete or demote (§7.2). */
static void roots_snapshot(char *out[ANN_ROOTS_MAX], int prio[ANN_ROOTS_MAX], int *outn) {
    EnterCriticalSection(&gLock);
    if (gRootsN == 0 && !gRootsSet) {
        /* gLock is a CRITICAL_SECTION: reentrant, the nested lock is fine */
        char *defs[ANN_PRIO_MAX];
        int n = prio_snapshot(defs);
        for (int i = 0; i < n; i++) {
            if (gRootsN < ANN_ROOTS_MAX) {
                gRootsPrio[gRootsN] = 1;          /* defaults: priority ON */
                gRoots[gRootsN++] = defs[i];
            } else Tcl_Free(defs[i]);
        }
    }
    for (int i = 0; i < gRootsN; i++) {
        out[i] = (char *) Tcl_Alloc(strlen(gRoots[i]) + 1);
        strcpy(out[i], gRoots[i]);
        prio[i] = gRootsPrio[i];
    }
    *outn = gRootsN;
    LeaveCriticalSection(&gLock);
}

/* only the priority-ON folders (event tiering + the bulk walk's skip list) */
static int roots_prio_snapshot(char *out[ANN_ROOTS_MAX]) {
    char *all[ANN_ROOTS_MAX]; int pr[ANN_ROOTS_MAX]; int n = 0, k = 0;
    roots_snapshot(all, pr, &n);
    for (int i = 0; i < n; i++) {
        if (pr[i]) out[k++] = all[i]; else Tcl_Free(all[i]);
    }
    return k;
}

/* ---- the DEFAULT seed locations (Win11 startable-item folders, §7.2) --------
 * Most-startable first (the tier-0 budget truncates the least valuable last).
 * Exposed as annindex::priority_paths for the Settings seed + coverage hint. */
static int prio_snapshot(char *out[ANN_PRIO_MAX]) {
    const KNOWNFOLDERID *def[] = {
        &FOLDERID_Desktop, &FOLDERID_PublicDesktop, &FOLDERID_Downloads,
        &FOLDERID_Documents, &FOLDERID_UserProgramFiles,
        &FOLDERID_ProgramFiles, &FOLDERID_ProgramFilesX86,
    };
    int n = 0;
    for (size_t i = 0; i < sizeof def / sizeof *def && n < ANN_PRIO_MAX; i++) {
        PWSTR dir = NULL;
        if (SHGetKnownFolderPath(def[i], 0, NULL, &dir) == S_OK && dir) {
            DWORD a = GetFileAttributesW(dir);
            if (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY))
                out[n++] = wide_to_utf8(dir);
        }
        if (dir) CoTaskMemFree(dir);
    }
    return n;
}

/* case-insensitive "path is under-or-equal root" with a component boundary
 * (C:\Foo covers C:\Foo\bar, never C:\Foobar); both UTF-8, either slash kind */
static int path_covers(const char *root, const char *path) {
    size_t rl = strlen(root), pl = strlen(path);
    while (rl > 1 && (root[rl-1] == '\\' || root[rl-1] == '/')
           && !(rl == 3 && root[1] == ':')) rl--;     /* keep "C:\" intact */
    if (rl == 0 || pl < rl) return 0;
    for (size_t i = 0; i < rl; i++) {
        char a = root[i], b = path[i];
        if (a == '/') a = '\\';
        if (b == '/') b = '\\';
        if (tolower((unsigned char) a) != tolower((unsigned char) b)) return 0;
    }
    if (pl == rl) return 1;
    if (root[rl-1] == '\\' || root[rl-1] == '/') return 1;   /* root ends with sep */
    return path[rl] == '\\' || path[rl] == '/';
}

/* the tier a live file event lands in: covered by a priority-ON folder -> 0 */
static int tier_for_path(const char *path, char *prio[], int prion) {
    for (int i = 0; i < prion; i++)
        if (path_covers(prio[i], path)) return 0;
    return 1;
}

/* pacing knobs (annindex::tune; tests set bulk_sleep 0) — read under gLock.
 * ~200 entries of walk+upsert take well under 25ms, so this is a <50% duty
 * cycle on top of THREAD_MODE_BACKGROUND's idle CPU/IO priority. */
static int gBulkSleepMs   = 25;
static int gBulkBatch     = 200;
static int gBulkCooldownS = 600;

/* ann's own files (db, -wal, -shm, log, selftest report) live in a watched
 * root; their write events MUST be dropped or the bulk scan's own commits feed
 * the watcher a permanent event storm (observed live: 3 aborted bulk walks). */
static int is_self_path(const char *path) {
    size_t dl = strlen(gDbPath);
    if (dl == 0) return 0;
    const char *sl = strrchr(gDbPath, '\\');
    size_t dirl = sl ? (size_t)(sl - gDbPath) + 1 : 0;
    if (dirl == 0) return 0;
    if (_strnicmp(path, gDbPath, dirl) != 0) return 0;
    const char *base = path + dirl;
    if (strchr(base, '\\')) return 0;          /* not a direct child */
    return _strnicmp(base, "ann", 3) == 0 && (base[3] == '.' || base[3] == '-');
}

static int apply_file_events(Writer *w);       /* fwd: drained between bulk batches */

typedef struct {
    Writer *w; Stats *st;
    int tier, maxDepth;
    int budget;
    char **skip; int nskip;        /* tier 1: priority subtrees already scanned */
    int sleepMs, batch;            /* tier 1 pacing (0 = none) */
    int pace;                      /* entries since the last pacing point */
    int aborted;                   /* gWork arrived mid-bulk: yield to new work */
} Walk;

/* a pacing point: commit the batch, drain live file events, sleep, re-check */
static void walk_pace(Walk *wk) {
    if (wk->tier != 1 || wk->batch <= 0 || ++wk->pace < wk->batch) return;
    wk->pace = 0;
    sqlite3_exec(wk->w->db, "COMMIT", NULL, NULL, NULL);     /* never sleep in a tx */
    apply_file_events(wk->w);                                /* don't starve the watcher */
    if (wk->sleepMs > 0) Sleep((DWORD) wk->sleepMs);
    if (WaitForSingleObject(gWork, 0) == WAIT_OBJECT_0) {
        SetEvent(gWork);                                     /* keep the signal for the loop */
        wk->aborted = 1;
    }
    sqlite3_exec(wk->w->db, "BEGIN", NULL, NULL, NULL);
}

static void walk_tree(Walk *wk, const wchar_t *dir, int depth) {
    if (depth > wk->maxDepth || wk->budget <= 0 || wk->aborted || stop_requested()) return;
    wchar_t *pat = path_join(dir, L"*");
    if (!pat) { wk->st->errors++; return; }
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    Tcl_Free((char *) pat);
    if (h == INVALID_HANDLE_VALUE) return;     /* unreadable (ACL): skip silently */
    do {
        if (fd.cFileName[0] == L'.') continue;            /* dotfiles + . + .. */
        if (fd.dwFileAttributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)) continue;
        wchar_t *full = path_join(dir, fd.cFileName);
        if (!full) { wk->st->errors++; continue; }
        char *u = wide_to_utf8(full);
        char *uname = wide_to_utf8(fd.cFileName);
        int isdir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        int want = 1, recurse = isdir && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
        if (isdir) {
            /* the deny list holds for BOTH tiers: a node_modules inside
             * Documents must not eat the tier-0 budget (seen on real machines) */
            char low[260]; size_t ln = strlen(uname);
            if (ln < sizeof low) {
                for (size_t i = 0; i <= ln; i++) low[i] = (char) tolower((unsigned char) uname[i]);
                if (deny_dir_name(low)) { want = 0; recurse = 0; }
            }
            if (wk->tier == 1) {
                /* skip priority subtrees: tier 0 already owns them */
                for (int i = 0; want && i < wk->nskip; i++) {
                    if (path_covers(wk->skip[i], u)) { want = 0; recurse = 0; }
                }
            }
        } else if (wk->tier == 1 && !allow_ext(uname)) {
            want = 0;              /* whole-disk walk: startable/openable types only */
        }
        if (want) {
            sqlite3_int64 mt = filetime_to_unix(&fd.ftLastWriteTime);
            int ok;
            if (mt > 0 && writer_mtime(wk->w, u) == mt) {
                /* unchanged since last scan: a cheap generation/tier touch —
                 * no row rewrite, no trigram churn, tiny WAL footprint */
                writer_touch(wk->w, u, wk->tier);
                ok = 1;
            } else {
                ok = writer_upsert_tier(wk->w, u, uname, isdir ? "folder" : "file",
                                        "path", NULL, "", mt, wk->tier);
            }
            if (ok) {
                wk->st->files_found++;
                if (wk->tier == 0) wk->st->files_prio++; else wk->st->files_bulk++;
                wk->budget--;
            } else wk->st->errors++;
        }
        walk_pace(wk);
        if (recurse) walk_tree(wk, full, depth + 1);
        Tcl_Free(u); Tcl_Free(uname); Tcl_Free((char *) full);
    } while (wk->budget > 0 && !wk->aborted && FindNextFileW(h, &fd) && !stop_requested());
    FindClose(h);
}

/* tier 0: every priority location covered by a root — fast, unpaced, all types.
 * Each location gets its own budget SLICE: one bloated Documents tree must not
 * starve Program Files of its slots (observed on the first real-machine run).
 * Each priority-ON folder gets its own budget SLICE: one bloated tree must
 * not starve the rest (observed live). */
static int gPrioEach = 8000;                   /* annindex::tune prio_each */
static void scan_prio(Writer *w, Stats *st, char *fast[], int nfast) {
    int each;
    EnterCriticalSection(&gLock); each = gPrioEach; LeaveCriticalSection(&gLock);
    int remaining = ANN_PRIO_BUDGET;
    for (int i = 0; i < nfast && remaining > 0; i++) {
        Walk wk = { .w = w, .st = st, .tier = 0, .maxDepth = ANN_PRIO_DEPTH,
                    .budget = (remaining < each ? remaining : each) };
        int given = wk.budget;
        wchar_t *wp = utf8_to_wide(fast[i]);
        if (wp) { walk_tree(&wk, wp, 0); Tcl_Free((char *) wp); }
        remaining -= (given - wk.budget);
        if (wk.budget <= 0) st->capped_prio = 1;
    }
    if (remaining <= 0) st->capped_prio = 1;
}

/* tier 1: every priority-OFF folder — paced, deny/allow filtered, skipping any
 * subtree owned by a priority-ON folder (overlap, e.g. C:\ off + Desktop on).
 * Returns 0 when aborted by new work (caller must NOT prune tier 1). */
static int scan_bulk(Writer *w, Stats *st, char *slow[], int nslow,
                     char *fast[], int nfast, int sleepMs, int batch) {
    Walk wk = { .w = w, .st = st, .tier = 1, .maxDepth = ANN_BULK_DEPTH,
                .budget = ANN_BULK_BUDGET, .skip = fast, .nskip = nfast,
                .sleepMs = sleepMs, .batch = batch };
    for (int i = 0; i < nslow && wk.budget > 0 && !wk.aborted; i++) {
        wchar_t *wr = utf8_to_wide(slow[i]);
        if (wr) { walk_tree(&wk, wr, 0); Tcl_Free((char *) wr); }
    }
    st->capped_bulk = (wk.budget <= 0);
    st->bulk_aborted = wk.aborted;
    return !wk.aborted;
}

/* ---- (d) the fixed system-command list (DESIGN §8) -------------------------- */
static void seed_system_commands(Writer *w, Stats *st) {
    static const struct { const char *id, *name, *kw; } CMDS[] = {
        { "syscmd:lock",     "Lock Workstation",  "lock workstation" },
        { "syscmd:sleep",    "Sleep",             "sleep suspend standby" },
        { "syscmd:shutdown", "Shut Down",         "shutdown power off halt" },
        { "syscmd:restart",  "Restart",           "restart reboot" },
        { "syscmd:emptybin", "Empty Recycle Bin", "empty recycle bin trash" },
        { "syscmd:settings", "Settings",          "settings preferences options" },
        { "syscmd:control",  "Control Panel",     "control panel" },
        { "syscmd:quit",     "Quit ann",          "quit exit ann" },
    };
    for (size_t i = 0; i < sizeof CMDS / sizeof CMDS[0]; i++) {
        if (!writer_upsert(w, CMDS[i].id, CMDS[i].name, "system_cmd", "syscmd",
                           NULL, CMDS[i].kw, 0)) st->errors++;
    }
}

/* ---- the two-phase scan (DESIGN §7.2 amendment) ------------------------------ */
static void meta_stamp(Writer *w, Stats *st, const char *key) {
    sqlite3_stmt *m = NULL;
    char sql[160];
    snprintf(sql, sizeof sql, "INSERT INTO app_meta(key,value) VALUES('%s',unixepoch())"
             " ON CONFLICT(key) DO UPDATE SET value=excluded.value", key);
    if (sqlite3_prepare_v2(w->db, sql, -1, &m, NULL) == SQLITE_OK) {
        if (sqlite3_step(m) != SQLITE_DONE) st->errors++;
        sqlite3_finalize(m);
    } else st->errors++;
}

/* MONOTONIC scan generation: time(NULL) alone collides when two scans run in
 * the same second, and `updated_at < gen` would then never prune (latent in the
 * pre-tier code; exposed by the per-tier prune tests). Writer-side only. */
static sqlite3_int64 gGenLast = 0;
static sqlite3_int64 next_gen(void) {
    sqlite3_int64 g = (sqlite3_int64) time(NULL);
    if (g <= gGenLast) g = gGenLast + 1;
    gGenLast = g;
    return g;
}

/* Phase A (fast): Start Menu + UWP + syscmds + every covered priority location,
 * one transaction, then the tier-0 prune. The catalog is useful after this. */
static void do_scan_fast(Writer *w, Stats *st, char *fast[], int nfast) {
    w->gen = next_gen();
    int intx = (sqlite3_exec(w->db, "BEGIN", NULL, NULL, NULL) == SQLITE_OK);
    if (!intx) st->errors++;
    scan_start_menu(w, st);
    scan_apps_folder(w, st);
    seed_system_commands(w, st);
    scan_prio(w, st, fast, nfast);
    if (!stop_requested() && st->errors == 0) {
        /* tier-0 prune: rows of fast kinds not re-stamped this generation are
         * gone. NEVER prune after an errored scan (un-stamped healthy rows). */
        sqlite3_stmt *p = NULL;
        if (sqlite3_prepare_v2(w->db,
                "DELETE FROM catalog WHERE updated_at < ?1 AND"
                " (kind IN ('shortcut','uwp','system_cmd')"
                "  OR (kind IN ('file','folder') AND tier=0))", -1, &p, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(p, 1, w->gen);
            if (sqlite3_step(p) != SQLITE_DONE) st->errors++;
            sqlite3_finalize(p);
        } else st->errors++;
    }
    if (intx && sqlite3_exec(w->db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) st->errors++;
    meta_stamp(w, st, "last_full_scan_ts");
}

/* Phase B (bulk): the throttled remainder of every root. Batched transactions
 * (walk_pace commits between batches); background CPU/IO priority when bg=1
 * (the indexer thread — never the GUI thread on a sync scan). The tier-1 prune
 * runs ONLY after a complete, error-free, un-aborted walk. */
static void do_scan_bulk(Writer *w, Stats *st, char *slow[], int nslow,
                         char *fast[], int nfast, int bg) {
    int sleepMs, batch;
    EnterCriticalSection(&gLock);
    sleepMs = gBulkSleepMs; batch = gBulkBatch;
    LeaveCriticalSection(&gLock);
    sqlite3_int64 bulkGen = next_gen();
    w->gen = bulkGen;
    DWORD t0 = GetTickCount();
    if (bg) SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_BEGIN);
    int intx = (sqlite3_exec(w->db, "BEGIN", NULL, NULL, NULL) == SQLITE_OK);
    if (!intx) st->errors++;
    int ok = scan_bulk(w, st, slow, nslow, fast, nfast, sleepMs, batch);
    if (intx && sqlite3_exec(w->db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) st->errors++;
    if (bg) SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_END);
    if (ok && !stop_requested() && st->errors == 0) {
        sqlite3_stmt *p = NULL;
        if (sqlite3_prepare_v2(w->db,
                "DELETE FROM catalog WHERE kind IN ('file','folder') AND tier=1"
                " AND updated_at < ?1", -1, &p, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(p, 1, bulkGen);
            if (sqlite3_step(p) != SQLITE_DONE) st->errors++;
            sqlite3_finalize(p);
        } else st->errors++;
    }
    st->bulk_done = ok && !stop_requested();
    st->bulk_ms = (int)(GetTickCount() - t0);
    if (st->bulk_done) meta_stamp(w, st, "last_bulk_scan_ts");
    /* Fold the WAL back UNCONDITIONALLY.  The bulk phase writes inside a single
       transaction, so the WAL necessarily grows to the whole write set; a scan
       that was STOPPED or that errored consumed just as much of it as one that
       finished.  Gating this on bulk_done stranded that WAL -- hundreds of MB --
       until the next *successful* full scan happened to run. */
    sqlite3_exec(w->db, "PRAGMA wal_checkpoint(TRUNCATE)", NULL, NULL, NULL);
}

/* the sync (test/tool) path: both phases, no notifies, no background mode */
static void do_scan(Writer *w, Stats *st) {
    memset(st, 0, sizeof *st);
    char *roots[ANN_ROOTS_MAX]; int pr[ANN_ROOTS_MAX]; int nroots = 0;
    roots_snapshot(roots, pr, &nroots);
    char *fast[ANN_ROOTS_MAX], *slow[ANN_ROOTS_MAX];
    int nfast = 0, nslow = 0;
    for (int i = 0; i < nroots; i++) {
        if (pr[i]) fast[nfast++] = roots[i]; else slow[nslow++] = roots[i];
    }
    do_scan_fast(w, st, fast, nfast);
    if (!stop_requested()) do_scan_bulk(w, st, slow, nslow, fast, nfast, 0);
    for (int i = 0; i < nroots; i++) Tcl_Free(roots[i]);
}

static Tcl_Obj *stats_dict(Tcl_Interp *ip, const Stats *st) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("lnk_found", -1),    Tcl_NewIntObj(st->lnk_found));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("lnk_resolved", -1), Tcl_NewIntObj(st->lnk_resolved));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("lnk_cached", -1),   Tcl_NewIntObj(st->lnk_cached));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("uwp_found", -1),    Tcl_NewIntObj(st->uwp_found));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("files_found", -1),  Tcl_NewIntObj(st->files_found));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("files_prio", -1),   Tcl_NewIntObj(st->files_prio));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("files_bulk", -1),   Tcl_NewIntObj(st->files_bulk));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("capped_prio", -1),  Tcl_NewIntObj(st->capped_prio));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("capped_bulk", -1),  Tcl_NewIntObj(st->capped_bulk));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("bulk_done", -1),    Tcl_NewIntObj(st->bulk_done));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("bulk_aborted", -1), Tcl_NewIntObj(st->bulk_aborted));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("bulk_ms", -1),      Tcl_NewIntObj(st->bulk_ms));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("errors", -1),       Tcl_NewIntObj(st->errors));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("phase", -1),        Tcl_NewIntObj(st->phase));
    return d;
}

/* ---- GUI notification (kind 0 = catalog updated, 1 = config changed) -------- */
typedef struct { Tcl_Event ev; int kind; } NotifyEvent;
static int NotifyProc(Tcl_Event *e, int flags) {
    (void) flags;
    NotifyEvent *ne = (NotifyEvent *) e;
    Tcl_Obj *cb = (ne->kind == 1) ? gNotifyCfg : gNotify;
    if (gInterp && cb) {
        if (Tcl_EvalObjEx(gInterp, cb, TCL_EVAL_GLOBAL) != TCL_OK)
            Tcl_BackgroundException(gInterp, TCL_ERROR);
    }
    return 1;
}
static void notify_gui(int kind) {
    if (!gGui) return;
    NotifyEvent *e = (NotifyEvent *) Tcl_Alloc(sizeof(NotifyEvent));
    e->ev.proc = NotifyProc; e->ev.nextPtr = NULL; e->kind = kind;
    Tcl_ThreadQueueEvent(gGui, (Tcl_Event *) e, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(gGui);
}

/* ---- frecency write (DESIGN §6.4): new = old*exp(-l*dt) + 1 ------------------ */
static int record_usage(Writer *w, sqlite3_int64 id, long long now) {
    int ok = 1;
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(w->db, "INSERT INTO usage_events(catalog_id,ts,weight) VALUES(?1,?2,1.0)", -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(s, 1, id); sqlite3_bind_int64(s, 2, now);
        if (sqlite3_step(s) != SQLITE_DONE) ok = 0;
        sqlite3_finalize(s);
    } else ok = 0;
    double old = 0; long long lts = 0; int have = 0; s = NULL;
    if (sqlite3_prepare_v2(w->db, "SELECT decayed_score,last_event_ts FROM frecency WHERE catalog_id=?1", -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(s, 1, id);
        if (sqlite3_step(s) == SQLITE_ROW) { old = sqlite3_column_double(s, 0); lts = sqlite3_column_int64(s, 1); have = 1; }
        sqlite3_finalize(s);
    } else ok = 0;
    double lambda;
    EnterCriticalSection(&gLock); lambda = gFrecLambda; LeaveCriticalSection(&gLock);
    double nv = 1.0;
    if (have) { double dt = (double)(now - lts); if (dt < 0) dt = 0; nv = old * exp(-lambda * dt) + 1.0; }
    s = NULL;
    if (sqlite3_prepare_v2(w->db, "INSERT INTO frecency(catalog_id,decayed_score,last_event_ts) VALUES(?1,?2,?3)"
        " ON CONFLICT(catalog_id) DO UPDATE SET decayed_score=excluded.decayed_score,last_event_ts=excluded.last_event_ts",
        -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(s, 1, id); sqlite3_bind_double(s, 2, nv); sqlite3_bind_int64(s, 3, now);
        if (sqlite3_step(s) != SQLITE_DONE) ok = 0;
        sqlite3_finalize(s);
    } else ok = 0;
    return ok;
}

/* ---- targeted file events from the watcher -----------------------------------
 * The fresh on-disk state is the ONLY truth: a path that stats is upserted, a
 * path that doesn't is deleted — the queued add/remove flag is deliberately
 * ignored (stale flags after rapid create/delete/recreate sequences must never
 * delete a file that exists). Deleting a folder also deletes its indexed
 * children; a NEW folder triggers a full rescan to pick its children up. */

/* does any path component (after the drive) start with a dot? (mirror of the
 * walk_files filter, so the watcher can't index inside .git etc.) */
static int has_dot_component(const char *path) {
    for (const char *p = path; *p; p++) {
        if ((*p == '\\' || *p == '/') && p[1] == '.') return 1;
    }
    return 0;
}

/* returns the number of rows actually changed — the caller only notifies the
 * GUI when something material happened (churn that the allow/deny filters
 * dropped must not re-query the popup every 200ms during a bulk walk) */
static int apply_file_events(Writer *w) {
    FileEv evs[ANN_FILEQ_MAX]; int n;
    EnterCriticalSection(&gLock);
    n = gFileQN;
    memcpy(evs, gFileQ, (size_t) n * sizeof(FileEv));
    gFileQN = 0;
    LeaveCriticalSection(&gLock);
    if (n == 0) return 0;
    int changed = 0;
    char *prio[ANN_ROOTS_MAX];
    int nprio = roots_prio_snapshot(prio);   /* priority-ON folders tier the events */
    int errors = 0;
    int intx = (sqlite3_exec(w->db, "BEGIN", NULL, NULL, NULL) == SQLITE_OK);
    for (int i = 0; i < n; i++) {
        wchar_t *wp = utf8_to_wide(evs[i].path);
        DWORD attrs = wp ? GetFileAttributesW(wp) : INVALID_FILE_ATTRIBUTES;
        if (attrs == INVALID_FILE_ATTRIBUTES) {
            sqlite3_reset(w->del);
            sqlite3_bind_text(w->del, 1, evs[i].path, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(w->del) != SQLITE_DONE) errors++;
            changed += sqlite3_changes(w->db);
            /* a renamed/removed DIRECTORY leaves children behind: delete every
             * row under it (substr match — no LIKE-wildcard pitfalls) */
            sqlite3_stmt *kids = NULL;
            if (sqlite3_prepare_v2(w->db,
                    "DELETE FROM catalog WHERE kind IN ('file','folder')"
                    " AND substr(path, 1, length(?1) + 1) = ?1 || '\\'",
                    -1, &kids, NULL) == SQLITE_OK) {
                sqlite3_bind_text(kids, 1, evs[i].path, -1, SQLITE_TRANSIENT);
                if (sqlite3_step(kids) != SQLITE_DONE) errors++;
                changed += sqlite3_changes(w->db);
                sqlite3_finalize(kids);
            } else errors++;
        } else if (!(attrs & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM))
                   && !has_dot_component(evs[i].path)) {
            const char *base = strrchr(evs[i].path, '\\');
            base = base ? base + 1 : evs[i].path;
            if (base[0] != '.' && !has_denied_component(evs[i].path)) {
                WIN32_FILE_ATTRIBUTE_DATA fad;
                sqlite3_int64 mt = 0;
                if (GetFileAttributesExW(wp, GetFileExInfoStandard, &fad))
                    mt = filetime_to_unix(&fad.ftLastWriteTime);
                int isdir = (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
                int tier = tier_for_path(evs[i].path, prio, nprio);
                if (isdir || tier == 0 || allow_ext(base)) {
                    if (!writer_upsert_tier(w, evs[i].path, base,
                                            isdir ? "folder" : "file", "path",
                                            NULL, "", mt, tier)) errors++;
                    else changed++;
                    if (isdir) {
                        /* index the new folder's CHILDREN inline (bounded) —
                         * never escalate one moved tree into a whole-disk
                         * rescan (the old behavior; storm-prone on C:\) */
                        Stats sub; memset(&sub, 0, sizeof sub);
                        Walk wk = { .w = w, .st = &sub, .tier = tier,
                                    .maxDepth = tier ? ANN_BULK_DEPTH : ANN_PRIO_DEPTH,
                                    .budget = 2000 };
                        walk_tree(&wk, wp, 1);
                        errors += sub.errors;
                    }
                }
            }
        }
        if (wp) Tcl_Free((char *) wp);
        Tcl_Free(evs[i].path);
    }
    if (intx) sqlite3_exec(w->db, "COMMIT", NULL, NULL, NULL);
    EnterCriticalSection(&gLock);
    gLastStats.errors += errors;
    LeaveCriticalSection(&gLock);
    for (int i = 0; i < nprio; i++) Tcl_Free(prio[i]);
    return changed;
}

/* ---- the indexer thread ------------------------------------------------------ */
/* The thread's full scan: fast phase -> publish -> (maybe) bulk -> publish.
 * The bulk walk runs on explicit/forced requests (start, set_roots, rescan)
 * always; on implicit ones (watcher overflow) only past the cooldown — a churn
 * storm on a whole-drive root must not re-walk the disk in a loop. */
static sqlite3_int64  gLastBulkTs = 0;   /* writer thread only */
static volatile LONG  gBulkForce  = 1;   /* the initial scan is always full */

static void scan_publish(const Stats *st) {
    EnterCriticalSection(&gLock); gLastStats = *st; LeaveCriticalSection(&gLock);
    notify_gui(0);
}

static void thread_full_scan(Writer *w, Stats *st) {
    memset(st, 0, sizeof *st);
    char *roots[ANN_ROOTS_MAX]; int pr[ANN_ROOTS_MAX]; int nroots = 0;
    roots_snapshot(roots, pr, &nroots);
    char *fast[ANN_ROOTS_MAX], *slow[ANN_ROOTS_MAX];
    int nfast = 0, nslow = 0;
    for (int i = 0; i < nroots; i++) {
        if (pr[i]) fast[nfast++] = roots[i]; else slow[nslow++] = roots[i];
    }
    /* phase is LIVE state for the GUI's LED: 1 while the priority scan runs,
     * 2 while the background walk runs, 0 idle — published at each boundary */
    st->phase = 1;
    scan_publish(st);
    do_scan_fast(w, st, fast, nfast);
    int force = (InterlockedExchange(&gBulkForce, 0) != 0);
    sqlite3_int64 cd;
    EnterCriticalSection(&gLock); cd = gBulkCooldownS; LeaveCriticalSection(&gLock);
    int willBulk = (!stop_requested()
                    && (force || (sqlite3_int64) time(NULL) - gLastBulkTs >= cd));
    st->phase = willBulk ? 2 : 0;
    scan_publish(st);                       /* the popup is useful right now */
    if (willBulk) {
        do_scan_bulk(w, st, slow, nslow, fast, nfast, 1);
        /* stamp ATTEMPTS, not just completions: an event storm that aborts the
         * walk must not thrash full re-walks back to back; the timed resume in
         * the thread loop finishes an aborted walk after the cooldown */
        gLastBulkTs = (sqlite3_int64) time(NULL);
        st->phase = 0;
        scan_publish(st);
    }
    for (int i = 0; i < nroots; i++) Tcl_Free(roots[i]);
}

static Tcl_ThreadCreateType IdxThreadProc(ClientData cd) {
    (void) cd;
    Writer w;
    gReadyOk = writer_open(&w, gDbPath);
    HRESULT hco = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    SetEvent(gReady);
    if (!gReadyOk) {
        writer_close(&w);                      /* close the partial connection too */
        if (SUCCEEDED(hco)) CoUninitialize();
        SetEvent(gDone);
        TCL_THREAD_CREATE_RETURN;
    }

    Stats st;
    InterlockedExchange(&gBulkForce, 1);       /* a fresh thread always walks fully */
    thread_full_scan(&w, &st);
    int pendingBulk = !st.bulk_done;           /* aborted/skipped: resume later */

    HANDLE waits[4] = { gStop, gWork, gUsage, gFileEvt };
    for (;;) {
        DWORD tmo = INFINITE;
        if (pendingBulk) {
            sqlite3_int64 cd;
            EnterCriticalSection(&gLock); cd = gBulkCooldownS; LeaveCriticalSection(&gLock);
            tmo = (DWORD)(cd * 1000) + 1000;
        }
        DWORD r = WaitForMultipleObjects(4, waits, FALSE, tmo);
        if (r == WAIT_OBJECT_0) break;                 /* gStop */
        if (r == WAIT_OBJECT_0 + 1 || r == WAIT_TIMEOUT) {  /* rescan / bulk resume */
            thread_full_scan(&w, &st);
            pendingBulk = !st.bulk_done;
        } else if (r == WAIT_OBJECT_0 + 2) {           /* gUsage: launch events */
            sqlite3_int64 ids[ANN_USAGE_QMAX]; int n;
            EnterCriticalSection(&gLock);
            n = gUsageN; if (n > ANN_USAGE_QMAX) n = ANN_USAGE_QMAX;
            memcpy(ids, gUsageQ, (size_t) n * sizeof(sqlite3_int64));
            gUsageN = 0;
            LeaveCriticalSection(&gLock);
            long long now = (long long) time(NULL);
            int errors = 0;
            int intx = (sqlite3_exec(w.db, "BEGIN", NULL, NULL, NULL) == SQLITE_OK);
            for (int i = 0; i < n; i++) if (!record_usage(&w, ids[i], now)) errors++;
            if (intx) sqlite3_exec(w.db, "COMMIT", NULL, NULL, NULL);
            if (errors) { EnterCriticalSection(&gLock); gLastStats.errors += errors; LeaveCriticalSection(&gLock); }
            notify_gui(0);
        } else if (r == WAIT_OBJECT_0 + 3) {           /* gFileEvt: targeted updates */
            if (apply_file_events(&w) > 0) notify_gui(0);
        } else {
            break;        /* WAIT_FAILED / unexpected: never spin (finding #33) */
        }
    }
    if (SUCCEEDED(hco)) CoUninitialize();
    writer_close(&w);
    SetEvent(gDone);
    TCL_THREAD_CREATE_RETURN;
}

/* ---- the watcher thread (ReadDirectoryChangesW over IOCP, DESIGN §7.2) ------- */
typedef struct {
    HANDLE hDir;
    OVERLAPPED ov;
    DWORD buf[ANN_WATCH_BUF / 4];     /* DWORD-aligned, <64KB (network-share rule) */
    wchar_t *rootW;                   /* Tcl_Alloc'd */
    int recursive;                    /* 0 for the config dir */
} WatchEnt;

#define ANN_WATCH_MAX (ANN_ROOTS_MAX + 1)
#define ANN_WKEY_STOP ((ULONG_PTR) 0xFFFF)

static int watch_issue(WatchEnt *e) {
    return ReadDirectoryChangesW(e->hDir, e->buf, sizeof e->buf, e->recursive,
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE,
        NULL, &e->ov, NULL);
}

static Tcl_ThreadCreateType WatchThreadProc(ClientData cd) {
    (void) cd;
    /* HEAP: 17 entries x ~60KB buffers ≈ 1 MB — never on a default thread stack */
    WatchEnt *ents = (WatchEnt *) Tcl_Alloc(sizeof(WatchEnt) * ANN_WATCH_MAX);
    int nents = 0;
    memset(ents, 0, sizeof(WatchEnt) * ANN_WATCH_MAX);

    /* snapshot the roots (the watcher watches ALL folders, both tiers) */
    char *roots[ANN_ROOTS_MAX]; int rpr[ANN_ROOTS_MAX]; int nroots = 0;
    roots_snapshot(roots, rpr, &nroots);
    char cfgdir[1024] = ""; char cfgtail[260] = "";
    EnterCriticalSection(&gLock);
    if (gCfgPath[0]) {
        /* Tcl hands paths with FORWARD slashes; accept either separator */
        const char *bs = strrchr(gCfgPath, '\\');
        const char *fs = strrchr(gCfgPath, '/');
        if (fs > bs) bs = fs;
        if (bs) {
            size_t dl = (size_t)(bs - gCfgPath);
            if (dl < sizeof cfgdir) { memcpy(cfgdir, gCfgPath, dl); cfgdir[dl] = 0; }
            snprintf(cfgtail, sizeof cfgtail, "%s", bs + 1);
        }
    }
    LeaveCriticalSection(&gLock);

    for (int i = 0; i < nroots + (cfgdir[0] ? 1 : 0); i++) {
        const char *dir = (i < nroots) ? roots[i] : cfgdir;
        wchar_t *wd = utf8_to_wide(dir);
        HANDLE h = CreateFileW(wd, FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            WatchEnt *e = &ents[nents];
            e->hDir = h;
            e->rootW = wd;
            e->recursive = (i < nroots);
            if (CreateIoCompletionPort(h, gWatchIocp, (ULONG_PTR) nents, 0) && watch_issue(e)) {
                nents++;
            } else {
                CloseHandle(h); Tcl_Free((char *) wd); e->hDir = NULL; e->rootW = NULL;
            }
        } else {
            Tcl_Free((char *) wd);
        }
    }
    for (int i = 0; i < nroots; i++) Tcl_Free(roots[i]);

    int dirtyFull = 0, dirtyFiles = 0, dirtyCfg = 0;
    DWORD quietStart = 0;
    DWORD lastFullSignal = 0;     /* overflow->rescan rate limit (see below) */
    for (;;) {
        DWORD bytes = 0; ULONG_PTR key = 0; OVERLAPPED *ov = NULL;
        BOOL ok = GetQueuedCompletionStatus(gWatchIocp, &bytes, &key, &ov, 120);
        if (ok && key == ANN_WKEY_STOP) break;
        if (!ok && ov == NULL) {
            /* timeout tick: flush if quiet for >=200ms */
            if ((dirtyFull || dirtyFiles || dirtyCfg) && GetTickCount() - quietStart >= 200) {
                if (dirtyCfg)  { notify_gui(1); dirtyCfg = 0; }
                /* an overflow-triggered rescan fires AT MOST once a minute: the
                 * rescan's own WAL writes can overflow the 60KB RDC buffer
                 * again, and an unthrottled signal loops scans forever (seen
                 * live). dirtyFull stays pending and fires after the window. */
                if (dirtyFull && GetTickCount() - lastFullSignal >= 60000) {
                    /* the rescan supersedes any queued targeted events — drop
                     * them, or stale entries would be applied AFTER the rescan */
                    EnterCriticalSection(&gLock);
                    for (int qi = 0; qi < gFileQN; qi++) Tcl_Free(gFileQ[qi].path);
                    gFileQN = 0;
                    LeaveCriticalSection(&gLock);
                    SetEvent(gWork); dirtyFull = 0; dirtyFiles = 0;
                    lastFullSignal = GetTickCount();
                } else if (!dirtyFull && dirtyFiles) { SetEvent(gFileEvt); dirtyFiles = 0; }
            }
            continue;
        }
        if (key >= (ULONG_PTR) nents) continue;
        WatchEnt *e = &ents[key];
        if (!e->hDir) continue;                       /* entry already marked dead */
        quietStart = GetTickCount();
        if (!ok || bytes == 0) {
            /* overflow (or error): everything may have been dropped -> full rescan */
            dirtyFull = 1;
            if (!watch_issue(e)) {                    /* root gone/unmounted: entry dies */
                CloseHandle(e->hDir); e->hDir = NULL;
            }
            continue;
        }
        /* parse FILE_NOTIFY_INFORMATION chain */
        BYTE *p = (BYTE *) e->buf;
        for (;;) {
            FILE_NOTIFY_INFORMATION *fni = (FILE_NOTIFY_INFORMATION *) p;
            int nameChars = (int)(fni->FileNameLength / sizeof(wchar_t));
            wchar_t *rel = (wchar_t *) Tcl_Alloc(((size_t) nameChars + 1) * sizeof(wchar_t));
            memcpy(rel, fni->FileName, fni->FileNameLength);
            rel[nameChars] = 0;
            if (!e->recursive) {
                /* config dir: only the config file itself matters */
                char *u = wide_to_utf8(rel);
                if (cfgtail[0] && _stricmp(u, cfgtail) == 0) dirtyCfg = 1;
                Tcl_Free(u);
            } else {
                wchar_t *full = path_join(e->rootW, rel);
                if (full) {
                    char *u = wide_to_utf8(full);
                    /* churn under deny-listed dirs (Temp, caches, Windows, …)
                     * never reaches the queue — a whole-drive root would flood
                     * it otherwise and degrade into rescan loops */
                    if (has_denied_component(u) || is_self_path(u)) {
                        Tcl_Free(u); Tcl_Free((char *) full); Tcl_Free((char *) rel);
                        if (fni->NextEntryOffset == 0) break;
                        p += fni->NextEntryOffset;
                        continue;
                    }
                    int remove = (fni->Action == FILE_ACTION_REMOVED ||
                                  fni->Action == FILE_ACTION_RENAMED_OLD_NAME);
                    EnterCriticalSection(&gLock);
                    if (gFileQN < ANN_FILEQ_MAX) {
                        gFileQ[gFileQN].path = u;
                        gFileQ[gFileQN].remove = remove;
                        gFileQN++;
                        u = NULL;                  /* queue owns it now */
                    } else {
                        dirtyFull = 1;             /* queue full -> degrade to rescan */
                    }
                    LeaveCriticalSection(&gLock);
                    if (u) Tcl_Free(u);
                    Tcl_Free((char *) full);
                    dirtyFiles = 1;
                } else {
                    dirtyFull = 1;
                }
            }
            Tcl_Free((char *) rel);
            if (fni->NextEntryOffset == 0) break;
            p += fni->NextEntryOffset;
        }
        /* MUST re-issue after each completion; a failed re-arm means the root is
         * gone — request a covering rescan and retire the entry (never silent) */
        if (!watch_issue(e)) {
            dirtyFull = 1;
            CloseHandle(e->hDir); e->hDir = NULL;
        }
    }

    for (int i = 0; i < nents; i++) {
        if (ents[i].hDir) { CancelIo(ents[i].hDir); CloseHandle(ents[i].hDir); }
        if (ents[i].rootW) Tcl_Free((char *) ents[i].rootW);
    }
    Tcl_Free((char *) ents);
    SetEvent(gWatchDone);
    TCL_THREAD_CREATE_RETURN;
}

static int watcher_start(void) {
    if (gWatchActive) return 1;
    gWatchIocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
    gWatchDone = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!gWatchIocp || !gWatchDone) return 0;
    if (Tcl_CreateThread(&gWatchThread, WatchThreadProc, NULL,
                         TCL_THREAD_STACK_DEFAULT, TCL_THREAD_NOFLAGS) != TCL_OK) {
        CloseHandle(gWatchIocp); gWatchIocp = NULL;
        CloseHandle(gWatchDone); gWatchDone = NULL;
        return 0;
    }
    gWatchActive = 1;
    return 1;
}

/* returns 1 = stopped clean, 0 = timeout (caller must wedge) */
static int watcher_stop(void) {
    if (!gWatchActive) return 1;
    PostQueuedCompletionStatus(gWatchIocp, 0, ANN_WKEY_STOP, NULL);
    int ok = (WaitForSingleObject(gWatchDone, 3000) == WAIT_OBJECT_0);
    if (ok) {
        CloseHandle(gWatchIocp); gWatchIocp = NULL;
        CloseHandle(gWatchDone); gWatchDone = NULL;
        gWatchThread = NULL;
        gWatchActive = 0;
    }
    return ok;
}

/* ---- commands (GUI thread) ---------------------------------------------------- */
static int Idx_Scan(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "dbpath"); return TCL_ERROR; }
    if (gIdxThread) {       /* single-writer invariant (DESIGN §3.2, finding #30) */
        Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer running; use annindex::rescan", -1));
        return TCL_ERROR;
    }
    Writer w;
    if (!writer_open(&w, Tcl_GetString(objv[1]))) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer: writer open/schema failed", -1));
        writer_close(&w); return TCL_ERROR;
    }
    HRESULT hco = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    Stats st; do_scan(&w, &st);
    if (SUCCEEDED(hco)) CoUninitialize();
    writer_close(&w);
    EnterCriticalSection(&gLock); gLastStats = st; LeaveCriticalSection(&gLock);
    Tcl_SetObjResult(ip, stats_dict(ip, &st));
    return TCL_OK;
}

/* purge OUR queued-but-unserviced notify events: after a stop they are stale and
 * would masquerade as the NEXT instance's "scan complete" (a real ordering bug
 * found by the suite: a leftover notify made a fresh search run on a half-built
 * catalog). Runs on the GUI thread, which owns the queue. */
static int notify_purge_proc(Tcl_Event *e, ClientData cd) {
    (void) cd;
    return e->proc == NotifyProc;
}

static void idx_release_all(void) {
    Tcl_DeleteEvents(notify_purge_proc, NULL);
    if (gStop)    { CloseHandle(gStop);    gStop = NULL; }
    if (gWork)    { CloseHandle(gWork);    gWork = NULL; }
    if (gUsage)   { CloseHandle(gUsage);   gUsage = NULL; }
    if (gFileEvt) { CloseHandle(gFileEvt); gFileEvt = NULL; }
    if (gReady)   { CloseHandle(gReady);   gReady = NULL; }
    if (gDone)    { CloseHandle(gDone);    gDone = NULL; }
    if (gNotify)    { Tcl_DecrRefCount(gNotify);    gNotify = NULL; }
    if (gNotifyCfg) { Tcl_DecrRefCount(gNotifyCfg); gNotifyCfg = NULL; }
    gIdxThread = NULL;
}

static int Idx_Start(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3 && objc != 5) {
        Tcl_WrongNumArgs(ip, 1, objv, "dbpath notifyProc ?configPath configNotifyProc?");
        return TCL_ERROR;
    }
    if (gWedged)   { Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer wedged (earlier handshake timeout); restart ann", -1)); return TCL_ERROR; }
    if (gIdxThread) { Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer already started", -1)); return TCL_ERROR; }
    snprintf(gDbPath, sizeof gDbPath, "%s", Tcl_GetString(objv[1]));
    gCfgPath[0] = 0;
    gGui = Tcl_GetCurrentThread(); gInterp = ip;
    if (gNotify) Tcl_DecrRefCount(gNotify);
    gNotify = objv[2]; Tcl_IncrRefCount(gNotify);
    if (gNotifyCfg) { Tcl_DecrRefCount(gNotifyCfg); gNotifyCfg = NULL; }
    if (objc == 5) {
        snprintf(gCfgPath, sizeof gCfgPath, "%s", Tcl_GetString(objv[3]));
        gNotifyCfg = objv[4]; Tcl_IncrRefCount(gNotifyCfg);
    }
    gReadyOk = 0;                            /* reset BEFORE the thread can write */
    gStop    = CreateEventW(NULL, TRUE, FALSE, NULL);
    gWork    = CreateEventW(NULL, FALSE, FALSE, NULL);
    gUsage   = CreateEventW(NULL, FALSE, FALSE, NULL);
    gFileEvt = CreateEventW(NULL, FALSE, FALSE, NULL);
    gReady   = CreateEventW(NULL, TRUE, FALSE, NULL);
    gDone    = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (Tcl_CreateThread(&gIdxThread, IdxThreadProc, NULL, TCL_THREAD_STACK_DEFAULT,
                         TCL_THREAD_NOFLAGS) != TCL_OK) {
        idx_release_all();
        Tcl_SetObjResult(ip, Tcl_NewStringObj("Tcl_CreateThread failed", -1));
        return TCL_ERROR;
    }
    DWORD wr = WaitForSingleObject(gReady, 15000);
    if (wr != WAIT_OBJECT_0) {
        /* unknown worker state: ask it to stop, never close handles under it */
        SetEvent(gStop);
        gWedged = 1;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer start timed out; subsystem wedged", -1));
        return TCL_ERROR;
    }
    if (!gReadyOk) {
        DWORD wd = WaitForSingleObject(gDone, 3000);
        if (wd != WAIT_OBJECT_0) { gWedged = 1;
            Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer open failed and worker did not exit; wedged", -1));
            return TCL_ERROR; }
        idx_release_all();
        Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer: writer open/schema failed", -1));
        return TCL_ERROR;
    }
    /* the watcher is best-effort: failure to watch never blocks indexing */
    watcher_start();
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Idx_Rescan(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    if (gWedged) { Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer wedged", -1)); return TCL_ERROR; }
    if (!gIdxThread) { Tcl_SetObjResult(ip, Tcl_NewStringObj("indexer not started", -1)); return TCL_ERROR; }
    InterlockedExchange(&gBulkForce, 1);   /* an explicit rescan ignores the cooldown */
    SetEvent(gWork);
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Idx_Stop(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    if (gWedged) { Tcl_SetObjResult(ip, Tcl_NewStringObj("stop-timeout", -1)); return TCL_OK; }
    if (!gIdxThread) { Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1)); return TCL_OK; }
    int watcherOk = watcher_stop();
    /* even when the watcher wedges, the (healthy) indexer must still be asked to
     * exit, or it would hold the writer connection for the life of the process
     * with no remaining stop path */
    SetEvent(gStop);
    if (WaitForSingleObject(gDone, 15000) != WAIT_OBJECT_0) {
        gWedged = 1;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("stop-timeout", -1));
        return TCL_OK;
    }
    if (!watcherOk) {
        /* indexer is down cleanly; only the watcher resources are orphaned.
         * Purge queued notifies + release callbacks, keep events leaked, and
         * wedge so a restart (which would recreate events the orphan could
         * alias) is refused. */
        Tcl_DeleteEvents(notify_purge_proc, NULL);
        if (gNotify)    { Tcl_DecrRefCount(gNotify);    gNotify = NULL; }
        if (gNotifyCfg) { Tcl_DecrRefCount(gNotifyCfg); gNotifyCfg = NULL; }
        gIdxThread = NULL;
        gWedged = 1;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("stop-timeout (watcher)", -1));
        return TCL_OK;
    }
    idx_release_all();
    /* drain any file events the watcher queued after the writer exited */
    EnterCriticalSection(&gLock);
    for (int i = 0; i < gFileQN; i++) Tcl_Free(gFileQ[i].path);
    gFileQN = 0;
    LeaveCriticalSection(&gLock);
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Idx_Active(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(gIdxThread != NULL && !gWedged));
    return TCL_OK;
}

static int Idx_Stats(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    Stats st;
    EnterCriticalSection(&gLock); st = gLastStats; LeaveCriticalSection(&gLock);
    Tcl_SetObjResult(ip, stats_dict(ip, &st));
    return TCL_OK;
}

static int Idx_RecordUsage(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "catalog_id"); return TCL_ERROR; }
    if (!gIdxThread || gWedged) { Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1)); return TCL_OK; }
    Tcl_WideInt id;
    if (Tcl_GetWideIntFromObj(ip, objv[1], &id) != TCL_OK) return TCL_ERROR;
    EnterCriticalSection(&gLock);
    if (gUsageN < ANN_USAGE_QMAX) gUsageQ[gUsageN++] = (sqlite3_int64) id;
    LeaveCriticalSection(&gLock);
    SetEvent(gUsage);
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Idx_SetRoots(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    /* set_roots <pathsList> ?priosList? — parallel lists; a missing/short prio
     * list means priority OFF (user-added folders default to the slow tier) */
    (void) cd;
    if (objc < 2 || objc > 3) { Tcl_WrongNumArgs(ip, 1, objv, "rootsList ?priosList?"); return TCL_ERROR; }
    Tcl_Size n, np = 0;
    Tcl_Obj **elems, **pels = NULL;
    if (Tcl_ListObjGetElements(ip, objv[1], &n, &elems) != TCL_OK) return TCL_ERROR;
    if (objc == 3 && Tcl_ListObjGetElements(ip, objv[2], &np, &pels) != TCL_OK) return TCL_ERROR;
    if (n > ANN_ROOTS_MAX) n = ANN_ROOTS_MAX;
    EnterCriticalSection(&gLock);
    for (int i = 0; i < gRootsN; i++) { Tcl_Free(gRoots[i]); gRoots[i] = NULL; }
    gRootsN = 0;
    gRootsSet = 1;
    for (Tcl_Size i = 0; i < n; i++) {
        const char *s = Tcl_GetString(elems[i]);
        char *cp = (char *) Tcl_Alloc(strlen(s) + 1);
        /* canonical backslashes: every catalog path derives from a root, so the
         * stored form must be slash-stable no matter how Tcl spelled it */
        for (size_t j = 0; ; j++) { cp[j] = (s[j] == '/') ? '\\' : s[j]; if (!s[j]) break; }
        int pv = 0;
        if (i < np) { Tcl_GetIntFromObj(NULL, pels[i], &pv); pv = (pv != 0); }
        gRootsPrio[gRootsN] = pv;
        gRoots[gRootsN++] = cp;
    }
    LeaveCriticalSection(&gLock);
    /* rewatch + rescan when running. A watcher that fails to stop keeps feeding
     * events for the OLD roots — that is the wedge condition (same policy as
     * stop): refuse further use rather than serve stale state. */
    if (gIdxThread && !gWedged) {
        if (!watcher_stop()) {
            gWedged = 1;
            Tcl_SetObjResult(ip, Tcl_NewStringObj("set_roots: watcher wedged", -1));
            return TCL_ERROR;
        }
        /* drop events queued for the old roots before the rescan */
        EnterCriticalSection(&gLock);
        for (int i = 0; i < gFileQN; i++) Tcl_Free(gFileQ[i].path);
        gFileQN = 0;
        LeaveCriticalSection(&gLock);
        watcher_start();
        InterlockedExchange(&gBulkForce, 1);   /* new roots: re-walk everything */
        SetEvent(gWork);
    }
    return TCL_OK;
}

static int Idx_GetRoots(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    /* returns {path prio} pairs — the Settings dialog round-trips these */
    (void) cd; (void) objc; (void) objv;
    char *roots[ANN_ROOTS_MAX]; int pr[ANN_ROOTS_MAX]; int n = 0;
    roots_snapshot(roots, pr, &n);
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    for (int i = 0; i < n; i++) {
        Tcl_Obj *pair = Tcl_NewListObj(0, NULL);
        Tcl_ListObjAppendElement(ip, pair, Tcl_NewStringObj(roots[i], -1));
        Tcl_ListObjAppendElement(ip, pair, Tcl_NewIntObj(pr[i]));
        Tcl_ListObjAppendElement(ip, l, pair);
        Tcl_Free(roots[i]);
    }
    Tcl_SetObjResult(ip, l);
    return TCL_OK;
}

static int Idx_Tune(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc == 2) {           /* compat: tune <halflife_days> */
        double days;
        if (Tcl_GetDoubleFromObj(ip, objv[1], &days) != TCL_OK) return TCL_ERROR;
        if (days < 0.01 || days > 3650) { Tcl_SetObjResult(ip, Tcl_NewStringObj("halflife out of range", -1)); return TCL_ERROR; }
        EnterCriticalSection(&gLock);
        gFrecLambda = 0.69314718055994531 / (days * 86400.0);
        LeaveCriticalSection(&gLock);
        return TCL_OK;
    }
    if (objc == 3) {           /* tune <key> <value> — bulk pacing knobs */
        const char *key = Tcl_GetString(objv[1]);
        int v;
        if (Tcl_GetIntFromObj(ip, objv[2], &v) != TCL_OK) return TCL_ERROR;
        if (v < 0 || v > 1000000) { Tcl_SetObjResult(ip, Tcl_NewStringObj("value out of range", -1)); return TCL_ERROR; }
        EnterCriticalSection(&gLock);
        if      (strcmp(key, "bulk_sleep") == 0)    gBulkSleepMs   = v;
        else if (strcmp(key, "bulk_batch") == 0)    gBulkBatch     = v;
        else if (strcmp(key, "bulk_cooldown") == 0) gBulkCooldownS = v;
        else if (strcmp(key, "prio_each") == 0 && v > 0) gPrioEach  = v;
        else {
            LeaveCriticalSection(&gLock);
            Tcl_SetObjResult(ip, Tcl_NewStringObj("unknown tune key (bulk_sleep|bulk_batch|bulk_cooldown|prio_each)", -1));
            return TCL_ERROR;
        }
        LeaveCriticalSection(&gLock);
        return TCL_OK;
    }
    Tcl_WrongNumArgs(ip, 1, objv, "halflife_days | key value");
    return TCL_ERROR;
}

/* annindex::drives — the fixed disks (the default roots), e.g. {C:\} */
static int Idx_Drives(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    DWORD mask = GetLogicalDrives();
    for (int c = 0; c < 26; c++) {
        if (!(mask & (1u << c))) continue;
        wchar_t r[4] = { (wchar_t)(L'A' + c), L':', L'\\', 0 };
        if (GetDriveTypeW(r) == DRIVE_FIXED) {
            char *u = wide_to_utf8(r);
            Tcl_ListObjAppendElement(ip, l, Tcl_NewStringObj(u, -1));
            Tcl_Free(u);
        }
    }
    Tcl_SetObjResult(ip, l);
    return TCL_OK;
}

/* annindex::priority_paths — the resolved, existing tier-0 locations (Settings
 * uses this for the coverage hint; the scan filters by root coverage itself) */
static int Idx_PriorityPaths(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    char *prio[ANN_PRIO_MAX];
    int n = prio_snapshot(prio);
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    for (int i = 0; i < n; i++) {
        Tcl_ListObjAppendElement(ip, l, Tcl_NewStringObj(prio[i], -1));
        Tcl_Free(prio[i]);
    }
    Tcl_SetObjResult(ip, l);
    return TCL_OK;
}


int Annindex_Init(Tcl_Interp *ip) {
#ifdef USE_TCL_STUBS
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
#endif
    if (!gLockInit) { InitializeCriticalSection(&gLock); gLockInit = 1; }
    Tcl_CreateNamespace(ip, "::annindex", NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::scan",         Idx_Scan,        NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::start",        Idx_Start,       NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::rescan",       Idx_Rescan,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::stop",         Idx_Stop,        NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::active",       Idx_Active,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::stats",        Idx_Stats,       NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::record_usage", Idx_RecordUsage, NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::set_roots",    Idx_SetRoots,    NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::get_roots",    Idx_GetRoots,    NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::tune",         Idx_Tune,        NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::drives",       Idx_Drives,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annindex::priority_paths", Idx_PriorityPaths, NULL, NULL);
    Tcl_PkgProvideEx(ip, "annindex", "0.1", NULL);
    return TCL_OK;
}

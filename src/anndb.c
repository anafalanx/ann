/*
 * anndb.c -- SQLite bridge for ann: the read/query side used by the GUI thread,
 * plus schema + upsert helpers used by tests. (The indexer's single WRITER
 * connection lives on its own thread in annindex.c; readers use a WAL snapshot and
 * never block it -- DESIGN §3.2.)
 *
 * Connection handles are validated indices into a small fixed table, so a bad
 * token from Tcl can never deref a wild pointer.
 *
 * Commands:
 *   anndb::version                                  -> linked SQLite version
 *   anndb::selftest                                 -> FTS5 + math smoke (M0)
 *   anndb::normalize <str>                          -> the shared index/query fold
 *   anndb::open <path> ?-readonly?                  -> connection handle
 *   anndb::schema <conn>                            -> create the schema (idempotent)
 *   anndb::exec <conn> <sql>                        -> run SQL (no result rows)
 *   anndb::upsert <conn> <path> <name> <kind> <launch_kind> <target> <keywords> <src_mtime>
 *   anndb::search <conn> <query> ?<limit>?          -> list of result dicts
 *   anndb::count <conn> ?<kind>?                    -> row count
 *   anndb::meta <conn> <key> ?<value>?             -> get/set app_meta
 *   anndb::close <conn>
 *
 * Compiled INTO ann.exe (ANN_STATIC_DB) and as a dev stubs .dll (x build-ext).
 */

#include <tcl.h>
#include "sqlite3.h"
#include "ann_norm.h"
#include "ann_schema.h"
#include "ann_fuzzy.h"
#include <string.h>
#include <stdlib.h>
#include <time.h>

/* ---- M0 smoke (kept) ------------------------------------------------------ */
static int Db_Version(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    Tcl_SetObjResult(ip, Tcl_NewStringObj(sqlite3_libversion(), -1));
    return TCL_OK;
}

static int Db_Selftest(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    sqlite3 *db = NULL; char *err = NULL;
    if (sqlite3_open(":memory:", &db)) { if (db) sqlite3_close(db);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("sqlite3_open failed", -1)); return TCL_ERROR; }
    if (sqlite3_exec(db,
        "CREATE VIRTUAL TABLE cat USING fts5(name, tokenize='trigram case_sensitive 0');"
        "INSERT INTO cat(name) VALUES('Google Chrome'),('Visual Studio Code'),('Notepad');",
        NULL, NULL, &err)) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("fts5 setup failed: %s", err ? err : "?"));
        sqlite3_free(err); sqlite3_close(db); return TCL_ERROR;
    }
    int matchCount = -1; const char *matchName = "";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT count(*),coalesce(max(name),'') FROM cat WHERE cat MATCH 'chr'",
            -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW) {
        matchCount = sqlite3_column_int(st, 0);
        matchName  = (const char *) sqlite3_column_text(st, 1);
    }
    Tcl_Obj *nameObj = Tcl_NewStringObj(matchName ? matchName : "", -1);
    Tcl_IncrRefCount(nameObj);
    if (st) sqlite3_finalize(st);
    double exp0 = -1.0; st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT exp(0.0)", -1, &st, NULL) == SQLITE_OK
        && sqlite3_step(st) == SQLITE_ROW) exp0 = sqlite3_column_double(st, 0);
    if (st) sqlite3_finalize(st);
    int threadsafe = sqlite3_threadsafe();
    sqlite3_close(db);
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("version", -1), Tcl_NewStringObj(sqlite3_libversion(), -1));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("threadsafe", -1), Tcl_NewIntObj(threadsafe));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fts5_match", -1), Tcl_NewIntObj(matchCount));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fts5_name", -1), nameObj);
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("exp0", -1), Tcl_NewDoubleObj(exp0));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("ok", -1),
                   Tcl_NewBooleanObj(matchCount == 1 && exp0 == 1.0 && threadsafe != 0));
    Tcl_DecrRefCount(nameObj);
    Tcl_SetObjResult(ip, d);
    return TCL_OK;
}

/* ---- normalization (shared with the indexer) ------------------------------ */
static int Db_Normalize(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "str"); return TCL_ERROR; }
    Tcl_Size n; const char *s = Tcl_GetStringFromObj(objv[1], &n);
    int cap = (int) n * 4 + 8;
    char *buf = (char *) Tcl_Alloc(cap);
    ann_normalize(s, buf, cap);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(buf, -1));
    Tcl_Free(buf);
    return TCL_OK;
}

/* ---- connection table ----------------------------------------------------- */
#define ANN_MAXCONN 8
static sqlite3 *gConn[ANN_MAXCONN];

static sqlite3 *conn_get(Tcl_Interp *ip, Tcl_Obj *o) {
    int idx;
    if (Tcl_GetIntFromObj(ip, o, &idx) != TCL_OK) return NULL;
    if (idx < 0 || idx >= ANN_MAXCONN || gConn[idx] == NULL) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("invalid db connection", -1));
        return NULL;
    }
    return gConn[idx];
}

static int Db_Open(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 2 || objc > 3) { Tcl_WrongNumArgs(ip, 1, objv, "path ?-readonly?"); return TCL_ERROR; }
    int ro = (objc == 3 && strcmp(Tcl_GetString(objv[2]), "-readonly") == 0);
    int slot = -1;
    for (int i = 0; i < ANN_MAXCONN; i++) if (gConn[i] == NULL) { slot = i; break; }
    if (slot < 0) { Tcl_SetObjResult(ip, Tcl_NewStringObj("too many open connections", -1)); return TCL_ERROR; }
    sqlite3 *db = NULL;
    int flags = ro ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    if (sqlite3_open_v2(Tcl_GetString(objv[1]), &db, flags, NULL) != SQLITE_OK) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("open failed: %s", db ? sqlite3_errmsg(db) : "?"));
        if (db) sqlite3_close(db);
        return TCL_ERROR;
    }
    sqlite3_busy_timeout(db, 3000);
    /* WAL is a persistent DB property; setting it on a writer is enough. On a
     * read-only handle these may be no-ops/errors, which we ignore. */
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA foreign_keys=ON;", NULL, NULL, NULL);
    gConn[slot] = db;
    Tcl_SetObjResult(ip, Tcl_NewIntObj(slot));
    return TCL_OK;
}

static int Db_Close(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "conn"); return TCL_ERROR; }
    int idx;
    if (Tcl_GetIntFromObj(ip, objv[1], &idx) != TCL_OK) return TCL_ERROR;
    if (idx >= 0 && idx < ANN_MAXCONN && gConn[idx]) {
        sqlite3_close(gConn[idx]); gConn[idx] = NULL;
    }
    return TCL_OK;
}

static int Db_Schema(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "conn"); return TCL_ERROR; }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    char *err = NULL;
    if (sqlite3_exec(db, ANN_SCHEMA_SQL, NULL, NULL, &err) != SQLITE_OK) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("schema: %s", err ? err : "?"));
        sqlite3_free(err); return TCL_ERROR;
    }
    /* migrate a pre-tier DB in place (only possible failure: duplicate column) */
    if (sqlite3_exec(db, "ALTER TABLE catalog ADD COLUMN tier INTEGER NOT NULL DEFAULT 0",
                     NULL, NULL, &err) != SQLITE_OK) sqlite3_free(err);
    return TCL_OK;
}

static int Db_Exec(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "conn sql"); return TCL_ERROR; }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    char *err = NULL;
    if (sqlite3_exec(db, Tcl_GetString(objv[2]), NULL, NULL, &err) != SQLITE_OK) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("exec: %s", err ? err : "?"));
        sqlite3_free(err); return TCL_ERROR;
    }
    return TCL_OK;
}

/* upsert: conn path name kind launch_kind target keywords src_mtime */
static int Db_Upsert(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 9) {
        Tcl_WrongNumArgs(ip, 1, objv, "conn path name kind launch_kind target keywords src_mtime");
        return TCL_ERROR;
    }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    const char *path = Tcl_GetString(objv[2]);
    const char *name = Tcl_GetString(objv[3]);
    const char *kind = Tcl_GetString(objv[4]);
    const char *lk   = Tcl_GetString(objv[5]);
    const char *tgt  = Tcl_GetString(objv[6]);
    const char *kw   = Tcl_GetString(objv[7]);
    Tcl_WideInt mtime = 0; Tcl_GetWideIntFromObj(NULL, objv[8], &mtime);

    /* search_text = normalize(name ' ' target ' ' keywords) */
    Tcl_Size rawcap = (Tcl_Size) strlen(name) + strlen(tgt) + strlen(kw) + 4;
    char *raw = (char *) Tcl_Alloc(rawcap);
    snprintf(raw, rawcap, "%s %s %s", name, tgt, kw);
    int ncap = (int) rawcap * 4 + 8;
    char *st = (char *) Tcl_Alloc(ncap);
    ann_normalize(raw, st, ncap);
    Tcl_Free(raw);

    /* RETURNING id: correct on BOTH the insert and the update branch (a plain
     * last_insert_rowid() is stale when the conflict/UPDATE path is taken). */
    static const char *SQL =
        "INSERT INTO catalog(path,display_name,kind,launch_kind,target,search_text,keywords,enabled,updated_at,source_mtime)"
        " VALUES(?1,?2,?3,?4,?5,?6,?7,1,unixepoch(),?8)"
        " ON CONFLICT(path) DO UPDATE SET display_name=excluded.display_name,kind=excluded.kind,"
        " launch_kind=excluded.launch_kind,target=excluded.target,search_text=excluded.search_text,"
        " keywords=excluded.keywords,enabled=1,updated_at=excluded.updated_at,source_mtime=excluded.source_mtime"
        " RETURNING id";
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, SQL, -1, &s, NULL) != SQLITE_OK) {
        Tcl_Free(st); Tcl_SetObjResult(ip, Tcl_ObjPrintf("upsert prepare: %s", sqlite3_errmsg(db))); return TCL_ERROR;
    }
    sqlite3_bind_text(s, 1, path, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 3, kind, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 4, lk,   -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 5, tgt,  -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 6, st,   -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 7, kw,   -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(s, 8, (sqlite3_int64) mtime);
    int rc = sqlite3_step(s);
    sqlite3_int64 rowid = (rc == SQLITE_ROW) ? sqlite3_column_int64(s, 0) : 0;
    if (rc == SQLITE_ROW) rc = sqlite3_step(s);                /* drain to DONE */
    sqlite3_finalize(s);
    Tcl_Free(st);
    if (rc != SQLITE_DONE) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("upsert: %s", sqlite3_errmsg(db))); return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(rowid));
    return TCL_OK;
}

/* build a result dict (id name path kind launch target score) from the current row */
static Tcl_Obj *make_row(Tcl_Interp *ip, sqlite3_stmt *s, double score) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("id", -1),     Tcl_NewWideIntObj(sqlite3_column_int64(s, 0)));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("name", -1),   Tcl_NewStringObj((const char *) sqlite3_column_text(s, 1), -1));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("path", -1),   Tcl_NewStringObj((const char *) sqlite3_column_text(s, 2), -1));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("kind", -1),   Tcl_NewStringObj((const char *) sqlite3_column_text(s, 3), -1));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("launch", -1), Tcl_NewStringObj((const char *) sqlite3_column_text(s, 4), -1));
    const unsigned char *tg = sqlite3_column_text(s, 5);
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("target", -1), Tcl_NewStringObj(tg ? (const char *) tg : "", -1));
    Tcl_DictObjPut(ip, d, Tcl_NewStringObj("score", -1),  Tcl_NewDoubleObj(score));
    if (sqlite3_column_count(s) > 9)
        Tcl_DictObjPut(ip, d, Tcl_NewStringObj("tier", -1), Tcl_NewIntObj(sqlite3_column_int(s, 9)));
    return d;
}

/* anndb::fuzzy <query> <candidate> -> the fzy score (the C scorer, exposed for tests) */
static int Db_Fuzzy(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "query candidate"); return TCL_ERROR; }
    Tcl_Size qn; const char *q = Tcl_GetStringFromObj(objv[1], &qn);
    int ncap = (int) qn * 4 + 8;
    char *nq = (char *) Tcl_Alloc(ncap);
    ann_normalize(q, nq, ncap);
    double sc = ann_fuzzy_score(nq, Tcl_GetString(objv[2]));
    Tcl_Free(nq);
    Tcl_SetObjResult(ip, Tcl_NewDoubleObj(sc));
    return TCL_OK;
}

/* anndb::get <conn> <path> -> one result dict (or empty) -- used by the alias pin */
static int Db_Get(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "conn path"); return TCL_ERROR; }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "SELECT id,display_name,path,kind,launch_kind,target,"
                               "0,0,search_text,tier FROM catalog"
                               " WHERE path=?1 AND enabled=1", -1, &s, NULL) != SQLITE_OK) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("get prepare: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }
    sqlite3_bind_text(s, 1, Tcl_GetString(objv[2]), -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(s);
    if (rc == SQLITE_ROW) Tcl_SetObjResult(ip, make_row(ip, s, ANN_SCORE_MAX));
    sqlite3_finalize(s);
    if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("get: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }
    return TCL_OK;
}

/* blend parameters — config-tunable via anndb::tune (GUI thread only) */
static double gLambda = ANN_FREC_LAMBDA;
static double gNormK  = ANN_FREC_K;
static double gWFuzzy = ANN_W_FUZZY;
static double gWFrec  = ANN_W_FREC;
static double gWTier  = 0.25;      /* additive bonus for tier-0 rows (§7.2) */

/* anndb::tune key value ?key value ...? — keys: halflife (days), k, wfuzzy, wfrec */
static int Db_Tune(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 3 || (objc % 2) == 0) { Tcl_WrongNumArgs(ip, 1, objv, "key value ?key value ...?"); return TCL_ERROR; }
    for (int i = 1; i + 1 < objc; i += 2) {
        const char *k = Tcl_GetString(objv[i]);
        double v;
        if (Tcl_GetDoubleFromObj(ip, objv[i + 1], &v) != TCL_OK) return TCL_ERROR;
        if (strcmp(k, "halflife") == 0) {
            if (v < 0.01 || v > 3650) { Tcl_SetObjResult(ip, Tcl_NewStringObj("halflife out of range", -1)); return TCL_ERROR; }
            gLambda = 0.69314718055994531 / (v * 86400.0);
        } else if (strcmp(k, "k") == 0) {
            if (v <= 0) { Tcl_SetObjResult(ip, Tcl_NewStringObj("k must be > 0", -1)); return TCL_ERROR; }
            gNormK = v;
        } else if (strcmp(k, "wfuzzy") == 0) {
            gWFuzzy = v;
        } else if (strcmp(k, "wfrec") == 0) {
            gWFrec = v;
        } else if (strcmp(k, "tier_bonus") == 0) {
            gWTier = v;
        } else {
            Tcl_SetObjResult(ip, Tcl_ObjPrintf("unknown tune key \"%s\"", k));
            return TCL_ERROR;
        }
    }
    return TCL_OK;
}

typedef struct { double final; Tcl_Obj *dict; } Cand;
static int cand_cmp(const void *a, const void *b) {
    double fa = ((const Cand *) a)->final, fb = ((const Cand *) b)->final;
    return (fa < fb) ? 1 : ((fa > fb) ? -1 : 0);    /* descending by final */
}
#define ANN_CAND_CAP 1024

/* search: conn query ?limit? -- the full pipeline (DESIGN §6):
 *   FTS5 trigram (>=3) / LIKE prefix (1-2) / all (empty)   -> candidate set
 *   C fzy subsequence score (vs the display NAME) + frecency query-time re-decay
 *   + blend (W_FUZZY*fuzzy + W_FREC*norm(frec)), sorted by `final` desc, top
 *   `limit`. Source-priority bucketing + alias pin are the Tcl caller's job
 *   (ann::rank). Each dict carries `score` and `kind` for that. */
static int Db_Search(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 3 || objc > 4) { Tcl_WrongNumArgs(ip, 1, objv, "conn query ?limit?"); return TCL_ERROR; }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    int limit = 50;
    if (objc == 4 && Tcl_GetIntFromObj(ip, objv[3], &limit) != TCL_OK) return TCL_ERROR;

    Tcl_Size qn; const char *q = Tcl_GetStringFromObj(objv[2], &qn);
    int ncap = (int) qn * 4 + 8;
    char *nq = (char *) Tcl_Alloc(ncap);
    int nlen = ann_normalize(q, nq, ncap);
    /* DESIGN §6.1 stage [0]: lowercase + TRIM + fold. Trim whitespace here so a
     * trailing space can never become a required match character. */
    while (nlen > 0 && (nq[nlen - 1] == ' ' || nq[nlen - 1] == '\t')) nq[--nlen] = 0;
    int lead = 0;
    while (nq[lead] == ' ' || nq[lead] == '\t') lead++;
    if (lead) { memmove(nq, nq + lead, (size_t) nlen - lead + 1); nlen -= lead; }

    /* cols: 0 id 1 name 2 path 3 kind 4 launch 5 target 6 decayed 7 last_ts
     *       8 search_text 9 tier */
#define ANN_SEL_COLS \
    "SELECT c.id,c.display_name,c.path,c.kind,c.launch_kind,c.target," \
    "coalesce(f.decayed_score,0),coalesce(f.last_event_ts,0),c.search_text,c.tier"

    /* Tiered candidate recall (DESIGN §7.2 amendment): the tier-0 corpus is
     * small and keeps FULL subsequence recall at every query length; the bulk
     * tier (up to ~150k rows) is recalled by FTS5 trigram MATCH (>=3 chars,
     * substring semantics) or a cheap prefix LIKE (1-2 chars, fails per row at
     * the first byte). An empty query never surfaces tier-1 rows unless they
     * have frecency — 150k unranked files must not flood the candidate cap. */
    sqlite3_stmt *stmts[2] = { NULL, NULL };
    int nst = 0, rc = SQLITE_OK;
    if (nlen == 0) {
        rc = sqlite3_prepare_v2(db,
            ANN_SEL_COLS
            " FROM catalog c LEFT JOIN frecency f ON f.catalog_id=c.id"
            " WHERE c.enabled=1 AND (c.tier=0 OR f.decayed_score>0) LIMIT ?1",
            -1, &stmts[0], NULL);
        if (rc == SQLITE_OK) { sqlite3_bind_int(stmts[0], 1, ANN_CAND_CAP); nst = 1; }
    } else {
        /* normalized CHAR count (trigram needs 3 characters, not bytes) */
        int nchars = 0;
        for (int i = 0; i < nlen; nchars++) {
            unsigned char c = (unsigned char) nq[i];
            i += (c < 0x80) ? 1 : ((c >> 5) == 0x6) ? 2 : ((c >> 4) == 0xE) ? 3
               : ((c >> 3) == 0x1E) ? 4 : 1;
        }
        /* [0] tier 0 — SUBSEQUENCE prefilter %c1%c2%...%cN% over search_text,
         * so vsc -> Visual Studio Code is recalled; the C fzy scorer ranks.
         * Built per CODEPOINT: '%' must never split a multi-byte sequence
         * (SQLite LIKE walks codepoints; a split sequence can never match). */
        char *pat = (char *) Tcl_Alloc((size_t) nlen * 3 + 4);
        int o = 0; pat[o++] = '%';
        for (int i = 0; i < nlen; ) {
            unsigned char c = (unsigned char) nq[i];
            if (c < 0x80) {
                if (c == '%' || c == '_' || c == '\\') pat[o++] = '\\';
                pat[o++] = (char) c; i++;
            } else {
                int len = ((c >> 5) == 0x6) ? 2 : ((c >> 4) == 0xE) ? 3 : ((c >> 3) == 0x1E) ? 4 : 1;
                for (int j = 0; j < len && i < nlen; j++) pat[o++] = nq[i++];
            }
            pat[o++] = '%';
        }
        pat[o] = 0;
        rc = sqlite3_prepare_v2(db,
            ANN_SEL_COLS
            " FROM catalog c LEFT JOIN frecency f ON f.catalog_id=c.id"
            " WHERE c.enabled=1 AND c.tier=0 AND c.search_text LIKE ?1 ESCAPE '\\' LIMIT ?2",
            -1, &stmts[0], NULL);
        if (rc == SQLITE_OK) {
            sqlite3_bind_text(stmts[0], 1, pat, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmts[0], 2, ANN_CAND_CAP);
            nst = 1;
        }
        Tcl_Free(pat);

        /* [1] tier 1 — trigram MATCH from the >=3-char tokens of the query */
        char *match = NULL;
        if (rc == SQLITE_OK && nchars >= 3) {
            match = (char *) Tcl_Alloc((size_t) nlen * 2 + 16);
            int mo = 0, any = 0;
            for (int i = 0; i < nlen; ) {
                while (i < nlen && nq[i] == ' ') i++;
                int s0 = i, chars = 0;
                int qo = mo + (any ? 1 : 0) + 1;     /* would-be token start */
                (void) qo;
                while (i < nlen && nq[i] != ' ') {
                    unsigned char c = (unsigned char) nq[i];
                    i += (c < 0x80) ? 1 : ((c >> 5) == 0x6) ? 2 : ((c >> 4) == 0xE) ? 3
                       : ((c >> 3) == 0x1E) ? 4 : 1;
                    chars++;
                }
                if (chars >= 3) {
                    if (any) match[mo++] = ' ';
                    match[mo++] = '"';
                    for (int j = s0; j < i; j++) {
                        if (nq[j] == '"') match[mo++] = '"';   /* fts escaping */
                        match[mo++] = nq[j];
                    }
                    match[mo++] = '"';
                    any = 1;
                }
            }
            match[mo] = 0;
            if (!any) { Tcl_Free(match); match = NULL; }
        }
        if (rc == SQLITE_OK && match) {
            rc = sqlite3_prepare_v2(db,
                ANN_SEL_COLS
                " FROM catalog_fts JOIN catalog c ON c.id=catalog_fts.rowid"
                " LEFT JOIN frecency f ON f.catalog_id=c.id"
                " WHERE catalog_fts MATCH ?1 AND c.enabled=1 AND c.tier=1 LIMIT ?2",
                -1, &stmts[1], NULL);
            if (rc == SQLITE_OK) {
                sqlite3_bind_text(stmts[1], 1, match, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int(stmts[1], 2, ANN_CAND_CAP);
                nst = 2;
            }
            Tcl_Free(match);
        } else if (rc == SQLITE_OK) {
            /* 1-2 chars (or no >=3-char token): prefix recall into the bulk
             * tier — a subsequence this short would match half the disk */
            char *pre = (char *) Tcl_Alloc((size_t) nlen * 2 + 4);
            int po = 0;
            for (int i = 0; i < nlen; i++) {
                if (nq[i] == '%' || nq[i] == '_' || nq[i] == '\\') pre[po++] = '\\';
                pre[po++] = nq[i];
            }
            pre[po++] = '%'; pre[po] = 0;
            rc = sqlite3_prepare_v2(db,
                ANN_SEL_COLS
                " FROM catalog c LEFT JOIN frecency f ON f.catalog_id=c.id"
                " WHERE c.enabled=1 AND c.tier=1 AND c.search_text LIKE ?1 ESCAPE '\\' LIMIT ?2",
                -1, &stmts[1], NULL);
            if (rc == SQLITE_OK) {
                sqlite3_bind_text(stmts[1], 1, pre, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int(stmts[1], 2, ANN_CAND_CAP);
                nst = 2;
            }
            Tcl_Free(pre);
        }
    }
    if (rc != SQLITE_OK) {
        Tcl_Free(nq);
        for (int i = 0; i < 2; i++) if (stmts[i]) sqlite3_finalize(stmts[i]);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("search prepare: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }

    long long now = (long long) time(NULL);
    Cand *arr = (Cand *) Tcl_Alloc(ANN_CAND_CAP * sizeof(Cand));
    int k = 0;
    for (int si = 0; si < nst; si++) {
    sqlite3_stmt *s = stmts[si];
    while (k < ANN_CAND_CAP && sqlite3_step(s) == SQLITE_ROW) {
        const char *name = (const char *) sqlite3_column_text(s, 1);
        double fuzzy = 0.0;
        if (nlen > 0) {
            /* score against the FOLDED name (diacritic+case): keeps "resume" matching
             * "Résumé" and preserves word-boundary bonuses (CamelCase is lost, an
             * acceptable trade since folding is what makes accents reachable).
             * Heap-sized fold buffer: a long name must never truncate away the
             * part the prefilter matched. */
            size_t namelen = strlen(name ? name : "");
            int fcap = (int) namelen * 4 + 8;
            char *foldname = (char *) Tcl_Alloc(fcap);
            ann_normalize(name ? name : "", foldname, fcap);
            fuzzy = ann_fuzzy_score(nq, foldname);
            Tcl_Free(foldname);
            if (fuzzy <= ANN_SCORE_MIN) {
                /* the prefilter recalled this row via target/keywords: score the
                 * stored (already-folded) search_text with a fixed penalty so
                 * name matches still outrank target-only matches (finding #22). */
                const char *st = (const char *) sqlite3_column_text(s, 8);
                if (st) fuzzy = ann_fuzzy_score(nq, st);
                if (fuzzy <= ANN_SCORE_MIN) continue;          /* no subsequence anywhere */
                fuzzy -= 2.0;
            }
        }
        double anchor = sqlite3_column_double(s, 6);
        double frec = 0.0;
        if (anchor > 0.0) {
            double dt = (double)(now - (long long) sqlite3_column_int64(s, 7));
            if (dt < 0) dt = 0;
            frec = anchor * exp(-gLambda * dt);     /* query-time re-decay, §6.4 */
        }
        double normf = frec / (frec + gNormK);
        double fin   = (nlen > 0) ? (gWFuzzy * fuzzy + gWFrec * normf) : normf;
        /* priority-location rows outrank equal deep-disk rows (§7.2) */
        if (nlen > 0 && sqlite3_column_int(s, 9) == 0) fin += gWTier;
        Tcl_Obj *d = make_row(ip, s, fin);
        Tcl_IncrRefCount(d);
        arr[k].final = fin; arr[k].dict = d; k++;
    }
    }
    for (int si = 0; si < 2; si++) if (stmts[si]) sqlite3_finalize(stmts[si]);
    Tcl_Free(nq);

    qsort(arr, (size_t) k, sizeof(Cand), cand_cmp);
    Tcl_Obj *list = Tcl_NewListObj(0, NULL);
    for (int i = 0; i < k && i < limit; i++) Tcl_ListObjAppendElement(ip, list, arr[i].dict);
    for (int i = 0; i < k; i++) Tcl_DecrRefCount(arr[i].dict);   /* list keeps its own refs */
    Tcl_Free((char *) arr);
    Tcl_SetObjResult(ip, list);
    return TCL_OK;
}

static int Db_Count(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 2 || objc > 3) { Tcl_WrongNumArgs(ip, 1, objv, "conn ?kind?"); return TCL_ERROR; }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    sqlite3_stmt *s = NULL;
    int rc;
    if (objc == 3) {
        rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM catalog WHERE kind=?1", -1, &s, NULL);
        if (rc == SQLITE_OK) sqlite3_bind_text(s, 1, Tcl_GetString(objv[2]), -1, SQLITE_TRANSIENT);
    } else {
        rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM catalog", -1, &s, NULL);
    }
    if (rc != SQLITE_OK) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("count prepare: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }
    int n = 0;
    rc = sqlite3_step(s);
    if (rc == SQLITE_ROW) n = sqlite3_column_int(s, 0);
    sqlite3_finalize(s);
    if (rc != SQLITE_ROW) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("count: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewIntObj(n));
    return TCL_OK;
}

static int Db_Meta(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 3 || objc > 4) { Tcl_WrongNumArgs(ip, 1, objv, "conn key ?value?"); return TCL_ERROR; }
    sqlite3 *db = conn_get(ip, objv[1]); if (!db) return TCL_ERROR;
    sqlite3_stmt *s = NULL;
    if (objc == 4) {
        if (sqlite3_prepare_v2(db, "INSERT INTO app_meta(key,value) VALUES(?1,?2)"
                               " ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &s, NULL) != SQLITE_OK) {
            Tcl_SetObjResult(ip, Tcl_ObjPrintf("meta prepare: %s", sqlite3_errmsg(db)));
            return TCL_ERROR;
        }
        sqlite3_bind_text(s, 1, Tcl_GetString(objv[2]), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(s, 2, Tcl_GetString(objv[3]), -1, SQLITE_TRANSIENT);
        int rc = sqlite3_step(s);
        sqlite3_finalize(s);
        if (rc != SQLITE_DONE) {                    /* e.g. SQLITE_READONLY on the reader */
            Tcl_SetObjResult(ip, Tcl_ObjPrintf("meta set: %s", sqlite3_errmsg(db)));
            return TCL_ERROR;
        }
        return TCL_OK;
    }
    if (sqlite3_prepare_v2(db, "SELECT value FROM app_meta WHERE key=?1", -1, &s, NULL) != SQLITE_OK) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("meta prepare: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }
    sqlite3_bind_text(s, 1, Tcl_GetString(objv[2]), -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(s);
    if (rc == SQLITE_ROW) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj((const char *) sqlite3_column_text(s, 0), -1));
    }
    sqlite3_finalize(s);
    if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("meta get: %s", sqlite3_errmsg(db)));
        return TCL_ERROR;
    }
    return TCL_OK;
}

int Anndb_Init(Tcl_Interp *ip) {
#ifdef USE_TCL_STUBS
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
#endif
    Tcl_CreateNamespace(ip, "::anndb", NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::version",   Db_Version,   NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::selftest",  Db_Selftest,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::normalize", Db_Normalize, NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::open",      Db_Open,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::close",     Db_Close,     NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::schema",    Db_Schema,    NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::exec",      Db_Exec,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::upsert",    Db_Upsert,    NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::search",    Db_Search,    NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::fuzzy",     Db_Fuzzy,     NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::get",       Db_Get,       NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::tune",      Db_Tune,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::count",     Db_Count,     NULL, NULL);
    Tcl_CreateObjCommand(ip, "::anndb::meta",      Db_Meta,      NULL, NULL);
    Tcl_PkgProvideEx(ip, "anndb", "0.1", NULL);
    return TCL_OK;
}

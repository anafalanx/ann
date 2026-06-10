/*
 * ann_schema.h -- the durable SQLite schema (DESIGN §5.2). Created (IF NOT
 * EXISTS) by the indexer's writer connection; the GUI's read-only connection
 * only queries it. WAL/synchronous/busy_timeout/foreign_keys are connection
 * PRAGMAs set in C at open time (anndb.c), not here.
 *
 * Extensions over §5.2 for the resolved-target cache (§7.1, sanctioned as "a
 * small side column"): `target` (resolved .lnk target) and `source_mtime` (the
 * .lnk's last-write time, so an unchanged shortcut is not re-resolved on rescan).
 */
#ifndef ANN_SCHEMA_H
#define ANN_SCHEMA_H

static const char *const ANN_SCHEMA_SQL =
    "CREATE TABLE IF NOT EXISTS catalog ("
    "  id           INTEGER PRIMARY KEY,"
    "  path         TEXT    NOT NULL UNIQUE,"   /* launch key: .lnk|file|AUMID|cmd */
    "  display_name TEXT    NOT NULL,"
    "  kind         TEXT    NOT NULL,"          /* app|uwp|shortcut|file|folder|system_cmd|config */
    "  launch_kind  TEXT    NOT NULL,"          /* path|aumid|shell|tclproc */
    "  target       TEXT,"                      /* resolved .lnk target (dedup/search/icon) */
    "  icon_ref     TEXT,"
    "  search_text  TEXT    NOT NULL,"          /* ann_normalize(name||' '||target||' '||keywords) */
    "  keywords     TEXT,"
    "  enabled      INTEGER NOT NULL DEFAULT 1,"
    "  updated_at   INTEGER NOT NULL,"
    "  source_mtime INTEGER,"                   /* .lnk last-write time (rescan cache) */
    "  tier         INTEGER NOT NULL DEFAULT 0" /* 0 fast/priority, 1 bulk (§7.2) */
    ");"
    "CREATE INDEX IF NOT EXISTS ix_catalog_kind ON catalog(kind) WHERE enabled = 1;"

    "CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5("
    "  search_text, content='catalog', content_rowid='id',"
    "  tokenize='trigram case_sensitive 0'"
    ");"

    "CREATE TRIGGER IF NOT EXISTS catalog_ai AFTER INSERT ON catalog BEGIN"
    "  INSERT INTO catalog_fts(rowid, search_text) VALUES (new.id, new.search_text);"
    "END;"
    "CREATE TRIGGER IF NOT EXISTS catalog_ad AFTER DELETE ON catalog BEGIN"
    "  INSERT INTO catalog_fts(catalog_fts, rowid, search_text) VALUES('delete', old.id, old.search_text);"
    "END;"
    /* the legacy unscoped trigger re-tokenized the trigram index on EVERY row
     * update (incl. the per-scan updated_at touch) — that WAL churn fed the
     * file watcher a self-sustaining event storm on whole-drive roots */
    "DROP TRIGGER IF EXISTS catalog_au;"
    "CREATE TRIGGER IF NOT EXISTS catalog_au2 AFTER UPDATE OF search_text ON catalog BEGIN"
    "  INSERT INTO catalog_fts(catalog_fts, rowid, search_text) VALUES('delete', old.id, old.search_text);"
    "  INSERT INTO catalog_fts(rowid, search_text) VALUES (new.id, new.search_text);"
    "END;"

    "CREATE TABLE IF NOT EXISTS usage_events ("
    "  id         INTEGER PRIMARY KEY,"
    "  catalog_id INTEGER NOT NULL REFERENCES catalog(id) ON DELETE CASCADE,"
    "  ts         INTEGER NOT NULL,"
    "  weight     REAL    NOT NULL DEFAULT 1.0"
    ");"
    "CREATE INDEX IF NOT EXISTS ix_usage_catalog_ts ON usage_events(catalog_id, ts);"

    "CREATE TABLE IF NOT EXISTS frecency ("
    "  catalog_id    INTEGER PRIMARY KEY REFERENCES catalog(id) ON DELETE CASCADE,"
    "  decayed_score REAL    NOT NULL,"
    "  last_event_ts INTEGER NOT NULL"
    ");"

    "CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY, value TEXT);";

#endif /* ANN_SCHEMA_H */

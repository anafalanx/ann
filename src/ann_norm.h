/*
 * ann_norm.h -- the ONE normalization used at BOTH index time and query time
 * (DESIGN §6 stage [0], §7.2). Folding the query the same way the catalog was
 * folded is what lets an accented entry ("Résumé") match a folded query
 * ("resume"); folding only one side would make accented entries unreachable.
 *
 * Header-only static so the indexer (annindex.c) and the DB/query layer
 * (anndb.c) share exactly one implementation.
 *
 * Fold = lowercase ASCII + strip common Latin diacritics (Latin-1 Supplement and
 * a few Latin Extended-A) to their ASCII base; everything else passes through as
 * UTF-8 unchanged. Pragmatic for app/file names; not a full Unicode fold.
 */
#ifndef ANN_NORM_H
#define ANN_NORM_H

#include <stdint.h>

/* Encode a codepoint as UTF-8 into out (>=4 bytes); return byte count. */
static inline int ann_norm_utf8(uint32_t cp, char *out) {
    if (cp < 0x80) { out[0] = (char) cp; return 1; }
    if (cp < 0x800) {
        out[0] = (char) (0xC0 | (cp >> 6));
        out[1] = (char) (0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char) (0xE0 | (cp >> 12));
        out[1] = (char) (0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char) (0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char) (0xF0 | (cp >> 18));
    out[1] = (char) (0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char) (0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char) (0x80 | (cp & 0x3F));
    return 4;
}

/* Fold one codepoint; write ASCII/UTF-8 bytes into out (>=4); return count. */
static inline int ann_norm_fold_cp(uint32_t cp, char *out) {
    if (cp >= 'A' && cp <= 'Z') { out[0] = (char) (cp + 32); return 1; }
    if (cp < 0x80)              { out[0] = (char) cp;        return 1; }

    /* case-fold the major bicameral non-Latin scripts so a lowercase query can
     * reach an uppercase catalog entry (CJK has no case; review finding #5 fam.) */
    if (cp >= 0x410 && cp <= 0x42F) return ann_norm_utf8(cp + 0x20, out);  /* Cyrillic А-Я */
    if (cp >= 0x400 && cp <= 0x40F) return ann_norm_utf8(cp + 0x50, out);  /* Ѐ-Џ (incl. Ё) */
    if (cp >= 0x391 && cp <= 0x3A1) return ann_norm_utf8(cp + 0x20, out);  /* Greek Α-Ρ */
    if (cp >= 0x3A3 && cp <= 0x3AB) return ann_norm_utf8(cp + 0x20, out);  /* Greek Σ-Ϋ */

    /* Latin-1 Supplement (upper + lower share a mapping here) */
    switch (cp) {
        case 0xC0: case 0xC1: case 0xC2: case 0xC3: case 0xC4: case 0xC5:
        case 0xE0: case 0xE1: case 0xE2: case 0xE3: case 0xE4: case 0xE5:
            out[0] = 'a'; return 1;
        case 0xC6: case 0xE6: out[0] = 'a'; out[1] = 'e'; return 2;   /* Æ/æ */
        case 0xC7: case 0xE7: out[0] = 'c'; return 1;                 /* Ç/ç */
        case 0xC8: case 0xC9: case 0xCA: case 0xCB:
        case 0xE8: case 0xE9: case 0xEA: case 0xEB:
            out[0] = 'e'; return 1;
        case 0xCC: case 0xCD: case 0xCE: case 0xCF:
        case 0xEC: case 0xED: case 0xEE: case 0xEF:
            out[0] = 'i'; return 1;
        case 0xD0: case 0xF0: out[0] = 'd'; return 1;                 /* Ð/ð */
        case 0xD1: case 0xF1: out[0] = 'n'; return 1;                 /* Ñ/ñ */
        case 0xD2: case 0xD3: case 0xD4: case 0xD5: case 0xD6: case 0xD8:
        case 0xF2: case 0xF3: case 0xF4: case 0xF5: case 0xF6: case 0xF8:
            out[0] = 'o'; return 1;
        case 0xD9: case 0xDA: case 0xDB: case 0xDC:
        case 0xF9: case 0xFA: case 0xFB: case 0xFC:
            out[0] = 'u'; return 1;
        case 0xDD: case 0xFD: case 0xFF: out[0] = 'y'; return 1;      /* Ý/ý/ÿ */
        case 0xDF: out[0] = 's'; out[1] = 's'; return 2;             /* ß */
        default: break;
    }
    /* Latin Extended-A: lowercase odd/even pairs map to a small base set. A few
     * common ones; the rest pass through. */
    switch (cp) {
        case 0x141: case 0x142: out[0] = 'l'; return 1;   /* Ł/ł */
        case 0x160: case 0x161: out[0] = 's'; return 1;   /* Š/š */
        case 0x17D: case 0x17E: out[0] = 'z'; return 1;   /* Ž/ž */
        case 0x10C: case 0x10D: out[0] = 'c'; return 1;   /* Č/č */
        default: break;
    }
    /* Latin Extended-A even=upper/odd=lower pairs in 0x100..0x17F often follow
     * base-letter ranges; fall back to passing the codepoint through, lowercased
     * if it is a simple ASCII-range mapping (handled above). */
    return ann_norm_utf8(cp, out);
}

/* Normalize a UTF-8 string into out (capacity outcap incl. NUL). Returns length. */
static inline int ann_normalize(const char *in, char *out, int outcap) {
    int o = 0;
    const unsigned char *p = (const unsigned char *) in;
    while (*p && o < outcap - 1) {
        unsigned char c = *p;
        uint32_t cp; int len;
        if (c < 0x80)            { cp = c;        len = 1; }
        else if ((c >> 5) == 0x6){ cp = c & 0x1F; len = 2; }
        else if ((c >> 4) == 0xE){ cp = c & 0x0F; len = 3; }
        else if ((c >> 3) == 0x1E){cp = c & 0x07; len = 4; }
        else                     { cp = c;        len = 1; }   /* stray byte */
        for (int i = 1; i < len; i++) {
            if ((p[i] & 0xC0) == 0x80) cp = (cp << 6) | (p[i] & 0x3F);
            else { len = i; break; }
        }
        char buf[4];
        int n = ann_norm_fold_cp(cp, buf);
        for (int i = 0; i < n && o < outcap - 1; i++) out[o++] = buf[i];
        p += len;
    }
    out[o] = 0;
    return o;
}

#endif /* ANN_NORM_H */

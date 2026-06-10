/*
 * ann_fuzzy.h -- the fzy/fzf-style subsequence scorer (DESIGN §6.3, "the core
 * IP") plus the frecency blend constants (§6.4). Header-only static so anndb.c
 * (query-time scoring) and annindex.c (frecency decay on a usage event) share one
 * definition.
 *
 * A match requires every query char to appear, IN ORDER, in the candidate (gaps
 * allowed). Scoring is an O(n*m) DP (rolling rows) awarding bonuses for
 * word-boundary, CamelCase, consecutive runs, and matches near the start. The
 * query is matched case-insensitively; bonuses use the candidate's ORIGINAL case
 * (so CamelCase is detectable) — therefore score against the display NAME, not the
 * already-lowercased search_text.
 */
#ifndef ANN_FUZZY_H
#define ANN_FUZZY_H

#include <string.h>
#include <math.h>

/* fzy scoring constants */
#define ANN_SCORE_GAP_LEADING       (-0.005)
#define ANN_SCORE_GAP_TRAILING      (-0.005)
#define ANN_SCORE_GAP_INNER         (-0.01)
#define ANN_SCORE_MATCH_CONSECUTIVE (1.0)
#define ANN_SCORE_MATCH_SLASH       (0.9)
#define ANN_SCORE_MATCH_WORD        (0.8)
#define ANN_SCORE_MATCH_CAPITAL     (0.7)
#define ANN_SCORE_MATCH_DOT         (0.6)
#define ANN_SCORE_MIN               (-1e18)
#define ANN_SCORE_MAX               (1e18)
/* DP window: candidates longer than this are scored on their first MAXLEN bytes
 * (recall beyond it is covered by the caller's search_text fallback). */
#define ANN_FUZZY_MAXLEN            512

/* frecency blend (DESIGN §6.4): final = W_FUZZY*fuzzy + W_FREC*norm(frecency),
 * norm(x)=x/(x+K); halflife 14d => lambda = ln2/(14*86400). */
#define ANN_FREC_LAMBDA  (0.69314718055994531 / (14.0 * 86400.0))
#define ANN_FREC_K       (4.0)
#define ANN_W_FUZZY      (1.0)
#define ANN_W_FREC       (0.35)

static inline char ann_lc(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }

/* is q (any case) an in-order subsequence of s (any case)? */
static inline int ann_has_match(const char *q, const char *s) {
    for (; *q; q++) {
        char lq = ann_lc(*q);
        while (*s && ann_lc(*s) != lq) s++;
        if (!*s) return 0;
        s++;
    }
    return 1;
}

/* bonus for a candidate position, from the preceding char + current char (orig case) */
static inline double ann_bonus(char prev, char cur) {
    if (cur >= 'A' && cur <= 'Z' && prev >= 'a' && prev <= 'z') return ANN_SCORE_MATCH_CAPITAL;
    switch (prev) {
        case '/': case '\\': return ANN_SCORE_MATCH_SLASH;
        case ' ': case '_': case '-': return ANN_SCORE_MATCH_WORD;
        case '.': return ANN_SCORE_MATCH_DOT;
    }
    return 0.0;
}

/* fzy score; ANN_SCORE_MIN if no match, ANN_SCORE_MAX for a case-insensitive
 * exact match. q is the (normalized/lowercased) query; s the original name. */
static inline double ann_fuzzy_score(const char *q, const char *s) {
    int n = (int) strlen(q);
    int m = (int) strlen(s);
    if (n == 0) return ANN_SCORE_MIN;
    if (!ann_has_match(q, s)) return ANN_SCORE_MIN;
    if (n == m) return ANN_SCORE_MAX;
    if (m > ANN_FUZZY_MAXLEN) m = ANN_FUZZY_MAXLEN;

    double bonus[ANN_FUZZY_MAXLEN];
    for (int j = 0; j < m; j++) {
        char prev = (j == 0) ? '/' : s[j - 1];
        bonus[j] = ann_bonus(prev, s[j]);
    }
    double Dprev[ANN_FUZZY_MAXLEN], Mprev[ANN_FUZZY_MAXLEN];
    double Dcur[ANN_FUZZY_MAXLEN],  Mcur[ANN_FUZZY_MAXLEN];
    for (int i = 0; i < n; i++) {
        double prev_score = ANN_SCORE_MIN;
        double gap = (i == n - 1) ? ANN_SCORE_GAP_TRAILING : ANN_SCORE_GAP_INNER;
        char lqi = ann_lc(q[i]);
        for (int j = 0; j < m; j++) {
            if (lqi == ann_lc(s[j])) {
                double score = ANN_SCORE_MIN;
                if (i == 0) {
                    score = j * ANN_SCORE_GAP_LEADING + bonus[j];
                } else if (j > 0) {
                    double a = Mprev[j - 1] + bonus[j];                  /* new run, boundary bonus */
                    double b = Dprev[j - 1] + ANN_SCORE_MATCH_CONSECUTIVE; /* extend a run */
                    score = (a > b) ? a : b;
                }
                Dcur[j] = score;
                double t = prev_score + gap;
                Mcur[j] = prev_score = (score > t) ? score : t;
            } else {
                Dcur[j] = ANN_SCORE_MIN;
                Mcur[j] = prev_score = prev_score + gap;
            }
        }
        memcpy(Dprev, Dcur, (size_t) m * sizeof(double));
        memcpy(Mprev, Mcur, (size_t) m * sizeof(double));
    }
    return Mprev[m - 1];
}

/* frecency at query time: re-apply the single exp() decay to the stored anchor
 * (DESIGN §6.4 — never a full event re-scan). */
static inline double ann_frecency_now(double anchor, long long last_ts, long long now) {
    if (anchor <= 0.0) return 0.0;
    double dt = (double) (now - last_ts);
    if (dt < 0) dt = 0;
    return anchor * exp(-ANN_FREC_LAMBDA * dt);
}

#endif /* ANN_FUZZY_H */

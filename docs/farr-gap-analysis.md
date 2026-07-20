# FARR vs ann — what to adopt, what to keep refusing

**Basis:** FARR v2.239.01 research report (help file, mouser's forum writeups, third-party reviews) against the ann v0.5 implemented-surface inventory (DESIGN.md amendments + code); every landing note below was checked against the actual sources (`ann.tcl`, `anndb.c`, `annindex.c`, `annhotkey.c`). Framing: the owner wants "roughly the same design as FARR, though not all of FARR's features." FARR's genius is the keystroke-driven, everything-is-a-file, engineer-serving core; FARR's failure mode is twenty years of accretion (a 15-switch alias mini-language, 40 virtual launch commands, an embedded IE browser). ann should take the former and treat the latter as the anti-model — which is what the locked non-goals already do.

---

## 1. Capability matrix

Verdicts: **HAS** · **HAS BETTER** · **LACKS → adopt** (numbered into §2) · **LACKS — refuse** (§3) · **DEFERRED** (needs an owner amendment, §2 endnote) · **REJECTED** (locked non-goal).

| FARR capability | ann v0.5 status | Verdict |
|---|---|---|
| Summonable popup, global hotkey, portable folder, no registry | Alt+Space toggle, single-instance mutex, portable folder | **HAS** — shared DNA |
| Incremental ranked result list (not single-best) | Debounced 15 ms re-query, virtualized ranked list | **HAS** |
| No-index live filesystem search (launch cache as backstop) | Tiered SQLite index: subsequence-LIKE tier 0 + FTS5 trigram tier 1, watcher, background walk | **HAS BETTER** — FARR's own help opens with an antivirus-exclusion workaround and "don't panic" for first searches; ann's index dissolves the whole problem class |
| Word/substring matching, out-of-order words, whitespace-removal penalty | fzy-style per-character subsequence DP with word-boundary / CamelCase / consecutive-run bonuses | **HAS BETTER** — `vsc` → Visual Studio Code needs no configuration |
| Launch-history ranking, per-item hand-edited bonus/penalty | Frecency with exponential decay, blended with fuzzy score, tunables exposed | **HAS BETTER** — automatic what FARR makes users hand-tune |
| Three user-editable scoring layers (heuristic / pattern / history) | Frecency + fixed bucketing | **HAS BETTER** for ranking; **LACKS the exclusion half → adopt #5** (ignore globs, "hide this item") |
| Search folders with depth, order, per-folder bonus | `watched_roots {path prio}` two-tier priorities, Settings dialog | **HAS** |
| Empty-box "start with top files" (opt-in) | Empty view = strict launch history from frecency, first-run hint | **HAS BETTER** — it's the amendment-blessed default, not an option |
| Typed-search history (Ctrl+Up/Down, distinct from launch history) | Query cleared on every show; no recall | **LACKS → adopt #3** |
| Directory browsing mode (type a path, live filter, Tab completion, `c:\pro\com` smart matching) | Files/folders in index; no path mode, no completion | **LACKS → adopt #4** — the biggest genuine gap |
| Simple aliases (`ed` → editor) | `ann::alias` exact-match top-pin | **HAS**, but no partial-match recall (DESIGN §6.7 unimplemented) — fixed in **adopt #2** |
| Regex aliases / search templates / `$$1` capture / `dosearch` rewriting | `ann::provider` already receives the full query and its rows compete in ranking | **HAS via Tcl → adopt #2** — ship as a config-template recipe plus the §6.7 recall fix, not a new engine |
| `noresults` fallback (Enter on zero results → shellexec, Run-box replacement) | Zero results = dead end | **LACKS → adopt #1** |
| Selected-text capture hotkey (Ctrl+C simulated, query pre-filled) | Single hotkey, always empty query | **DEFERRED** — a second hotkey reverses the locked single-chord mechanism (DESIGN §10.1, §16); owner amendment required (§2 endnote) |
| Detailed-report mode showing computed score per result | Final blended score rides in every result dict; the component breakdown never surfaces | **LACKS → adopt #6** |
| `-word` negation | None | **LACKS → adopt #7** |
| Keyword modifiers (`+music` scopes folders/scoring) | None | **LACKS — refuse for now** (see §3; the index dissolved the problem it solved) |
| Alias action keywords (`+hexedit` verb on picked result) | Action panel (Tab/Ctrl+K), kind-scoped, config-extensible | **LACKS — refuse** — the panel *is* this feature with one syntax instead of two |
| Virtual launch strings (~40-command DSL: sendkeys, appcap, showmemo…) | `ann::run`, arbitrary Tcl in providers/actions | **HAS BETTER** — Tcl is a real language; a string mini-language inside config is the anti-model |
| `appcapresults` / `fileresults` (program stdout as result list) | `ann::provider` + Tcl `exec` covers it | **HAS** (via Tcl) — worth a documented recipe in the config template, not a feature |
| Alias pack distribution (`.alias` XML, installed vs user dirs, third-party packs) | One user-owned `ann.config.tcl`, staged load, error rollback | **HAS BETTER** for one engineer; pack *ecosystem* is plugins-adjacent — refuse |
| Live window switching | Native `EnumWindows` source, activate/close, HWND revalidation | **HAS BETTER** — FARR never had it natively (plugins only) |
| UWP/Store apps | First-class AUMID indexing + `IApplicationActivationManager` launch | **HAS BETTER** — not in evidence anywhere in FARR's docs |
| System commands | 8 seeded syscmds with destructive-confirm cascades | **HAS** (FARR's cpanel/mmc enumeration is broader; not worth chasing) |
| Config hot reload (`goreload`) | File watcher, 150 ms debounce, staged commit keeps last good config on error | **HAS BETTER** |
| Tray icon, run-as-admin, open-location, copy-path | All present (runas via panel; ERROR_CANCELLED handled) | **HAS** |
| Result list as real file list: drag-out, native shell context menu | Tk context menu, Open file location | **LACKS — refuse** (mouse-first chrome) |
| Bare digit / Alt+# / F-key result launching | None | **REJECTED** — number quick-pick is locked, and FARR's own docs document the digit-typing conflict it causes |
| Skins, per-element fonts | els-calm grey, one accent | **REJECTED** — theming locked; Slant's top FARR con is the dated look *despite* skins |
| Web search / define / email packs | None | **REJECTED** — web search locked |
| Plugin API (calculator, clipboard, bookmarks, Everything, processes, todo, Gmail-in-launcher…) | `ann::provider` / `ann::action` in Tcl, in-process, no ecosystem | **REJECTED** — plugins/marketplace, calculator, clipboard, bookmarks all locked |
| Embedded IE ActiveX HTML view | — | **LACKS — refuse**, gladly |

---

## 2. The adopt list

Filtered hard. Everything here is keyboard-first, adds no visible chrome, and lands in existing architecture without touching a locked decision. One standing rule, stated once so it can't erode: **adopt items ship without hedge toggles.** If a feature is right, it needs no off-switch; "controversial? make it an option" is exactly the accretion path that gave FARR a 15-switch alias language. (`show_scores` below survives as a debug surface, which is a different thing.)

Numbered by recommended order (§4).

### #1 Zero-results fallback: "Run: `<query>`" — **S**
**What:** FARR's `noresults` behavior — Enter on an empty result list shellexecs the query. ann's version: when a query matches nothing, show one synthetic row `Run: <query>`. No toggle; the row is inert unless you press Enter on it.
**Why:** Makes ann a full Win+R replacement — `\\server\share`, `ms-settings:display`, `winver`, anything on PATH — with zero new syntax. The CoNetrix and forum sources both treat "Run-box replacement" as core FARR value.
**Landing:** Tcl appends the synthetic row in the merge step (`ann.tcl` ~1440) when kept-results is empty and the query is non-empty. Launching hands the **raw query string** to a small C entry point doing ShellExecuteEx with Run-box-style splitting (quoted first token wins; otherwise greedy longest-existing-path prefix, remainder = params). It must never pass through Tcl list operations: a raw query with an unbalanced brace or quote throws in list parsing, and `\\server\my share` would split at the wrong boundary. Two deliberate properties: fallback launches don't enter frecency (they're not catalog items, and the `tclproc` launch arm never records usage — correct, since synthetic strings shouldn't pollute the catalog), and their recall mechanism is #3.

### #2 Parameterized aliases — shipped recipe + the §6.7 recall fix — **S**
**What:** FARR's most famous feature (`ssh build04`, `clone <url>`, `tk 4711`), delivered the way this document demands FARR's `appcapresults` be delivered: as a **documented recipe, not a mechanism**. `ann::provider` already receives the full query on every keystroke; a provider proc that matches its keyword as first token can return a row whose `-launch` runs `wt ssh $host`, and because `ann::provider_candidates` respects a caller-supplied score, even the top-pin is achievable from config today. FARR's `dosearch` menus fall out the same way — return multiple rows and let the list filter them. Core work would buy only sugar and a preview label; the document refuses FARR features on exactly those grounds, so it refuses itself the same indulgence. What ships: a worked `ssh`-style parameterized-alias block in the config template, including the subtitle-as-preview-label trick.
**The one genuine core item:** the DESIGN §6.7 alias-recall gap — a partial or typo'd alias currently gets nothing, because aliases never touch `search_text`. The `keywords` column and its upsert already exist in the indexer (`annindex.c` ~211); the missing piece is Tcl→indexer plumbing that pushes config-side alias keywords into their target's catalog row on config load. Scope honestly: this helps **catalog-backed targets only** — file-path and command-prefix aliases have no catalog row (`ann::rank` synthesizes them) and keep exact-keyword behavior. That residual is acceptable; the common case (alias → indexed app) is the one that matters.
**Landing:** config-template text + config-load marshal to the indexer thread. No new match layer, no new syntax.

### #3 Typed-query history (Ctrl+Up / Ctrl+Down) — **S**
**What:** Cycle through the last ~20 *committed* queries (query text at launch time, not every keystroke) in the entry. FARR treats this as distinct from launch history.
**Why:** Precision about the value: for ordinary 2–4-keystroke catalog queries, retyping beats recalling, and the empty-query view already *is* launch history. Query recall pays exactly where the query itself carries state the launch history can't reconstruct — parameterized alias invocations (#2) and Run-fallback strings (#1), neither of which enters frecency. That is also FARR's own case for the feature: mouser singles out re-running alias invocations. So this lands third, as the recall mechanism for what #1 and #2 create, and it composes with clear-on-show instead of fighting it — the box stays clean, recall is one chord away.
**Landing:** Flat MRU file next to ann.db — deliberately not the database, because the GUI thread's SQLite connection is read-only by design (all writes marshal through the indexer thread; `Db_Meta` itself anticipates `SQLITE_READONLY` on the reader), and a 20-line query ring does not merit that machinery. Record in the launch path (`ann.tcl` ~1536), bind Ctrl+Up/Down in the entry keymap. No UI.

### #4 Path mode: directory browsing with Tab completion — **L**
**What:** Type a rooted path → live-filtered listing of that directory; Tab autocompletes the top subdirectory into the entry; Ctrl+Backspace pops a level; the segment after the last `\` is fuzzy-filtered. FARR's smart matching (`c:\pro\com` → `C:\Program Files\Common Files`) is the stretch goal, not the requirement.
**Why:** The single most-cited FARR power feature among engineer users (kartal's daily list; directory_searching_tricks.htm has its own help chapter). Filesystem navigation at typing speed, without Explorer, is exactly "a launcher for engineers." ann indexes files but cannot *walk*.
**Landing — with the two real costs on the books:**
- **Ordering is its own branch, not free.** `ann::do_query` routes everything through `ann::rank` → `ann::bucketize`, whose fixed nature order (cmds → execs → files → dirs) would list subdirectories *last* and hoist `.exe`s above documents — backwards for browsing. Path mode bypasses rank/bucketize with its own rule: **directories first, then files; name order when the tail filter is empty, fuzzy score on the tail segment otherwise.**
- **The Tab collision is resolved by mode, deliberately.** The §9.5 amendment binds Tab/Ctrl+K to the action panel. In path mode, Tab means completion and **Ctrl+K is the only panel opener** — a documented mode exception, chosen because completion-on-Tab is a universal shell convention and path mode is unmistakably a mode (the entry starts with a rooted path). One exception, stated once, beats inventing a third chord.
- Everything else genuinely rides existing rails: enumerate via `glob`/a small C helper with a per-directory cache (the 15 ms debounce throttles); emit ordinary file/folder rows so icons and the action panel's verbs work unchanged.
This is the flagship adoption; worth being a release centerpiece.

### #5 Ignore rules + "Hide this result" — **M**
**What:** The useful half of FARR's pattern-scoring layer, inverted into ann's idiom: `ann::option ignore_globs {*/node_modules/* *.tmp *.bak}` applied at index time, plus a panel action "Hide from results" persisting a per-item exclude. No editable score numbers — hide or don't.
**Why:** Every engineer's disk has noise; frecency buries junk but can't remove it. ann currently has no way to say "never show me this again."
**Landing — three constraints that shape it:**
- **Hides live in the config, not the database.** A hidden item never appears again, so the persistence *is* the un-hide surface — it must be visible, editable, and portable. The codebase already has the precedent: the Settings dialog persists into the ONE managed block at the end of the config (`ann::settings_save`, `ann.tcl` ~2051). Hides go there. An opaque exclude table inside ann.db would contradict the one-user-owned-config ethos this document praises FARR for lacking.
- **Enforcement is index-time, not query-time.** Walk filter in `annindex.c` plus an immediate marshaled disable for already-indexed rows. `Db_Search` stays untouched — no per-query join, no per-keystroke tax; latency is the product.
- **The upsert trap, stated so nobody rediscovers it:** the indexer's ON CONFLICT clause forces `enabled=1` (`annindex.c` ~215), so a naive `enabled=0` hide silently resurrects on the next walk. The upsert must consult the exclude list; hides survive re-scans by design, not accident.

### #6 Score inspection view — **S**
**What:** FARR's detailed-report mode makes ranking debuggable. ann already puts the final blended score in every result dict; what's missing is the *component breakdown*. `ann::option show_scores 1` renders `final (fuzzy/frec/tier)` in the subtitle.
**Why:** ann exposes `weight_fuzzy`, `weight_frecency`, `frecency_norm_k` — tunables you currently tune blind. "Debuggable ranking" is the most engineer-flavored idea FARR has. Also the natural moment to expose the existing-but-hidden `tier_bonus` (inventory gap #11). `show_scores` is a debug surface for people adjusting exposed tunables, not a hedge toggle on a feature.
**Landing:** The components are already computed in `Db_Search` (`anndb.c` ~515-525); thread them through the result dict and format in the row renderer. Nearly free.

### #7 `-term` exclusion — **S**
**What:** FARR's `-word` negation, adapted: a whitespace-delimited token starting with `-` becomes a substring exclusion; remaining tokens re-join for fuzzy scoring. `foo -test` prunes test artifacts.
**Why:** Cheap precision for noisy trees, and the only piece of FARR's modifier zoo that pays for its syntax.
**Landing:** Entirely Tcl-side: pre-tokenize, strip `-terms` from the query **before it reaches `Db_Search` and the window/provider candidate calls** (all consumers must see the stripped query), then post-filter merged results. The post-filter tests `name`+`path` — result dicts carry those, not `search_text`. Require the leading space so hyphenated filenames still match; document in the config template.

### Deferred, pending owner amendment: selection-capture hotkey
A second global hotkey that simulates Ctrl+C and opens ann pre-filled with the selection is the one taste-compatible slice of FARR's multi-hotkey system, and it would multiply path mode (highlight a path, hotkey, land in the listing). It is **not on the adopt list**, for a reason this document must not blur: DESIGN §10.1 specifies "a single configurable global hotkey," and the §16 open-questions note locks it — "the mechanism (single configurable chord) is fixed regardless." Adding a second chord is a reversal of a locked mechanism, the same class of change as the tray reversal, which required an explicit owner amendment. The code agrees: `annhotkey.c` is structurally single-chord (one id, one mods/vk pair, one callback, singular rebind/wedge handshake), so this is a subsystem API widening, not an additive tweak.

Two honest failure modes belong in any amendment proposal alongside the clipboard-clobber tradeoff: simulated Ctrl+C is the same launcher-as-macro-engine mechanism §3 uses to refuse `%LASTHWND%` — the case for admitting this one species of the rejected genus (fixed, single, bounded semantics vs. open-ended scripting) is real but must be made to the owner, not smuggled; and UIPI means unelevated ann cannot inject into elevated windows, while terminals — the flagship scenario — overload Ctrl+C as interrupt. **Recommendation:** after path mode ships, if the demand is felt in practice, bring this to the owner as a §16-style amendment with all three caveats on the table. Until then it stays off the roadmap.

---

## 3. The refuse list

Locked non-goals — restated because FARR users genuinely love several of these, and the answer is still no:

- **Plugin API / marketplace** — FARR's moat *and* its bloat (Gmail-in-the-launcher); ann's extensibility budget is the Tcl config, and it is spent.
- **Web search / define / email alias packs** — locked; the parameterized-alias recipe (#2) gives users the mechanism without ann shipping the policy.
- **Calculator with tape** — locked, even though it's the single most-quoted FARR-plugin love ("cannot live without"); a tape belongs in a REPL.
- **Clipboard history search** — locked; a launcher that remembers your clipboard is a different, scarier program.
- **Browser bookmarks** — locked.
- **Bare digit / Alt+# / F-key result launching** — locked, and FARR's own docs concede the conflict by inventing `\#` escaping to work around their own feature.
- **Skins and theming** — locked; FARR proves the point: fully skinnable, and its top review complaint is still the dated look — nobody wanted skins, they wanted one good default.
- **Autostart** — locked.

FARR features refused on taste, not lock:

- **Three user-editable scoring rule layers** — frecency plus #5's hide-list achieves the outcome automatically; hand-maintained score arithmetic is homework the tool should do itself.
- **Alias action keywords (`+verb` on a picked result)** — ann's action panel already applies verbs to results; adding a second, typed syntax for the same verbs is exactly the two-ways-to-do-everything accretion that made FARR "the most obtuse" of its peers.
- **Keyword modifiers (`+music` source/scoping scopes)** — they exist to scope FARR's slow non-indexed walk; ann's index dissolved that problem, and the residual filtering need is covered by `-term` and buckets — revisit only on a concrete demonstrated need.
- **Virtual launch string DSL (~40 commands, `;;;` chaining, three variable syntaxes)** — ann already has a launch DSL; it's called Tcl, and it has functions.
- **Alias pack distribution format** — shareable `.alias` files are a plugin ecosystem wearing an XML trenchcoat.
- **Multiple configurable launch-modifier combos, launch-all (Ctrl+Alt+Enter), `+launchone`** — configurability sprawl serving niches ann doesn't have.
- **Special search phrases (`gooptions`, `agroups`, `historys`…)** — magic words are hidden UI; ann has a Settings dialog, a tray menu, and (with #3) real history recall.
- **Toolbar strip, drag-out-of-results, icon-size modes** — mouse-first chrome on a keystroke-driven tool.
- **Embedded IE ActiveX HTML view** — the single best argument in FARR's whole feature list for the phrase "locked non-goal."
- **`%LASTHWND%` desktop scripting** — powerful in the AutoHotkey-glue sense, but it makes the launcher a macro engine; the deferred selection-capture hotkey (§2 endnote) would preserve the one high-value use, if and only if the owner amends the single-hotkey lock.
- **Quick Search Words** — a typo-expansion layer that fuzzy matching plus aliases already subsumes.

---

## 4. Recommended order

Value first, cost-aware. Waves map naturally onto releases. Note the dependency logic: #3 deliberately follows #1 and #2 because they create the invocations it recalls.

| # | Item | Size | Why here |
|---|------|------|----------|
| 1 | Zero-results "Run:" fallback | S | Makes ann a complete Win+R replacement in an afternoon; the C-side Run-box splitter is the only new piece |
| 2 | Parameterized-alias recipe + §6.7 recall fix | S | Unlocks an entire class of user config with template text, and pays down a known DESIGN gap with a small, well-located core fix |
| 3 | Typed-query history (Ctrl+Up) | S | The recall mechanism for what #1 and #2 just created; flat file, zero UI |
| 4 | Path mode with Tab completion | L | The flagship — biggest single capability gap vs FARR; do it after the quick wins, as its own release, with the ordering branch and the Tab mode-exception specified up front |
| 5 | Ignore globs + "Hide this result" | M | Index hygiene; value grows as the catalog ages; hides in the managed config block, enforcement at index time |
| 6 | Score inspection view | S | Nearly free; ship alongside any ranking/tuning work rather than standalone |
| 7 | `-term` exclusion | S | Nice-to-have; slot into any release |

*(Selection capture is deliberately absent: it awaits an owner amendment to the single-hotkey lock, revisited after #4 ships — §2 endnote.)*

**One-line summary:** ann already beats FARR at the parts FARR was famous for being fast at (index, ranking, config); what it's missing is FARR's *reach* — running what it doesn't know, aliases that take arguments, recalling what you typed, and walking the filesystem at typing speed. Adopt those four things plus their small satellites, defer the one idea that would touch a locked decision until the owner blesses it, and keep refusing everything FARR's own users complain about.
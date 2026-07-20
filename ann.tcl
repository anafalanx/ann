# ann.tcl — the ann launcher (Tcl/Tk UI + programmable config surface).
#
# Ordinary Tcl. In the shipped product it rides inside ann.exe's appended zipfs
# image as main.tcl; in development it runs under wish (`x run-dev`) with the C
# extensions loaded as dev .dll's. The hard Windows integration is C: ::annplat::*
# (window/monitor/foreground), ::annhotkey::* (global hotkey + single instance),
# ::anndb::* (SQLite). SECTION ORDER MATTERS: the error-capture spine (logging +
# a no-dialog background-error handler) is installed FIRST, before anything that
# could throw, so a GUI-subsystem exe can never spill a modal error dialog.

package require Tk

namespace eval ann {
    variable version "0.5"     ;# major.minor, two natural numbers
    variable dir ""
    variable logfile ""
    variable visible 0
    variable hotkey "Alt+Space"        ;# the single global hotkey (M1: fixed default)
    variable status_after ""

    # M2: catalog/search state
    variable reader ""                 ;# read-only DB connection (GUI thread)
    variable db ""                     ;# DB path next to the exe
    variable results {}                ;# current result dicts
    variable sel 0                     ;# selected result index
    variable last_query " "       ;# last queried text (sentinel != "")
    variable query_after ""            ;# keystroke debounce token
    variable result_limit 9            ;# rows in the VIEWPORT (DESIGN §11.4)
    variable result_max 50             ;# results kept in the scrollable list
    variable view_offset 0             ;# results index of the first visible row
    variable last_stats {}             ;# latest indexer stats (statusbar)
    variable last_scan_at ""           ;# HH:MM of the latest catalog update
    variable set_pairs {}              ;# Settings dialog model: {path prio} pairs
    variable window_width 640          ;# fixed popup width (DESIGN §9.1, §11.4)
    variable indexing 1                ;# cold-start until the first catalog update
    variable aliases {}                ;# normalized-keyword -> catalog path (§6.7, §11.3)
    variable confirm_destructive 1     ;# inline confirm for shutdown/restart/empty-bin (§15.4)

    # M5: live running-windows provider (enumerated, never persisted — §7.3)
    variable win_cache {}              ;# last EnumWindows snapshot
    variable win_cache_ts 0            ;# ms timestamp; re-enumerated when >250ms old

    # M6: the action panel (Tab / Ctrl+K — §9.5)
    variable panel_open 0
    variable panel_actions {}          ;# list of dicts {label script destructive}
    variable panel_sel 0
    variable panel_confirm -1          ;# index armed for the inline destructive confirm

    # deferred icon extraction (render paints cache-only, §6.6)
    variable icon_defer {}             ;# list of {rowIndex spec} misses to fill
    variable render_gen 0              ;# generation: stale deferred passes abort

    variable sysmenu_hooked 0          ;# titlebar-icon menu hook installed once

    # One fixed look, matching els (its DESIGN palette): a calm grey page,
    # near-black ink, flat white fields with hairlines, ONE accent flourish, and
    # a cool calm selection tint. ann's accent is els RED #DC322F (owner
    # decision 2026-07-20, REVERSING the earlier green4 #008B00 choice: the
    # tools now read as one suite — the same single accent everywhere, same
    # one-flourish discipline). ONE color serves caret, icon bit, update notice
    # and hints alike. Errors also read red — same hue, semantics carried by
    # placement and wording, exactly as in els (red caret + red errors coexist).
    # The catalog LED's idle state moves to the semantic good-green (it is a
    # status light, not a flourish; accent-red idle would collide with its own
    # red priority-scan state).
    variable C
    array set C {
        bg "#F2F2F2"  panel "#FFFFFF"  ink "#1A1A1A"  muted "#767676"
        accent "#DC322F"  accentText "#DC322F"  good "#3C8A50"  bad "#DC322F"
        sel "#D6E2F2"  hair "#D9D9D9"  focus "#BFCFE3"
    }
}

# ---- install directory (next to the exe, or the repo root in dev) -----------
proc ann::dir {} {
    if {[string match "//zipfs:*" [info script]]} {
        return [file dirname [info nameofexecutable]]
    }
    return [file dirname [file normalize [info script]]]
}
set ann::dir     [ann::dir]
set ann::logfile [file join $ann::dir ann.log]

# ============================================================================
#  ERROR-CAPTURE SPINE — installed before anything else can throw.
# ============================================================================

# ann::log — append a timestamped line to ann.log AND stderr (stderr is text in
# the console twin / dev; a harmless no-op in the GUI exe). MUST NOT throw.
proc ann::log {level msg} {
    set line ""
    catch {
        set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] \[$level\] $msg"
    }
    catch {
        set fh [open $::ann::logfile a]
        fconfigure $fh -encoding utf-8 -translation lf
        puts $fh $line
        close $fh
    }
    catch {puts stderr $line ; flush stderr}
}

# ann::status — a transient message in the popup's status line. Safe before the
# UI exists (no-op). Used by the error handler so failures are visible without a
# dialog. Auto-clears after a few seconds.
proc ann::status {msg {kind info}} {
    variable C
    variable status_after
    if {![winfo exists .status.in.msg]} return
    if {$status_after ne ""} { catch {after cancel $status_after} ; set status_after "" }
    if {$msg eq ""} {
        # idle: show the steady hint, muted, no auto-clear
        .status.in.msg configure -text [ann::status_idle_text] -foreground $C(muted)
        return
    }
    .status.in.msg configure -text $msg -foreground [expr {$kind eq "error" ? $C(bad) : $C(ink)}]
    set status_after [after 6000 [list ann::status ""]]
}

# THE no-dialog guarantee: route every background/async error to the log + the
# status line, NEVER to Tk's modal error dialog. Replaces every spelling of the
# handler Tk might invoke.
proc ann::bgerror {msg {opts {}}} {
    ann::log ERROR "bgerror: $msg | [string map {\n { }} $::errorInfo]"
    catch {ann::status "error: $msg" error}
}
interp bgerror {} ::ann::bgerror
proc ::bgerror {msg} { ::ann::bgerror $msg }
catch {proc ::tk::dialog::error::bgerror {msg args} { ::ann::bgerror $msg }}

ann::log INFO "ann $ann::version starting (dir=$ann::dir, script=[info script])"

# Load the C extensions. In ann.exe they are statically provided by the app-init,
# so `package require` returns immediately; under wish/tests they load as dev
# .dll's from build/; if absent, the UI degrades and logs a warning.
foreach pkg {anndb annplat annhotkey annindex annicon} {
    if {[catch {package require $pkg} e]} { ann::log WARN "extension '$pkg' unavailable: $e" }
}

proc ann::has {cmd} { return [expr {[llength [info commands ::$cmd]] > 0}] }

# ============================================================================
#  THE CONFIG SURFACE (DESIGN §11) — the ONLY extensibility mechanism.
#  ann.config.tcl is plain Tcl sourced into this interpreter. Loading is STAGED:
#  the ann::* registration commands write into cfg_st_* while a load is running;
#  only an error-free source commits (a typo can never brick a live launcher).
# ============================================================================
namespace eval ann {
    variable providers {}              ;# name -> proc (committed)
    variable cfg_actions {}            ;# list of {kinds label proc} (committed)
    variable cfg_staging 0
    variable cfg_st_options {}
    variable cfg_st_aliases {}
    variable cfg_st_providers {}
    variable cfg_st_actions {}
    variable hotkey_active ""          ;# the chord actually registered right now
    variable reload_after ""
}

# ann::option <option> <value> — the knobs (§11.4). Unknown options warn, never
# fail. (Named `option`, NOT the spec's `ann::set`: a proc called ann::set would
# shadow the builtin `set` for every proc in this namespace — a Tcl resolution
# rule — so the spec name is unimplementable without poisoning the whole app.)
proc ann::option {opt value} {
    if {$::ann::cfg_staging} { dict set ::ann::cfg_st_options $opt $value ; return }
    ann::apply_option $opt $value
}

# ann::alias <keyword> <target> — exact keyword pins its target (§6.7). Target may
# be a catalog path, a plain file path, or a command prefix (§11.4 shows all 3).
proc ann::alias {keyword target} {
    if {$::ann::cfg_staging} {
        dict set ::ann::cfg_st_aliases [string tolower [string trim $keyword]] $target
        return
    }
    dict set ::ann::aliases [string tolower [string trim $keyword]] $target
}

# ann::provider <name> <proc> — custom result provider, called per keystroke with
# the query; returns ann::result dicts (§11.3).
proc ann::provider {name procname} {
    if {$::ann::cfg_staging} { dict set ::ann::cfg_st_providers $name $procname ; return }
    dict set ::ann::providers $name $procname
}

# ann::action <name> -kinds {...} -label "..." <proc> — a panel action (§11.3).
proc ann::action {name args} {
    if {[llength $args] != 5 || [lindex $args 0] ne "-kinds" || [lindex $args 2] ne "-label"} {
        error "usage: ann::action name -kinds {kinds} -label \"label\" proc"
    }
    set entry [list [lindex $args 1] [lindex $args 3] [lindex $args 4]]
    if {$::ann::cfg_staging} { lappend ::ann::cfg_st_actions $entry ; return }
    lappend ::ann::cfg_actions $entry
}

# ann::result -id I -name N ?-subtitle S? ?-kind K? ?-icon spec? -launch script
proc ann::result {args} {
    array set o {-id "" -name "" -subtitle "" -kind app -icon "" -launch ""}
    foreach {k v} $args {
        if {![info exists o($k)]} { error "ann::result: unknown key $k" }
        set o($k) $v
    }
    if {$o(-name) eq ""} { error "ann::result: -name is required" }
    if {$o(-id) eq ""} { set o(-id) "cfg:$o(-name)" }
    set d [dict create id $o(-id) name $o(-name) path $o(-id) kind $o(-kind) \
               launch tclproc target $o(-subtitle) score 0 script $o(-launch)]
    if {$o(-subtitle) ne ""} { dict set d subtitle $o(-subtitle) }
    if {$o(-icon) ne ""} { dict set d iconspec $o(-icon) }
    return $d
}

# CommandLineToArgvW-compatible quoting of ONE argument (§15.3): backslash runs
# preceding a quote (or the closing quote) are doubled; embedded quotes become \".
proc ann::quote_arg {a} {
    if {$a ne "" && ![regexp {[ \t"]} $a]} { return $a }
    set out "\""
    set bs 0
    foreach ch [split $a ""] {
        if {$ch eq "\\"} { incr bs ; continue }
        if {$ch eq "\""} {
            append out [string repeat "\\" [expr {$bs * 2 + 1}]] "\""
            set bs 0
            continue
        }
        if {$bs} { append out [string repeat "\\" $bs] ; set bs 0 }
        append out $ch
    }
    append out [string repeat "\\" [expr {$bs * 2}]] "\""
    return $out
}

# ann::run <verb> <path> ?arg ...? — invoke the C launch layer (§11.3). Each
# extra word is ONE argument (a single list argument is accepted as the vector,
# matching the §11.4 example `ann::run open exe [list -d $path]`); quoting is
# CommandLineToArgvW-correct — argument vectors, never string splicing (§15.3).
proc ann::run {verb path args} {
    if {[llength $args] == 1} { set args [lindex $args 0] }
    switch -- $verb {
        open {
            set argstr [join [lmap a $args { ann::quote_arg $a }] " "]
            annplat::launch path $path $argstr
        }
        shell {
            # `shell` takes a full command LINE as a Tcl list: word 0 is the
            # program, the rest are its arguments. The §11.4 idiom passes the
            # whole line as one argument: `ann::run shell {rundll32.exe ...}`.
            if {[llength $args] == 0} {
                set words $path
            } else {
                set words [concat [list $path] $args]
            }
            set prog [lindex $words 0]
            set argstr [join [lmap a [lrange $words 1 end] { ann::quote_arg $a }] " "]
            annplat::launch path $prog $argstr
        }
        runas { annplat::runas $path }
        default { error "ann::run: unknown verb $verb (open|shell|runas)" }
    }
}

proc ann::config_path {} { return [file join $::ann::dir ann.config.tcl] }

proc ann::config_template {} {
    return {# ============================================================================
#  ann.config.tcl — sourced at startup; hot-reloaded on save (a broken config is
#  rejected and the previous one stays live). This file is the ONLY extensibility
#  surface: it is plain Tcl running inside ann's interpreter (DESIGN §11/§12).
# ============================================================================

# ---- options ---------------------------------------------------------------
ann::option hotkey              {Alt+Space}  ;# the single global hotkey
ann::option result_limit        9            ;# rows shown before scrolling
ann::option confirm_destructive 1            ;# confirm shutdown/restart/empty-bin
ann::option frecency_halflife   14           ;# days; how fast habits fade
ann::option weight_fuzzy        1.0          ;# blend: w_fuzzy * fuzzyScore
ann::option weight_frecency     0.35         ;#      + w_frec  * norm(frecency)
ann::option frecency_norm_k     4.0          ;# norm(x) = x/(x+k)
ann::option window_width        640          ;# popup width in px

# Folders to scan. These ARE the list — ordinary entries seeded with the
# Windows-11 startable-item locations; delete any (or all) to stop scanning
# them, add a drive root like C:/ for whole-disk. The startable locations are
# always indexed first and fast; the rest follows in a throttled background
# walk. %VARS% are expanded; / and \ both work. (The Settings dialog edits
# this via its managed block at the end of the file.)
ann::option watched_roots [lmap p [ann::default_roots] { list $p 1 }]

# ---- a keyword alias (§6.7): typing exactly "cfg" pins this file to the top --
# (a partial or typo'd keyword also recalls the target, at its fuzzy score)
ann::alias cfg [file join $ann::dir ann.config.tcl]

# ---- a PARAMETERIZED alias (recipe): "<keyword> <args>" via a provider -------
# The alias table handles bare keywords; for FARR-style parameterized shortcuts,
# match the keyword prefix in a provider and template the remainder. ann ships
# no search policy — this stays yours, in your config:
# proc gh_search {query} {
#     if {![string match "gh *" $query]} { return {} }
#     set term [string trim [string range $query 3 end]]
#     if {$term eq ""} { return {} }
#     return [list [ann::result -id "gh:$term" -name "GitHub: $term" \
#         -subtitle "search github.com" -kind app -icon stock:app \
#         -launch [list ann::run open "https://github.com/search?q=$term"]]]
# }
# ann::provider gh gh_search

# ---- a custom result provider (procs run per keystroke — keep them fast) -----
# proc my_projects {query} {
#     set out {}
#     foreach {name dir} { ann {C:\dev\ann} } {
#         if {[ann::fuzzy $query $name] > 0} {
#             lappend out [ann::result -id "proj:$name" -name "Project: $name" \
#                 -subtitle $dir -kind app -icon stock:folder \
#                 -launch [list ann::run open $dir]]
#         }
#     }
#     return $out
# }
# ann::provider projects my_projects

# ---- a custom action for the Tab/Ctrl+K panel --------------------------------
# proc open_in_terminal {result} {
#     set path [dict get $result path]
#     if {[dict get $result kind] eq "file"} { set path [file dirname $path] }
#     ann::run open wt.exe [list -d $path]
# }
# ann::action term_here -kinds {file folder} -label "Open in Terminal" open_in_terminal
}
}

# Load (or first-run-create) the config with staged commit (§11.1/§11.2/§15.1).
proc ann::load_config {} {
    set path [ann::config_path]
    if {![file exists $path]} {
        if {[catch {
            set fh [open $path w]
            fconfigure $fh -encoding utf-8 -translation lf
            puts -nonewline $fh [ann::config_template]
            close $fh
        } e]} {
            ann::log ERROR "cannot write default config: $e"
            return 0
        }
        ann::log INFO "first run: wrote default config $path"
    }
    set ::ann::cfg_st_options {}
    set ::ann::cfg_st_aliases {}
    set ::ann::cfg_st_providers {}
    set ::ann::cfg_st_actions {}
    set ::ann::cfg_staging 1
    set rc [catch {uplevel #0 [list source $path]} err]
    set ::ann::cfg_staging 0
    if {$rc} {
        ann::log ERROR "config rejected (previous config stays live): $err"
        ann::status "config error: $err" error
        return 0
    }
    # commit registries atomically, then apply options — one bad VALUE must
    # never abort the rest (it is logged + shown, never thrown)
    set ::ann::aliases     $::ann::cfg_st_aliases
    set ::ann::providers   $::ann::cfg_st_providers
    set ::ann::cfg_actions $::ann::cfg_st_actions
    dict for {opt value} $::ann::cfg_st_options {
        if {[catch {ann::apply_option $opt $value} e]} {
            ann::log ERROR "option '$opt' rejected: $e"
            ann::status "config option '$opt' rejected" error
        }
    }
    ann::log INFO "config loaded ([dict size $::ann::cfg_st_options] options,\
 [dict size $::ann::aliases] aliases, [dict size $::ann::providers] providers,\
 [llength $::ann::cfg_actions] actions)"
    return 1
}

proc ann::apply_option {opt value} {
    switch -- $opt {
        hotkey {
            set ::ann::hotkey $value
            ann::apply_hotkey
        }
        result_limit {
            if {![string is integer -strict $value] || $value < 1 || $value > 20} {
                ann::log WARN "result_limit '$value' out of range (1-20), ignored" ; return
            }
            if {$value != $::ann::result_limit} {
                set ::ann::result_limit $value
                if {[winfo exists .c.list]} { ann::make_rows ; ann::render_results }
            }
        }
        confirm_destructive {
            if {![string is boolean -strict $value]} {
                ann::log WARN "confirm_destructive '$value' is not a boolean, ignored" ; return
            }
            set ::ann::confirm_destructive [expr {$value ? 1 : 0}]
        }
        window_width {
            if {[string is integer -strict $value] && $value >= 360 && $value <= 2000} {
                set ::ann::window_width $value
                if {[winfo exists .c.spacer]} { .c.spacer configure -width [expr {$value - 36}] }
            }
        }
        frecency_halflife {
            set days $value
            regexp {^([0-9.]+)d?$} $value -> days
            if {[ann::has anndb::tune]}    { catch {anndb::tune halflife $days} }
            if {[ann::has annindex::tune]} { catch {annindex::tune $days} }
        }
        weight_fuzzy    { if {[ann::has anndb::tune]} { catch {anndb::tune wfuzzy $value} } }
        weight_frecency { if {[ann::has anndb::tune]} { catch {anndb::tune wfrec $value} } }
        frecency_norm_k { if {[ann::has anndb::tune]} { catch {anndb::tune k $value} } }
        watched_roots {
            # Entries are {path prio} pairs (prio 1 = scan fast/first, 0 = the
            # throttled background tier). A bare path is accepted too (legacy /
            # hand-written): its priority defaults to ON iff it is one of the
            # default startable-item folders. %VARS% are expanded.
            if {[catch {llength $value} n]} {
                ann::log WARN "watched_roots is not a list, ignored" ; return
            }
            set defs [string tolower [ann::default_roots]]
            set roots {} ; set prios {}
            foreach r $value {
                set prio ""
                if {[llength $r] == 2 && [lindex $r 1] in {0 1}} {
                    set prio [lindex $r 1]
                    set r [lindex $r 0]
                }
                if {[string first % $r] >= 0 && [ann::has annplat::expand_env]} {
                    catch { set r [annplat::expand_env $r] }
                }
                if {$prio eq ""} {
                    set prio [expr {[string tolower $r] in $defs ? 1 : 0}]
                }
                lappend roots $r
                lappend prios $prio
            }
            if {[ann::has annindex::set_roots]} { catch {annindex::set_roots $roots $prios} }
        }
        default { ann::log WARN "unknown option '$opt' ignored" }
    }
}

# register/rebind the global hotkey to ::ann::hotkey (non-fatal on conflict §11.1;
# rebind is marshalled to the hotkey thread, old chord unregistered first §11.2)
proc ann::apply_hotkey {} {
    variable hotkey ; variable hotkey_active
    if {![ann::has annhotkey::start]} { return 0 }
    if {$hotkey eq $hotkey_active && [annhotkey::active]} { return 1 }
    if {[catch {ann::parse_hotkey $hotkey} parsed]} {
        ann::log ERROR "bad hotkey '$hotkey': $parsed"
        ann::status "bad hotkey: $hotkey" error
        return 0
    }
    lassign $parsed mods vk
    if {[annhotkey::active]} {
        if {[catch {annhotkey::rebind $mods $vk} e]} {
            ann::log ERROR "hotkey rebind to '$hotkey' failed: $e (old chord kept)"
            ann::status "hotkey '$hotkey' unavailable; previous kept" error
            if {$hotkey_active ne ""} { set ::ann::hotkey $hotkey_active }  ;# footer shows the truth
            ann::update_foot
            return 0
        }
    } else {
        if {[catch {annhotkey::start $mods $vk [ann::instance_tag] ::ann::on_hotkey ::ann::on_show} e]} {
            ann::log ERROR "hotkey '$hotkey' not registered: $e"
            ann::status "hotkey $hotkey unavailable: $e" error
            if {$hotkey_active ne ""} { set ::ann::hotkey $hotkey_active }
            ann::update_foot
            return 0
        }
    }
    set hotkey_active $hotkey
    ann::log INFO "global hotkey '$hotkey' active"
    ann::update_foot
    return 1
}

# hot reload, debounced (the watcher notifies on the GUI thread — §11.2)
proc ann::on_config_changed {} {
    variable reload_after
    if {$reload_after ne ""} { catch {after cancel $reload_after} }
    set reload_after [after 150 ann::reload_config]
}
proc ann::reload_config {} {
    set ::ann::reload_after ""
    ann::log INFO "config change detected; reloading"
    if {[ann::load_config]} {
        ann::status "config reloaded"
        if {$::ann::visible} { ann::do_query }
    }
}

# ============================================================================
#  SEARCH / RANKING
# ============================================================================

# ann::fuzzy — the subsequence scorer. Delegates to the C fzy scorer (DESIGN §6.3)
# when available (the real path), with a pure-Tcl fallback for degraded dev runs.
# Returns >0 on a match, 0 on no match.
proc ann::fuzzy {query cand} {
    if {$query eq ""} { return 1 }      ;# empty query matches everything (show all)
    if {[llength [info commands ::anndb::fuzzy]]} {
        set s [anndb::fuzzy $query $cand]
        return [expr {$s < -1.0e9 ? 0 : ($s > 1.0e9 ? 100 : $s)}]
    }
    set q [string tolower $query]
    set c [string tolower $cand]
    if {$q eq ""} { return 1 }
    set qi 0 ; set ql [string length $q]
    set score 0 ; set prev -2 ; set boundary 1
    set n [string length $c]
    for {set i 0} {$i < $n && $qi < $ql} {incr i} {
        set ch [string index $c $i]
        if {$ch eq [string index $q $qi]} {
            incr score
            if {$i == $prev + 1} { incr score 2 }
            if {$boundary}       { incr score 3 }
            set prev $i ; incr qi
        }
        set boundary [expr {[string first $ch " /\\_-.."] >= 0}]
    }
    return [expr {$qi == $ql ? $score : 0}]
}

# ============================================================================
#  HOTKEY parsing (Tcl, testable) — "Alt+Space" -> {fsModifiers vk}
# ============================================================================
proc ann::vk_for {key} {
    set lk [string tolower $key]
    if {[string length $key] == 1 && [string is alpha -strict $key]} { return [scan [string toupper $key] %c] }
    if {[string length $key] == 1 && [string is digit -strict $key]} { return [scan $key %c] }
    set named {
        space 0x20  enter 0x0d  return 0x0d  tab 0x09  esc 0x1b  escape 0x1b
        backspace 0x08  delete 0x2e  del 0x2e  insert 0x2d  ins 0x2d
        home 0x24  end 0x23  pageup 0x21  pagedown 0x22  prior 0x21  next 0x22
        up 0x26  down 0x28  left 0x25  right 0x27  plus 0xbb  minus 0xbd
    }
    if {[dict exists $named $lk]} { return [expr [dict get $named $lk]] }
    if {[regexp {^f([0-9]{1,2})$} $lk -> n] && $n >= 1 && $n <= 24} { return [expr {0x6f + $n}] }
    return 0
}
# returns {fsModifiers vk}; throws on an unparseable chord.
proc ann::parse_hotkey {chord} {
    set MOD {alt 1  ctrl 2  control 2  shift 4  win 8  super 8  cmd 8}
    set mods 0 ; set vk 0
    foreach part [split $chord +] {
        set p [string trim $part]
        if {$p eq ""} continue
        set lp [string tolower $p]
        if {[dict exists $MOD $lp]} {
            set mods [expr {$mods | [dict get $MOD $lp]}]
        } else {
            if {$vk != 0} { error "hotkey has more than one key: $chord" }
            set vk [ann::vk_for $p]
            if {$vk == 0} { error "unknown key in hotkey: $p" }
        }
    }
    if {$vk == 0} { error "hotkey has no key: $chord" }
    return [list $mods $vk]
}

# a per-install tag so two copies (USB vs local) don't collide on mutex/hotkey-window.
# crc32 needs a BYTE sequence: encode first or a non-Latin-1 install path (C:\Users\
# José, C:\Users\иван) would throw at startup.
proc ann::instance_tag {} {
    set p [string tolower [file nativename [file normalize $::ann::dir]]]
    return [format %08x [zlib crc32 [encoding convertto utf-8 $p]]]
}

# ============================================================================
#  STACK-HEALTH PROBES (shared by the UI and --selftest)
# ============================================================================
proc ann::probe_all {} {
    set out {}
    lappend out [list "Tcl/Tk" "[info patchlevel] / [package present Tk]" 1]
    set zip [string match "//zipfs:*" [info script]]
    lappend out [list "zipfs"  [expr {$zip ? "mounted (//zipfs:/app)" : "dev (filesystem)"}] 1]
    if {[ann::has anndb::selftest]} {
        if {[catch {anndb::selftest} d]} {
            lappend out [list "SQLite/FTS5" "error: $d" 0]
        } else {
            lappend out [list "SQLite/FTS5" \
                "v[dict get $d version] · trigram 'chr'->[dict get $d fts5_name]" [dict get $d ok]]
        }
    } else { lappend out [list "SQLite/FTS5" "anndb not loaded" 0] }
    if {[ann::has annplat::thread_roundtrip]} {
        set rc [catch {annplat::thread_roundtrip} r]
        lappend out [list "worker→GUI bridge" $r [expr {!$rc && $r eq "ok"}]]
    } else { lappend out [list "worker→GUI bridge" "annplat not loaded" 0] }
    if {[ann::has annhotkey::active]} {
        # capability present = PASS; current registration state shown in the detail
        # (the live UI shows "registered"; --selftest, which doesn't grab the real
        # chord, shows "ready" — the actual RegisterHotKey test is in probe_hotkey).
        lappend out [list "global hotkey" \
            [expr {[annhotkey::active] ? "$::ann::hotkey registered" : "ready (started on launch)"}] 1]
    } else { lappend out [list "global hotkey" "annhotkey not loaded" 0] }
    set fz [expr {[ann::fuzzy gc {Google Chrome}] > 0 && [ann::fuzzy zzx {Google Chrome}] == 0}]
    lappend out [list "fuzzy gc→Chrome" "score=[ann::fuzzy gc {Google Chrome}]" $fz]
    return $out
}

# Exercise the M1 hotkey + single-instance C path headlessly, on a UNIQUE tag and
# an obscure chord so it never collides with a live instance. Returns probe rows.
proc ann::probe_hotkey {} {
    set out {}
    if {![ann::has annhotkey::start]} {
        return [list [list "hotkey C path" "annhotkey not loaded" 0]]
    }
    set tag "selftest[pid]"
    set firstOk 0
    catch {set firstOk [annhotkey::acquire $tag]}
    lappend out [list "single-instance mutex" "first=$firstOk" $firstOk]
    # Ctrl+Alt+Shift+F24 — vanishingly unlikely to be taken.
    lassign [ann::parse_hotkey "Ctrl+Alt+Shift+F24"] m1 v1
    set startOk [expr {![catch {annhotkey::start $m1 $v1 $tag ::ann::_noop ::ann::_noop} e1]}]
    lappend out [list "RegisterHotKey" [expr {$startOk ? "ok" : $e1}] $startOk]
    if {$startOk} {
        lassign [ann::parse_hotkey "Ctrl+Alt+Shift+F23"] m2 v2
        set rebindOk [expr {![catch {annhotkey::rebind $m2 $v2} e2]}]
        lappend out [list "rebind (old→new)" [expr {$rebindOk ? "ok" : $e2}] $rebindOk]
        catch {annhotkey::stop}
        set stopped [expr {![annhotkey::active]}]
        lappend out [list "stop/join" [expr {$stopped ? "ok" : "still active"}] $stopped]
    }
    return $out
}
proc ann::_noop {} {}

# ============================================================================
#  HEADLESS SELF-TEST: ann.exe --selftest [report.txt]
# ============================================================================
proc ann::selftest_report {path} {
    set rows {}
    # a THROWING probe is itself a hard FAIL — never silently an empty report
    if {[catch {ann::probe_all} r]} { lappend rows [list probe_all "error: $r" 0] } \
    else { lappend rows {*}$r }
    if {[catch {ann::probe_hotkey} r]} { lappend rows [list probe_hotkey "error: $r" 0] } \
    else { lappend rows {*}$r }
    set lines [list "ann $::ann::version --selftest" "script: [info script]" [string repeat - 62]]
    set all [expr {[llength $rows] > 0}]
    foreach row $rows {
        lassign $row label detail ok
        if {!$ok} { set all 0 }
        lappend lines [format "  %-22s %-5s %s" $label [expr {$ok ? "PASS" : "FAIL"}] $detail]
    }
    lappend lines [string repeat - 62] "OVERALL: [expr {$all ? "PASS" : "FAIL"}]"
    catch {
        set fh [open $path w] ; fconfigure $fh -translation lf
        puts $fh [join $lines \n] ; close $fh
    }
    ann::log INFO "selftest -> [expr {$all ? "PASS" : "FAIL"}] ($path)"
    return $all
}

# ============================================================================
#  THE POPUP
# ============================================================================
proc ann::build {} {
    variable C
    wm withdraw .              ;# never show an unstyled frame (anti-flash)
    # A REAL titlebar (user decision, amends DESIGN §9.1): "ann <version>".
    wm overrideredirect . 0
    wm title . "ann $::ann::version"
    wm attributes . -topmost 1
    wm resizable . 0 0
    wm protocol . WM_DELETE_WINDOW ann::hide ;# X hides; quitting stays explicit (§10.2)
    ann::set_window_icon       ;# real ann icon in the titlebar + taskbar (not Tk's feather)
    # The menu lives UNDER the titlebar app icon (annplat::hook_sysmenu) + the
    # tray, not on a menubar — an els menubar made no real difference to the
    # window, so ann keeps the in-icon menu (owner decision).
    catch {. configure -menu ""}   ;# ensure no stale menubar survives a rebuild
    . configure -bg $C(bg)

    catch {destroy .c}         ;# idempotent: rebuildable (tests, config reload)
    catch {destroy .status}
    frame .c -bg $C(bg)
    # NB: .c is packed at the END of build, AFTER the status bar, so the packer
    # gives the non-expanding bar the bottom edge before .c claims the rest. The
    # padding lives on that pack: extra TOP so the field clears the titlebar app
    # icon, small bottom (the docked status bar owns the window's foot).

    # Fixed width by construction: this spacer pins the content width, the
    # toplevel sizes itself to its content (we never force WxH via wm geometry,
    # only the position), so the popup grows downward as rows appear (§9.1).
    # Chrome typography matches els: Segoe UI. annName/annSub drive the action
    # panel + settings dialog; the result LIST uses its own (smaller) row fonts
    # (annRowName/annRowSub = annName/annSub - 4pt, owner decision); the status
    # bar has its own font so the row shrink never touches it.
    catch {font create annName    -family "Segoe UI" -size 12}
    catch {font create annSub     -family "Segoe UI" -size 9}
    catch {font create annQuery   -family "Segoe UI" -size 13}
    catch {font create annRowName -family "Segoe UI" -size 8}
    catch {font create annRowSub  -family "Segoe UI" -size 5}
    catch {font create annStatus  -family "Segoe UI" -size 8}
    frame .c.spacer -bg $C(bg) -width [expr {$::ann::window_width - 36}] -height 1
    pack .c.spacer

    # flat white field, hairline border, calm-blue focus ring, and els's one red
    # flourish: the caret
    entry .c.q -bg $C(panel) -fg $C(ink) -insertbackground $C(accent) \
        -insertwidth 2 -insertofftime 0 \
        -relief flat -font annQuery -highlightthickness 1 \
        -highlightbackground $C(hair) -highlightcolor $C(focus)
    pack .c.q -fill x -ipady 7 -pady {0 10}

    # the list viewport + the els-style vertical scrollbar (auto-hidden while
    # everything fits). The list keeps result_max results; only result_limit
    # rows exist as widgets — scrolling re-points them (true virtualization).
    ann::init_scrollbar_style
    frame .c.body -bg $C(bg)
    pack .c.body -fill both -expand 1
    frame .c.list -bg $C(bg)
    ttk::scrollbar .c.vs -orient vertical -command ann::scroll_cmd
    grid .c.list -in .c.body -row 0 -column 0 -sticky nsew
    grid .c.vs   -in .c.body -row 0 -column 1 -sticky ns
    grid remove .c.vs
    grid rowconfigure    .c.body 0 -weight 1
    grid columnconfigure .c.body 0 -weight 1
    # RESERVE the bar's column even while it is hidden: without the minsize, the
    # grid's requested width changes as the bar appears/disappears and the whole
    # window visibly wobbles a few px during scrolling (user-reported glitch)
    grid columnconfigure .c.body 1 -minsize [winfo reqwidth .c.vs]
    label .c.list.empty -bg $C(bg) -fg $C(muted) -anchor w -font {-size 11} -text "" -width 1
    ann::make_rows

    ann::build_statusbar       ;# a real docked status bar (els-style), child of .

    bind . <Control-q> { ann::quit }
    bind .c.q <KeyRelease> { ann::on_query }
    bind .c.q <Down>      { ann::key_nav down ; break }
    bind .c.q <Up>        { ann::key_nav up ; break }
    bind .c.q <Return>    { ann::key_nav enter ; break }
    bind .c.q <Escape>    { ann::key_nav escape ; break }
    bind .c.q <Tab>       { ann::key_nav tab ; break }
    bind .c.q <Control-k> { ann::key_nav tab ; break }

    # Dock order matters (Tk packer): the non-expanding status bar must claim the
    # bottom edge BEFORE the expanding content frame claims the rest.
    pack .status -side bottom -fill x
    pack .c      -side top    -fill both -expand 1 -padx 18 -pady {22 8}

    ann::render_results
    ann::status ""             ;# seed the bar with the default hint
    focus -force .c.q
}

# A real status bar like els: a full-width bar pinned to the window foot, set off
# by a hairline, with a left message cell (transient status / key hints) and a
# right info cell (result count). Width-safe: the left cell uses the -width 1 +
# fill trick so a long message clips instead of widening the fixed popup.
# ---- tooltips (els's machinery, ported verbatim: els.tcl find-bar polish) ----
proc ann::tooltip {w text} {
    bind $w <Enter>      [list ann::tip_schedule $w $text]
    bind $w <Leave>      ann::tip_cancel
    # per-button (not generic <ButtonPress>) + APPEND: a widget's own specific
    # <Button-1> binding shadows a generic one, so a click never dismissed the
    # tip; appending composes with existing handlers
    bind $w <ButtonPress-1> {+ann::tip_cancel}
    bind $w <ButtonPress-2> {+ann::tip_cancel}
    bind $w <ButtonPress-3> {+ann::tip_cancel}
    # the anchor dying must take its pending timer AND a visible tip with it
    bind $w <Destroy> {+ann::tip_cancel}
}
# dynamic tooltip: textcmd is evaluated when the tip is about to show, so it
# tracks live state; an empty result suppresses the tip
proc ann::tooltip_for {w textcmd {delay 550}} {
    bind $w <Enter>       [list ann::tip_schedule_cmd $w $textcmd $delay]
    bind $w <Leave>       ann::tip_cancel
    bind $w <ButtonPress-1> {+ann::tip_cancel}
    bind $w <ButtonPress-2> {+ann::tip_cancel}
    bind $w <ButtonPress-3> {+ann::tip_cancel}
    bind $w <Destroy> {+ann::tip_cancel}
}
proc ann::tip_schedule {w text} {
    ann::tip_cancel
    set ::ann::tip_after [after 550 [list ann::tip_pop $w $text]]
}
proc ann::tip_schedule_cmd {w textcmd {delay 550}} {
    ann::tip_cancel
    set ::ann::tip_after [after $delay [list ann::tip_pop_cmd $w $textcmd]]
}
proc ann::tip_cancel {} {
    if {[info exists ::ann::tip_after]} { after cancel $::ann::tip_after ; unset ::ann::tip_after }
    catch {destroy .tip}
}
# wrap long tip text so it can't run off the screen (els::tip_wrap: breaks after
# a separator once a line reaches ~target, hard break past target+cap)
proc ann::tip_wrap {s {target 72} {cap 24}} {
    if {[string length $s] <= $target} { return $s }
    set out {}
    foreach para [split $s \n] {
        if {[string length $para] <= $target} { lappend out $para ; continue }
        set line ""
        foreach ch [split $para ""] {
            append line $ch
            set n [string length $line]
            if {($n >= $target && [string first $ch "/\\ -_"] >= 0) || $n >= $target + $cap} {
                lappend out $line ; set line ""
            }
        }
        if {$line ne ""} { lappend out $line }
    }
    return [join $out \n]
}
proc ann::tip_pop {w text} {
    catch {destroy .tip}
    if {![winfo exists $w] || $text eq ""} { return }
    toplevel .tip -bd 0
    wm overrideredirect .tip 1
    catch {wm attributes .tip -topmost 1}
    label .tip.l -text [ann::tip_wrap $text] -justify left \
        -bg "#2B2B2B" -fg "#F0F0F0" -font annStatus -padx 6 -pady 2
    pack .tip.l
    update idletasks
    set tw [winfo reqwidth .tip] ; set th [winfo reqheight .tip]
    set x [expr {[winfo rootx $w] + [winfo width $w] / 2 - $tw / 2}]
    set below [expr {[winfo rooty $w] + [winfo height $w] + 5}]
    # prefer below; flip above when needed; clamp into the widget's own toplevel
    set top [winfo toplevel $w]
    set margin 4
    set winl [winfo rootx $top]
    set wint [winfo rooty $top]
    set winr [expr {$winl + [winfo width $top]}]
    set winb [expr {$wint + [winfo height $top]}]
    set above [expr {[winfo rooty $w] - $th - 5}]
    if {$below + $th <= $winb - $margin} {
        set y $below
    } elseif {$above >= $wint + $margin} {
        set y $above
    } else {
        set y [expr {min(max($below, $wint + $margin), $winb - $th - $margin)}]
    }
    if {$x < $winl + $margin} {
        set x [expr {$winl + $margin}]
    } elseif {$x + $tw > $winr - $margin} {
        set x [expr {max($winl + $margin, $winr - $margin - $tw)}]
    }
    wm geometry .tip +$x+$y
}
proc ann::tip_pop_cmd {w textcmd} {
    if {![winfo exists $w]} { return }
    ann::tip_pop $w [uplevel #0 $textcmd]
}

proc ann::build_statusbar {} {
    variable C
    frame .status -bg $C(bg)
    frame .status.sep -bg $C(hair) -height 1
    pack .status.sep -side top -fill x
    frame .status.in -bg $C(bg) -padx 12 -pady 4
    pack .status.in -fill x
    # the catalog LED (flat, sober): good-green idle · red priority scan ·
    # dark-yellow background walk — hover for words. Idle is the SEMANTIC green,
    # not the accent: with the accent now red, an accent-idle LED would be
    # indistinguishable from its own priority-scan state.
    label .status.in.led -bg $C(bg) -fg $C(good) -font annStatus -text "●"
    pack .status.in.led -side left -padx {0 7}
    ann::tooltip_for .status.in.led ann::led_tip
    label .status.in.info -bg $C(bg) -fg $C(muted) -anchor e -font annStatus -text ""
    pack .status.in.info -side right -padx {10 0}
    ann::tooltip_for .status.in.info {expr {"[llength $::ann::results] results shown (ann keeps the first $::ann::result_max matches; the viewport scrolls)"}}
    # a normally-empty notice; lights up when a newer release is detected
    # (els's .sb.update, verbatim mechanism) — click opens the download page
    label .status.in.update -bg $C(bg) -fg $C(accentText) -anchor e -font annStatus \
        -text "" -cursor hand2
    pack .status.in.update -side right -padx {10 0}
    bind .status.in.update <Button-1> \
        {ann::open_url "https://github.com/anafalanx/ann/releases/latest"}
    label .status.in.msg -bg $C(bg) -fg $C(muted) -anchor w -font annStatus -text "" -width 1
    pack .status.in.msg -side left -fill x -expand 1
    ann::tooltip_for .status.in.msg ann::status_tip
}

# the LED state from the live indexer phase (0 idle, 1 priority, 2 background)
proc ann::led_phase {} {
    if {[dict size $::ann::last_stats] && [dict exists $::ann::last_stats phase]} {
        return [dict get $::ann::last_stats phase]
    }
    return [expr {$::ann::indexing ? 1 : 0}]
}
proc ann::led_update {} {
    variable C
    if {![winfo exists .status.in.led]} return
    # 1 = priority scan: red · 2 = background walk: sober yellow ·
    # idle: the semantic good-green (NOT the accent — the accent is red now,
    # and an accent-idle LED would collide with the priority-scan state).
    # (NO inline comments in the pattern list: Tcl parses them as patterns —
    # they pair up silently and break `default`.)
    switch -- [ann::led_phase] {
        1       { .status.in.led configure -fg "#DC322F" }
        2       { .status.in.led configure -fg "#B8860B" }
        default { .status.in.led configure -fg $C(good) }
    }
}
proc ann::led_tip {} {
    switch -- [ann::led_phase] {
        1       { return "catalog: PRIORITY scan running — the fast folders are being indexed right now" }
        2       { return "catalog: BACKGROUND walk running — the slow-tier folders, throttled so the machine stays quiet" }
        default { return "catalog: idle — nothing is being indexed" }
    }
}

# ---- update check (els's mechanism, verbatim) --------------------------------
# Best-effort, fire-and-forget check of the GitHub Releases API — a public,
# unauthenticated GET (one request at startup, far within the 60/hr limit, so
# it stays within GitHub's terms). This runtime has no TLS, so we lean on
# Windows' bundled curl.exe; stdout is piped back and stderr is sent to NUL so
# no console window flashes. Any failure (offline, no curl, odd JSON) is
# swallowed silently — the launcher never blocks or complains.
proc ann::check_update {} {
    set url "https://api.github.com/repos/anafalanx/ann/releases/latest"
    if {[catch {
        set ch [::open [list | curl.exe -s -m 6 \
            -H "User-Agent: ann-launcher" \
            -H "Accept: application/vnd.github+json" $url 2> NUL] r]
    }]} { return }
    set ::ann::update_buf ""
    fconfigure $ch -blocking 0 -translation binary
    fileevent $ch readable [list ann::update_read $ch]
}
proc ann::update_read {ch} {
    if {[catch {read $ch} chunk]} { catch {close $ch} ; return }
    append ::ann::update_buf $chunk
    if {[eof $ch]} {
        fileevent $ch readable {}
        catch {close $ch}
        ann::update_parse $::ann::update_buf
    }
}
proc ann::update_parse {data} {
    if {![regexp {"tag_name"\s*:\s*"([^"]+)"} $data -> tag]} { return }
    set latest [string trimleft $tag vV]
    if {[ann::version_gt $latest $::ann::version]} { ann::show_update $latest }
}
# a > b for dotted versions, via Tcl's own package comparator (junk -> false)
proc ann::version_gt {a b} {
    return [expr {![catch {package vcompare $a $b} c] && $c > 0}]
}
proc ann::show_update {ver} {
    if {![winfo exists .status.in.update]} return
    .status.in.update configure -text "ann $ver available"
    ann::log INFO "update available: ann $ver"
}
proc ann::open_url {url} {
    if {[catch {exec rundll32.exe url.dll,FileProtocolHandler $url &}]} {
        catch {exec cmd.exe /c start "" $url &}
    }
}

# The scrollbar style, cloned from els (els.tcl init_style): the clam theme's
# DEFAULT Vertical.TScrollbar layout so the up/down arrows always draw, sizes
# in POINTS so ttk scales them per-DPI, els's exact greys.
proc ann::init_scrollbar_style {} {
    variable C
    catch {ttk::style theme use clam}
    ttk::style configure Vertical.TScrollbar -troughcolor $C(bg) \
        -background "#BCBCBC" -arrowcolor "#4A4A4A" -bordercolor "#9A9A9A" \
        -relief raised -borderwidth 1 -arrowsize 10p   ;# slightly narrower than els's 12p: ann's UI is narrow
    ttk::style map Vertical.TScrollbar \
        -background [list active "#A4A4A4" disabled $C(bg)]
    # els's dialog family (els.tcl init_style), on ann's identical palette:
    # flat page-colored chrome, hairline-bordered buttons, white fields
    ttk::style configure TFrame -background $C(bg)
    ttk::style configure TLabel -background $C(bg) -foreground $C(ink) -font annSub
    ttk::style configure Dialog.TButton -font annSub \
        -background $C(bg) -foreground $C(ink) \
        -borderwidth 1 -relief solid -padding {10 5} -anchor center \
        -bordercolor $C(hair) -lightcolor $C(hair) -darkcolor $C(hair)
    ttk::style map Dialog.TButton \
        -background [list pressed $C(hair) active "#EAEAEA"] \
        -foreground [list disabled $C(muted)]
    ttk::style configure TEntry -fieldbackground $C(panel) -foreground $C(ink) \
        -bordercolor $C(hair) -lightcolor $C(panel) -darkcolor $C(panel) \
        -insertcolor $C(accent)
    ttk::style configure TSpinbox -fieldbackground $C(panel) -foreground $C(ink) \
        -bordercolor $C(hair) -arrowcolor "#4A4A4A" -insertcolor $C(accent) \
        -background $C(bg)
}

# 1234567 -> 1,234,567 (statusbar counts)
proc ann::ncomma {n} {
    while {[regsub {^(\d+)(\d{3})} $n {\1,\2} n]} {}
    return $n
}

# The steady left-cell text: INDEXING ACTIVITY, not usage hints (user decision).
# The steady left-cell line: ABBREVIATED catalog facts (A apps · F files ·
# HH:MM ⌚ last update, plus terse flags); the full sentences live in the
# tooltip (ann::status_tip) — hover the line or the LED.
proc ann::status_idle_text {} {
    variable last_stats ; variable last_scan_at ; variable indexing
    if {![dict size $last_stats]} { return [expr {$indexing ? "scanning…" : ""}] }
    set apps  [expr {[dict get $last_stats lnk_found] + [dict get $last_stats uwp_found]}]
    set txt "A [ann::ncomma $apps] · F [ann::ncomma [dict get $last_stats files_found]]"
    if {$last_scan_at ne ""} { append txt " · $last_scan_at" }
    if {[dict get $last_stats capped_prio] || [dict get $last_stats capped_bulk]} {
        append txt " · cap"
    }
    if {[dict get $last_stats errors]} { append txt " · E[dict get $last_stats errors]" }
    return $txt
}

# the verbose companion (the statusbar line's tooltip)
proc ann::status_tip {} {
    variable last_stats ; variable last_scan_at
    if {![dict size $last_stats]} { return "the catalog has not been built yet" }
    dict with last_stats {}
    set out "catalog: [ann::ncomma [expr {$lnk_found + $uwp_found}]] apps ([ann::ncomma $lnk_found] Start-Menu, [ann::ncomma $uwp_found] Store) · [ann::ncomma $files_found] files & folders ([ann::ncomma $files_prio] in priority folders, [ann::ncomma $files_bulk] background)"
    if {$last_scan_at ne ""} { append out "\nlast update $last_scan_at" }
    switch -- [ann::led_phase] {
        1 { append out " — priority scan running now" }
        2 { append out " — background walk running now (throttled)" }
    }
    if {$capped_prio} { append out "\npriority cap reached: a fast folder has more entries than its slice" }
    if {$capped_bulk} { append out "\nfile cap reached ([ann::ncomma $files_bulk] background rows) — narrow the scan folders if results look incomplete" }
    if {$bulk_aborted} { append out "\nthe last background walk yielded to newer work; it resumes automatically" }
    if {$errors} { append out "\n$errors error(s) during the last scan — see ann.log" }
    return $out
}

# Load the real ann icon (multiple sizes) into the titlebar + taskbar. Best-effort
# and idempotent: a missing/unreadable resource just leaves Tk's default.
proc ann::set_window_icon {} {
    set imgs {}
    foreach {img file} {ann_ico16 icon16.png ann_ico32 icon32.png ann_icoBig icon.png} {
        set p [ann::resource $file]
        if {$p eq ""} continue
        if {[lsearch [image names] $img] < 0 && [catch {image create photo $img -file $p}]} continue
        if {[lsearch [image names] $img] >= 0} { lappend imgs $img }
    }
    if {[llength $imgs]} { catch {wm iconphoto . -default {*}$imgs} }
}

# resolve a bundled resource by name across dev (loose files) and the built exe
# (zipfs), returning "" when absent.
proc ann::resource {name} {
    foreach cand [list \
            [file join $::ann::dir resources $name] \
            //zipfs:/app/resources/$name \
            [file join [file dirname [file normalize [info script]]] resources $name]] {
        if {[file exists $cand]} { return $cand }
    }
    return ""
}

# Build the FIXED set of row slots (DESIGN §9.4 virtualization: only these
# result_limit rows ever hold live Tk photo images; images are refilled from the
# C-side RGBA LRU on each render). Re-entrant: destroys + rebuilds on limit change.
proc ann::make_rows {} {
    variable C ; variable result_limit
    foreach w [winfo children .c.list] { if {$w ne ".c.list.empty"} { destroy $w } }
    for {set i 0} {$i < $result_limit} {incr i} {
        if {[lsearch [image names] annimg$i] < 0} { image create photo annimg$i }
        set f [frame .c.list.row$i -bg $C(bg)]
        label $f.ic -image annimg$i -bg $C(bg) -width 36 -anchor center
        frame $f.tx -bg $C(bg)
        label $f.tx.name -bg $C(bg) -fg $C(ink)   -anchor w -font annRowName
        label $f.tx.sub  -bg $C(bg) -fg $C(muted) -anchor w -font annRowSub
        pack $f.tx.name -fill x -anchor w
        pack $f.tx.sub  -fill x -anchor w
        pack $f.ic -side left -padx {2 8} -pady 3
        pack $f.tx -side left -fill x -expand 1 -pady 3
        # mouse: click selects, double-click launches (user decision; the
        # keyboard path stays primary); the wheel scrolls the viewport
        foreach w [list $f $f.ic $f.tx $f.tx.name $f.tx.sub] {
            bind $w <Button-1>        [list ann::row_click $i]
            bind $w <Double-Button-1> [list ann::row_dblclick $i]
            bind $w <Button-3>        [list ann::row_context $i %X %Y]
            bind $w <MouseWheel>      { ann::wheel %D }
        }
    }
    bind .c.list <MouseWheel> { ann::wheel %D }
    catch {bind .c.q <MouseWheel> { ann::wheel %D }}
}

proc ann::row_click {i} {
    set ri [expr {$::ann::view_offset + $i}]      ;# row -> results index
    if {$ri >= [llength $::ann::results]} return
    set ::ann::sel $ri
    ann::panel_close
    ann::render_results
}
proc ann::row_dblclick {i} {
    set ri [expr {$::ann::view_offset + $i}]
    if {$ri >= [llength $::ann::results]} return
    set ::ann::sel $ri
    ann::launch_selected
}

proc ann::row_bg {i color} {
    set f .c.list.row$i
    if {![winfo exists $f]} return
    foreach w [list $f $f.ic $f.tx $f.tx.name $f.tx.sub] { $w configure -bg $color }
}

# subtitle line for a result (kind-dependent; %envvar% targets expanded for display)
proc ann::subtitle {r} {
    if {[dict exists $r subtitle]} { return [dict get $r subtitle] }
    switch [dict get $r kind] {
        shortcut {
            set t [dict get $r target]
            if {$t eq ""} { return "Application" }
            if {[string match "%*" $t] && [ann::has annplat::expand_env]} {
                catch { set t [annplat::expand_env $t] }
            }
            return $t
        }
        uwp      { return "App (Store)" }
        window   { return [dict get $r target] }
        system_cmd { return "System command" }
        default  { return [dict get $r path] }
    }
}

# which icon to show for a result (consumed by annicon::fill)
proc ann::icon_spec {r} {
    if {[dict exists $r iconspec]} { return [dict get $r iconspec] }
    switch [dict get $r kind] {
        uwp        { return "aumid:[dict get $r path]" }
        window     { return "hwnd:[dict get $r path]" }
        system_cmd {
            if {[ann::is_destructive [dict get $r path]]} { return "stock:shield" }
            return "stock:pc"
        }
        folder     { return [dict get $r path] }
        default    { return [dict get $r path] }
    }
}

proc ann::render_results {} {
    variable C ; variable results ; variable sel ; variable indexing
    variable result_limit ; variable view_offset
    if {![winfo exists .c.list]} return
    # restart the deferred-icon pass for this render generation (stale passes
    # self-abort on the generation check)
    set ::ann::icon_defer {}
    incr ::ann::render_gen
    after idle [list ann::fill_deferred $::ann::render_gen]
    set n [llength $results]
    # clamp the viewport window into the result list
    set maxoff [expr {$n > $result_limit ? $n - $result_limit : 0}]
    if {$view_offset > $maxoff} { set view_offset $maxoff }
    if {$view_offset < 0}       { set view_offset 0 }
    if {$n == 0} {
        set q [expr {[winfo exists .c.q] ? [.c.q get] : ""}]
        .c.list.empty configure -text [expr {$indexing ? "  indexing…" :
            [expr {$q ne "" ? "  No results"
                 : "  Nothing launched yet — what you start with ann appears here"}]}]
        pack .c.list.empty -fill x -pady 8
        for {set i 0} {$i < $result_limit} {incr i} { pack forget .c.list.row$i }
    } else {
        pack forget .c.list.empty
        for {set i 0} {$i < $result_limit} {incr i} {
            set f .c.list.row$i
            set ri [expr {$view_offset + $i}]            ;# results index this row shows
            if {$ri < $n} {
                set r [lindex $results $ri]
                set maxpx [expr {$::ann::window_width - 110}]
                $f.tx.name configure -text [ann::fit annRowName [dict get $r name] $maxpx end]
                $f.tx.sub  configure -text [ann::fit annRowSub [ann::subtitle $r] $maxpx middle]
                if {[ann::has annicon::fill]} {
                    # render stays in the §6.6 budget: paint from CACHE only; a
                    # miss shows a stock placeholder now and the real icon is
                    # extracted in a deferred idle pass (ann::fill_deferred)
                    set spec [ann::icon_spec $r]
                    set st "nocache"
                    catch { set st [annicon::fill annimg$i $spec 32 -cached] }
                    if {$st eq "nocache"} {
                        catch {annicon::fill annimg$i stock:doc 32}
                        lappend ::ann::icon_defer [list $i $spec]
                    }
                }
                ann::row_bg $i [expr {$ri == $sel ? $C(sel) : $C(bg)}]
                pack $f -fill x
            } else {
                pack forget $f
            }
        }
    }
    ann::update_vscroll
    ann::update_foot
}

# Scrollbar feed + autohide — the same logic as els::update_vscroll: the bar is
# visible only while the view is partial.
proc ann::update_vscroll {} {
    variable results ; variable result_limit ; variable view_offset
    if {![winfo exists .c.vs]} return
    set n [llength $results]
    if {$n <= $result_limit} {
        .c.vs set 0 1
        grid remove .c.vs
        return
    }
    set first [expr {double($view_offset) / $n}]
    set last  [expr {double($view_offset + $result_limit) / $n}]
    .c.vs set $first $last
    if {$first > 0.0001 || $last < 0.9999} { grid .c.vs } else { grid remove .c.vs }
}

# scroll the viewport (selection stays put, exactly like a listbox)
proc ann::scroll_to {off} {
    variable results ; variable result_limit ; variable view_offset
    set n [llength $results]
    set maxoff [expr {$n > $result_limit ? $n - $result_limit : 0}]
    if {$off < 0} { set off 0 }
    if {$off > $maxoff} { set off $maxoff }
    if {$off == $view_offset} return
    set view_offset $off
    ann::render_results
}
# the ttk scrollbar's -command (yview protocol: moveto f | scroll k units|pages)
proc ann::scroll_cmd {args} {
    variable view_offset ; variable result_limit ; variable results
    switch -- [lindex $args 0] {
        moveto { ann::scroll_to [expr {int(round([lindex $args 1] * [llength $results]))}] }
        scroll {
            set k [lindex $args 1]
            set unit [expr {[lindex $args 2] eq "pages" ? $result_limit : 1}]
            ann::scroll_to [expr {$view_offset + $k * $unit}]
        }
    }
}
# mouse wheel: float division like els::wheel (integer / floors toward -inf,
# which made one direction scroll and the other not); 3 rows per notch
proc ann::wheel {delta} {
    if {$::ann::panel_open} return
    ann::scroll_to [expr {$::ann::view_offset - int($delta / 120.0 * 3)}]
}

# Deferred icon extraction: one miss per idle tick, abandoned the moment a newer
# render supersedes this generation. Keeps keystroke->render inside the §6.6
# budget; first-seen icons pop in a tick later (then live in the C LRU forever).
proc ann::fill_deferred {gen} {
    if {$gen != $::ann::render_gen} return
    if {![llength $::ann::icon_defer]} return
    set entry [lindex $::ann::icon_defer 0]
    set ::ann::icon_defer [lrange $::ann::icon_defer 1 end]
    lassign $entry i spec
    if {[winfo exists .c.list.row$i] && [ann::has annicon::fill]} {
        catch {annicon::fill annimg$i $spec 32}
    }
    after 10 [list ann::fill_deferred $gen]
}

# Ellipsize text to fit maxpx in the given named font; mode `middle` keeps the
# head and tail (right for paths), `end` keeps the head (right for names).
proc ann::fit {fontspec text maxpx {mode end}} {
    if {[font measure $fontspec $text] <= $maxpx} { return $text }
    set n [string length $text]
    for {set keep [expr {$n - 1}]} {$keep > 8} {incr keep -1} {
        if {$mode eq "middle"} {
            set head [expr {$keep * 3 / 5}]
            set cand "[string range $text 0 [expr {$head - 1}]]…[string range $text end-[expr {$keep - $head - 1}] end]"
        } else {
            set cand "[string range $text 0 [expr {$keep - 1}]]…"
        }
        if {[font measure $fontspec $cand] <= $maxpx} { return $cand }
    }
    return "[string range $text 0 7]…"
}

proc ann::update_foot {} {
    if {![winfo exists .status.in.info]} return
    set n [llength $::ann::results]
    set extra [expr {$::ann::indexing ? "  ·  indexing…" : ""}]
    .status.in.info configure -text "$n result[expr {$n == 1 ? {} : {s}}]$extra"
    # keep the steady hint in the left cell when no transient message is active
    if {$::ann::status_after eq "" && [winfo exists .status.in.msg]} {
        .status.in.msg configure -text [ann::status_idle_text] -foreground $::ann::C(muted)
    }
}

proc ann::position {} {
    variable window_width
    set w $window_width
    if {[ann::has annplat::active_monitor_rect] && ![catch {annplat::active_monitor_rect} r] && [llength $r] == 4} {
        lassign $r rx ry rw rh
    } else {
        set rx 0 ; set ry 0 ; set rw [winfo screenwidth .] ; set rh [winfo screenheight .]
    }
    set x [expr {$rx + ($rw - $w) / 2}]
    set y [expr {$ry + int($rh * 0.18)}]
    # POSITION ONLY — never force a size, so the toplevel keeps sizing itself to
    # its content and the popup grows/shrinks downward naturally (§9.1).
    wm geometry . +${x}+${y}
}

proc ann::show {} {
    # Build the fresh content BEFORE mapping, so the previous session's query and
    # results never flash (spotlight-style: each invocation starts clean).
    .c.q delete 0 end
    set ::ann::last_query " "
    ann::do_query
    ann::position
    # subtle whole-window fade-in (§9.2: -alpha is the ONE sanctioned use).
    # Skipped when alpha is already forced low (the test harness runs at 0.0).
    set fade [expr {[catch {wm attributes . -alpha} a] == 0 && $a >= 0.99}]
    if {$fade} { catch {wm attributes . -alpha 0.0} }
    wm deiconify .
    raise .
    update idletasks
    focus -force .c.q
    if {[ann::has annplat::force_foreground]} { catch {annplat::force_foreground [winfo id .]} }
    # (no DWM corner request needed: the real titlebar's frame provides them)
    ann::hook_titlebar_menu          ;# frame exists now; install once
    if {$fade} { ann::fade_in 0.25 }
    set ::ann::visible 1
}

proc ann::fade_in {a} {
    if {!$::ann::visible && $a > 0.3} return     ;# hidden mid-fade: stop
    if {$a >= 1.0} { catch {wm attributes . -alpha 1.0} ; return }
    catch {wm attributes . -alpha $a}
    after 16 [list ann::fade_in [expr {$a + 0.25}]]
}

proc ann::hide {} {
    ann::panel_close
    catch {wm withdraw .}
    # restore full alpha if a fade was interrupted (never touch the test harness's
    # deliberate 0.0)
    catch { if {[wm attributes . -alpha] > 0.05} { wm attributes . -alpha 1.0 } }
    set ::ann::visible 0
}

# ---- search (debounced) + navigation + launch -------------------------------
proc ann::on_query {} {
    variable query_after ; variable last_query
    set q [.c.q get]
    if {$q eq $last_query} return        ;# arrows/Enter don't change text -> no requery
    set last_query $q
    if {$query_after ne ""} { catch {after cancel $query_after} }
    set query_after [after 15 ann::do_query]   ;# DESIGN §6.6 debounce ~10-20ms
}

# Source-priority bucketing with reserved slots (DESIGN §6.5): apps -> running
# windows -> files, but reserve up to one window and one file slot so a small
# result_limit dominated by apps still surfaces a matching window/file; reclaim
# any unused reserved slot back to the priority fill.
# is this catalog FILE "executable stuff"? (extension-based, §6.5 bucket 2)
proc ann::is_executable {r} {
    expr {[string tolower [file extension [dict get $r path]]] in \
        {.exe .com .bat .cmd .msi .msc .lnk .url .appref-ms}}
}

# Bucket order (owner decision, supersedes the old apps->windows->files):
#   1. commands (system commands + any future ann commands)
#   2. executable stuff (apps, running windows, executable files)
#   3. openable files
#   4. folders
# Score-ranked WITHIN each bucket (stable sort: equal scores keep the C-ranked
# arrival order) and NO reserved slots — relevance decides inside a bucket, the
# bucket decides between natures. Born from a real failure: a portable
# firefox.exe (exact name, files bucket) sat below eight Office shortcuts whose
# TARGET PATHS merely contained f-i-r-e-f-o-x as a subsequence — the penalized
# target-fallback recall must never outrank an exact name match through bucket
# privilege.
proc ann::bucketize {cands limit} {
    set cmds {} ; set execs {} ; set files {} ; set dirs {}
    # default arm = shortcut/uwp/app/provider rows (comments must stay OUT of a
    # switch pattern list: Tcl parses them as patterns)
    foreach c $cands {
        switch -- [dict get $c kind] {
            system_cmd { lappend cmds  $c }
            window     { lappend execs $c }
            folder     { lappend dirs  $c }
            file       {
                if {[ann::is_executable $c]} { lappend execs $c } \
                else                         { lappend files $c }
            }
            default    { lappend execs $c }
        }
    }
    set out {}
    foreach v {cmds execs files dirs} {
        set pairs [lmap c [set $v] {
            list [expr {[dict exists $c score] ? [dict get $c score] : 0}] $c
        }]
        lappend out {*}[lmap p [lsort -real -decreasing -index 0 $pairs] { lindex $p 1 }]
    }
    return [lrange $out 0 [expr {$limit - 1}]]
}

# Resolve an alias TARGET (§6.7/§11.4: a catalog path, a plain file/folder path,
# or a command prefix) into one result row carrying the given score. Returns ""
# when the target resolves to nothing. Shared by the exact top-pin (score 1e9)
# and the partial-recall path (honest fuzzy score).
proc ann::alias_item {kw target score} {
    if {$::ann::reader ne "" && [ann::has anndb::get]} {
        set item ""
        catch { set item [anndb::get $::ann::reader $target] }
        if {$item ne ""} {
            dict set item score $score
            return $item
        }
    }
    if {[file exists $target]} {
        # the whole target string is a real path (spaces included)
        return [dict create id "alias:$kw" name [file tail $target] path $target \
            kind [expr {[file isdirectory $target] ? "folder" : "file"}] \
            launch path target $target score $score]
    }
    if {![catch {lindex $target 0} word0] && $word0 ne "" \
            && [llength [info commands $word0]]} {
        # a command prefix (one word or more) -> a tclproc result
        return [dict create id "alias:$kw" name $kw path "alias:$kw" \
            kind app launch tclproc target "alias" score $score script $target]
    }
    return ""
}

# Apply the alias legs of the HYBRID model (§6.7) then bucket. The C search
# already returns candidates sorted by the fuzzy+frecency blend. An EXACT alias
# match pins its target to the top of its bucket regardless of fuzzy competition;
# a PARTIAL/typo'd match of a keyword recalls the target at its honest fuzzy
# score, competing like any other candidate (no pin) — the §6.7 recall promise,
# implemented query-time over the config-scale alias table (see the DESIGN §6.7
# amendment: search_text folding would cross the single-writer boundary).
proc ann::rank {cands query} {
    set nq [string tolower [string trim $query]]
    if {$nq ne "" && [dict exists $::ann::aliases $nq]} {
        set item [ann::alias_item $nq [dict get $::ann::aliases $nq] 1e9]
        if {$item ne ""} {
            set tpath [dict get $item path]
            set cands [lmap c $cands { if {[dict get $c path] eq $tpath} continue ; set c }]
            set cands [linsert $cands 0 $item]
        }
    } elseif {$nq ne ""} {
        dict for {kw target} $::ann::aliases {
            set s [ann::fuzzy $nq $kw]
            if {$s <= 0} continue
            set item [ann::alias_item $kw $target $s]
            if {$item eq ""} continue
            set tpath [dict get $item path]
            set keep 1
            set cands [lmap c $cands {
                if {[dict get $c path] eq $tpath} {
                    set cs [expr {[dict exists $c score] ? [dict get $c score] : 0}]
                    if {$cs >= $s} { set keep 0 ; set c } else continue
                } else { set c }
            }]
            if {$keep} { lappend cands $item }
        }
    }
    set out [ann::bucketize $cands $::ann::result_max]
    # Zero-results fallback (docs/farr-gap-analysis.md #1): a non-empty query
    # that matches nothing still offers exactly ONE row — "Run: <query>" — so
    # the box doubles as the Run box (\\server\share, ms-settings:, anything on
    # PATH). Inert unless invoked; no toggle, per the no-hedge-options rule.
    if {![llength $out]} {
        set rq [string trim $query]
        if {$rq ne ""} {
            return [list [dict create id "run:$rq" name "Run: $rq" path $rq \
                kind run launch run target $rq score 0 \
                iconspec stock:pc subtitle "run as typed"]]
        }
    }
    return $out
}

# run the config-registered providers (§11.3) — bounded, isolated failures (§15.1).
# Rows are NORMALIZED (every key downstream code reads gets a default) and SCORED
# so provider results genuinely compete in the ranking (§11.4 promises they are
# "merged into the candidate set BEFORE fuzzy scoring").
proc ann::provider_candidates {query} {
    set out {}
    dict for {name procname} $::ann::providers {
        set t0 [clock microseconds]
        if {[catch {uplevel #0 [list $procname $query]} rows]} {
            ann::log ERROR "provider '$name' failed (dropped this keystroke): $rows"
            continue
        }
        set dt [expr {([clock microseconds] - $t0) / 1000.0}]
        if {$dt > 50} { ann::log WARN "provider '$name' took [format %.1f $dt] ms (budget 50)" }
        foreach r $rows {
            if {[catch {dict get $r name} nm] || $nm eq ""} { continue }   ;# malformed: drop
            # defaults for every key the pipeline reads
            if {![dict exists $r kind]}   { dict set r kind app }
            if {![dict exists $r launch]} { dict set r launch tclproc }
            if {![dict exists $r path]}   { dict set r path "cfg:$nm" }
            if {![dict exists $r id]}     { dict set r id [dict get $r path] }
            if {![dict exists $r target]} { dict set r target "" }
            if {![dict exists $r score] || [dict get $r score] == 0} {
                dict set r score [expr {$query eq "" ? 0.0 : [ann::fuzzy $query $nm]}]
            }
            lappend out $r
        }
    }
    return $out
}

# live windows provider (DESIGN §7.3): EnumWindows snapshot cached ~250 ms, fuzzy
# scored against the query, merged as kind=window candidates.
proc ann::windows_get {} {
    variable win_cache ; variable win_cache_ts
    if {![ann::has annplat::windows]} { return {} }
    set now [clock milliseconds]
    if {$now - $win_cache_ts > 250} {
        if {[catch {annplat::windows} win_cache]} { set win_cache {} }
        set win_cache_ts $now
    }
    return $win_cache
}

proc ann::window_candidates {query} {
    set out {}
    foreach w [ann::windows_get] {
        set title [dict get $w title]
        if {$query eq ""} {
            set score 0.0
        } else {
            set score [ann::fuzzy $query $title]
            if {$score <= 0} continue
        }
        lappend out [list $score [dict create \
            id "win:[dict get $w hwnd]" name $title path [dict get $w hwnd] \
            kind window launch window target [dict get $w exe] score $score]]
    }
    return [lmap p [lsort -real -decreasing -index 0 $out] { lindex $p 1 }]
}

proc ann::do_query {{mode -reset}} {
    variable reader
    if {![winfo exists .c.q]} return
    set q [.c.q get]
    set keepid ""
    if {$mode eq "-keepsel" && $::ann::sel < [llength $::ann::results]} {
        set keepid [dict get [lindex $::ann::results $::ann::sel] id]
    }
    set cands {}
    if {$reader ne "" && [ann::has anndb::search]} {
        if {[catch {anndb::search $reader $q 80} cands]} {
            ann::log ERROR "search '$q': $cands" ; set cands {}
        }
    }
    lappend cands {*}[ann::window_candidates $q]
    lappend cands {*}[ann::provider_candidates $q]
    set ::ann::results [ann::rank $cands $q]
    set ::ann::sel 0
    set ::ann::view_offset 0
    if {$keepid ne ""} {
        set i 0
        foreach r $::ann::results {
            if {[dict get $r id] eq $keepid} { set ::ann::sel $i ; break }
            incr i
        }
        # keep the restored selection inside the viewport
        if {$::ann::sel >= $::ann::result_limit} {
            set ::ann::view_offset [expr {$::ann::sel - $::ann::result_limit + 1}]
        }
    }
    if {$mode ne "-keepsel"} { ann::panel_close }
    ann::render_results
}

proc ann::move_sel {d} {
    variable results ; variable sel ; variable result_limit ; variable view_offset
    set n [llength $results]
    if {$n == 0} return
    set sel [expr {($sel + $d) % $n}]
    if {$sel < 0} { incr sel $n }
    # keep the selection inside the viewport (scroll the window to it)
    if {$sel < $view_offset} { set view_offset $sel }
    if {$sel >= $view_offset + $result_limit} {
        set view_offset [expr {$sel - $result_limit + 1}]
    }
    ann::render_results
}

# ---- result invocation (the Enter action, by launch kind) -------------------
proc ann::launch_selected {} {
    variable results ; variable sel
    if {![llength $results]} return
    ann::invoke_result [lindex $results $sel]
}

proc ann::invoke_result {r} {
    set launch [dict get $r launch]
    set path   [dict get $r path]
    ann::log INFO "invoke '[dict get $r name]' ($launch -> $path)"
    switch -- $launch {
        window {
            # revalidated in C; a stale HWND silently drops + refreshes (§7.3)
            if {![ann::has annplat::activate] || ![annplat::activate $path]} {
                ann::log INFO "stale window $path: dropped, re-enumerating"
                set ::ann::win_cache_ts 0
                ann::do_query
                return
            }
            ann::hide
        }
        syscmd {
            if {$path eq "syscmd:quit"} { ann::quit ; return }
            if {[ann::is_destructive $path] && $::ann::confirm_destructive} {
                # destructive commands confirm INSIDE the panel (§9.5/§15.4)
                ann::panel_toggle
                return
            }
            ann::run_syscmd $r
        }
        tclproc {
            # config-provided result (§11.3): its -launch script is the action
            if {[dict exists $r script] && [dict get $r script] ne ""} {
                if {[catch {uplevel #0 [dict get $r script]} e]} {
                    ann::log ERROR "provider launch: $e"
                    ann::status "launch failed: $e" error
                    return
                }
                ann::hide
            }
        }
        run {
            # the zero-results "Run:" row: split Run-box style in C (pure,
            # tested), execute through the ordinary launch path
            if {![ann::has annplat::run_split] || ![ann::has annplat::launch]} {
                ann::status "launch unavailable" error ; return
            }
            lassign [annplat::run_split $path] rf ra
            if {[catch {annplat::launch path $rf $ra} e]} {
                ann::log ERROR "run '$path': $e"
                ann::status "run failed: $e" error
                return
            }
            ann::hide
        }
        default {
            if {![ann::has annplat::launch]} { ann::status "launch unavailable" error ; return }
            if {[catch {annplat::launch $launch $path} e]} {
                ann::log ERROR "launch failed: $e"
                ann::status "launch failed: $e" error
                return
            }
            if {[ann::has annindex::record_usage]} { catch {annindex::record_usage [dict get $r id]} }
            ann::hide
        }
    }
}

proc ann::is_destructive {id} {
    return [expr {$id in {syscmd:shutdown syscmd:restart syscmd:emptybin}}]
}

proc ann::run_syscmd {r} {
    set id [dict get $r path]
    if {$id eq "syscmd:quit"} { ann::quit ; return }
    if {![ann::has annplat::syscmd]} { ann::status "system commands unavailable" error ; return }
    if {[catch {annplat::syscmd $id} e]} {
        ann::log ERROR "syscmd $id: $e"
        ann::status "failed: $e" error
        return
    }
    if {[ann::has annindex::record_usage]} { catch {annindex::record_usage [dict get $r id]} }
    ann::hide
}

# ---- the action panel (Tab / Ctrl+K — DESIGN §9.5) ---------------------------
proc ann::copy_to_clipboard {text what} {
    clipboard clear
    clipboard append -- $text
    ann::status "$what copied"
}

# kind-contextual actions for a result: list of {label <l> script <s> destructive 0|1}
proc ann::actions_for {r} {
    set kind [dict get $r kind]
    set path [dict get $r path]
    set name [dict get $r name]
    set target [dict get $r target]
    set real [expr {$target ne "" ? $target : $path}]
    # SLGP_RAWPATH targets may carry %VAR% — expand for location/copy actions
    if {[string match "%*" $real] && [ann::has annplat::expand_env]} {
        catch { set real [annplat::expand_env $real] }
    }
    set acts {}
    switch -- $kind {
        shortcut - app {
            lappend acts [dict create label "Launch" script [list ann::invoke_result $r] destructive 0]
            lappend acts [dict create label "Run as administrator" script [list ann::act_runas $real] destructive 0]
            lappend acts [dict create label "Open file location" script [list ann::act_open_location $real] destructive 0]
            lappend acts [dict create label "Copy path" script [list ann::copy_to_clipboard $real "Path"] destructive 0]
            lappend acts [dict create label "Copy name" script [list ann::copy_to_clipboard $name "Name"] destructive 0]
        }
        uwp {
            lappend acts [dict create label "Launch" script [list ann::invoke_result $r] destructive 0]
            lappend acts [dict create label "Copy name" script [list ann::copy_to_clipboard $name "Name"] destructive 0]
        }
        file {
            lappend acts [dict create label "Open" script [list ann::invoke_result $r] destructive 0]
            lappend acts [dict create label "Open containing folder" script [list ann::act_open_location $path] destructive 0]
            lappend acts [dict create label "Copy path" script [list ann::copy_to_clipboard $path "Path"] destructive 0]
            lappend acts [dict create label "Copy name" script [list ann::copy_to_clipboard $name "Name"] destructive 0]
        }
        folder {
            lappend acts [dict create label "Open" script [list ann::invoke_result $r] destructive 0]
            lappend acts [dict create label "Copy path" script [list ann::copy_to_clipboard $path "Path"] destructive 0]
        }
        window {
            lappend acts [dict create label "Activate" script [list ann::invoke_result $r] destructive 0]
            lappend acts [dict create label "Close window" script [list ann::act_close_window $path] destructive 0]
            lappend acts [dict create label "Copy title" script [list ann::copy_to_clipboard $name "Title"] destructive 0]
        }
        system_cmd {
            lappend acts [dict create label "Run" script [list ann::run_syscmd $r] \
                destructive [expr {[ann::is_destructive $path] && $::ann::confirm_destructive}]]
        }
    }
    # config-registered actions for this kind land here (M8, §11.3)
    foreach a [ann::config_actions_for $kind $r] { lappend acts $a }
    # the global section (§9.6): quit is always reachable
    lappend acts [dict create label "Quit ann" script [list ann::quit] destructive 0]
    return $acts
}
# config-registered panel actions whose -kinds include this result's kind (§11.3)
proc ann::config_actions_for {kind r} {
    set out {}
    foreach entry $::ann::cfg_actions {
        lassign $entry kinds label procname
        if {$kind in $kinds} {
            lappend out [dict create label $label script [list $procname $r] destructive 0]
        }
    }
    return $out
}

proc ann::act_runas {path} {
    if {![ann::has annplat::runas]} { ann::status "unavailable" error ; return }
    if {[catch {annplat::runas $path} e]} {
        ann::log ERROR "runas: $e" ; ann::status "failed: $e" error ; return
    }
    if {$e eq "cancelled"} { ann::status "elevation cancelled" ; return }
    ann::hide
}
proc ann::act_open_location {path} {
    if {![ann::has annplat::open_folder_select]} { ann::status "unavailable" error ; return }
    if {[catch {annplat::open_folder_select $path} e]} {
        ann::log ERROR "open location: $e" ; ann::status "failed: $e" error ; return
    }
    ann::hide
}
proc ann::act_close_window {hwnd} {
    if {![ann::has annplat::close_window] || ![annplat::close_window $hwnd]} {
        ann::log INFO "stale window $hwnd on close: dropped"
    }
    set ::ann::win_cache_ts 0
    after 150 ann::do_query        ;# let the window die, then refresh the list
}

# The action menu is a CLASSIC native context menu now (owner decision,
# supersedes the custom §9.5 panel): Tab/Ctrl+K posts it at the selected row,
# right-click posts it at the pointer. Navigation/Enter/Esc are the native
# menu's own. Destructive actions use the classic cascade-confirm idiom — the
# item is a submenu whose single child executes — so a slip of the finger can
# never fire them and no dialog is ever needed.
proc ann::actions_menu {r} {
    catch {destroy .actmenu}
    menu .actmenu -tearoff 0
    # the Map/Unmap pair keeps panel_open truthful for the interaction guards
    # (wheel scrolling, catalog-update refresh suppression)
    bind .actmenu <Map>   { set ::ann::panel_open 1 }
    bind .actmenu <Unmap> { set ::ann::panel_open 0 }
    set i 0
    foreach a [ann::actions_for $r] {
        set lbl [dict get $a label]
        set cmd [list ann::action_run $lbl [dict get $a script]]
        if {[dict get $a destructive]} {
            menu .actmenu.c$i -tearoff 0
            .actmenu.c$i add command -label "Confirm: $lbl" -command $cmd
            .actmenu add cascade -label "$lbl..." -menu .actmenu.c$i
        } else {
            .actmenu add command -label $lbl -command $cmd
        }
        incr i
    }
    return .actmenu
}

proc ann::action_run {lbl scr} {
    if {[catch {uplevel #0 $scr} e]} {
        ann::log ERROR "action '$lbl': $e"
        ann::status "action failed: $e" error
    }
}

# Tab / Ctrl+K: the context menu of the SELECTED row, posted at that row
proc ann::panel_toggle {} {
    variable results ; variable sel ; variable result_limit ; variable view_offset
    if {![llength $results]} return
    set m [ann::actions_menu [lindex $results $sel]]
    set i [expr {$sel - $view_offset}]
    set row .c.list.row$i
    if {$i >= 0 && $i < $result_limit && [winfo exists $row] && [winfo ismapped $row]} {
        set x [expr {[winfo rootx $row] + [winfo width $row] / 3}]
        set y [expr {[winfo rooty $row] + [winfo height $row] - 4}]
    } else {
        set x [winfo pointerx .] ; set y [winfo pointery .]
    }
    tk_popup $m $x $y
}

proc ann::panel_close {} {
    set ::ann::panel_open 0
    catch {.actmenu unpost}
}

# right-click on a row: select it, then the same classic menu at the pointer
proc ann::row_context {i X Y} {
    set ri [expr {$::ann::view_offset + $i}]
    if {$ri >= [llength $::ann::results]} return
    set ::ann::sel $ri
    ann::render_results
    tk_popup [ann::actions_menu [lindex $::ann::results $ri]] $X $Y
}

# ============================================================================
#  THE APP MENU (under the titlebar icon + on the tray), TRAY, SETTINGS DIALOG
#  (owner decisions amending DESIGN §10.2: ann lives in the system tray; the
#  titlebar icon opens ann's own menu instead of the standard system menu.)
# ============================================================================

# build (fresh) the ann menu used by both the titlebar icon and the tray
proc ann::app_menu {} {
    catch {destroy .annmenu}
    menu .annmenu -tearoff 0
    .annmenu add command -label "Settings…"    -command ann::settings_open
    .annmenu add command -label "Rescan index" -command {catch {annindex::rescan}}
    .annmenu add separator
    .annmenu add command -label "Quit ann"     -command ann::quit
    return .annmenu
}

# the titlebar-icon click (via annplat::hook_sysmenu): post under the icon
proc ann::titlebar_menu {} {
    set m [ann::app_menu]
    tk_popup $m [expr {[winfo rootx .] - 6}] [winfo rooty .]
}

# hook the frame window once it exists (called from show; idempotent)
proc ann::hook_titlebar_menu {} {
    variable sysmenu_hooked
    if {$sysmenu_hooked || ![ann::has annplat::hook_sysmenu]} return
    set frame [wm frame .]
    if {$frame == 0} return
    if {[catch {annplat::hook_sysmenu $frame ann::titlebar_menu} e]} {
        ann::log WARN "titlebar menu hook failed: $e"
        return
    }
    # No taskbar button (owner decision, §9.1): a hidden owner keeps the popup
    # off the taskbar while preserving the normal titlebar (the tray is ann's
    # presence; Alt-Tab still lists the window while it is up).
    if {[ann::has annplat::own_window]} {
        if {[catch {annplat::own_window $frame} e]} {
            ann::log WARN "taskbar detach failed: $e"
        }
    }
    set sysmenu_hooked 1
}

# ---- system tray (tk systray; one icon per interp) ---------------------------
proc ann::tray_setup {} {
    if {[catch {tk systray exists} ex]} { ann::log WARN "no systray support: $ex" ; return 0 }
    if {$ex} { return 1 }
    set img ""
    set p [ann::resource icon16.png]
    if {$p ne "" && ![catch {image create photo anntrayicon -file $p} i]} { set img $i }
    if {$img eq ""} { ann::log WARN "tray icon image not found" ; return 0 }
    if {[catch {
        tk systray create -image $img -text "ann $::ann::version — $::ann::hotkey" \
            -button1 ann::tray_click -button3 ann::tray_menu
    } e]} {
        ann::log WARN "tray icon failed: $e"
        return 0
    }
    ann::log INFO "tray icon created"
    return 1
}
proc ann::tray_click {} { ann::show }
proc ann::tray_menu {} {
    set m [ann::app_menu]
    tk_popup $m [winfo pointerx .] [winfo pointery .]
}
proc ann::tray_teardown {} { catch {tk systray destroy} }

# ---- the Settings dialog ------------------------------------------------------
# settings_build creates the dialog WITHDRAWN (tests drive it headlessly);
# settings_open centers + shows it.
proc ann::settings_build {} {
    variable C
    catch {destroy .settings}
    toplevel .settings -bg $C(bg)
    wm withdraw .settings
    wm title .settings "ann Settings"
    wm transient .settings .
    wm resizable .settings 0 0
    wm protocol .settings WM_DELETE_WINDOW {destroy .settings}

    # els dialog conventions throughout: ttk family, -padding 12, Dialog.TButton
    ann::init_scrollbar_style          ;# styles live here; idempotent
    set f [ttk::frame .settings.f -padding 12]
    pack $f -fill both -expand 1

    ttk::label $f.t1 -text "Indexed folders" -font annName -anchor w
    pack $f.t1 -fill x -pady {0 4}

    frame $f.lf -bg $C(panel) -highlightthickness 1 -highlightbackground $C(hair)
    listbox $f.lf.list -bg $C(panel) -fg $C(ink) -relief flat -highlightthickness 0 \
        -font annSub -height 7 -width 64 -activestyle none \
        -selectbackground $C(sel) -selectforeground $C(ink) \
        -yscrollcommand ann::settings_vs_set
    ttk::scrollbar $f.lf.sb -orient vertical -command [list $f.lf.list yview]
    pack $f.lf.list -side left -fill both -expand 1
    pack $f.lf -fill x

    ttk::frame $f.lb
    ttk::button $f.lb.add -text "Add folder…" -style Dialog.TButton -command ann::settings_add_folder
    ttk::button $f.lb.rm  -text "Remove"      -style Dialog.TButton -command ann::settings_remove_folder
    ttk::button $f.lb.pri -text "Priority"    -style Dialog.TButton -command ann::settings_toggle_priority
    ttk::button $f.lb.def -text "Add Defaults" -style Dialog.TButton -command ann::settings_add_defaults
    pack $f.lb.add $f.lb.rm $f.lb.pri $f.lb.def -side left -padx {0 6} -pady 6
    pack $f.lb -fill x
    ttk::label $f.leg -anchor w -foreground $C(muted) \
        -text "● priority: scanned first and fast   ○ background: scanned slowly, last"
    pack $f.leg -fill x -pady {0 4}

    # coverage guidance (§7.2): priority locations not under any listed root
    ttk::frame $f.cov
    ttk::label $f.cov.w -text "⚠" -foreground $C(accentText)
    ttk::label $f.cov.t -text "" -anchor w
    ttk::button $f.cov.inc -text "Include" -style Dialog.TButton -command ann::settings_include_uncovered
    grid $f.cov.w -row 0 -column 0 -padx {0 4}
    grid $f.cov.t -row 0 -column 1 -sticky we
    grid $f.cov.inc -row 0 -column 2 -padx {8 0}
    grid columnconfigure $f.cov 1 -weight 1
    pack $f.cov -fill x -pady {0 4}

    ann::settings_set_pairs [ann::settings_current_roots]

    ttk::frame $f.o
    ttk::label $f.o.hkl -text "Hotkey" -anchor w
    ttk::entry $f.o.hk -width 18 -font annSub
    $f.o.hk insert 0 $::ann::hotkey
    ttk::label $f.o.rll -text "   Results shown" -anchor w
    ttk::spinbox $f.o.rl -from 1 -to 20 -width 4 -font annSub
    $f.o.rl set $::ann::result_limit
    pack $f.o.hkl $f.o.hk $f.o.rll $f.o.rl -side left -pady {8 0}
    pack $f.o -fill x

    ttk::frame $f.b
    ttk::button $f.b.ok     -text "OK"     -style Dialog.TButton -command ann::settings_apply
    ttk::button $f.b.cancel -text "Cancel" -style Dialog.TButton -command {destroy .settings}
    pack $f.b.cancel $f.b.ok -side right -padx {6 0} -pady {12 0}   ;# OK left of Cancel (els order)
    pack $f.b -fill x

    bind .settings <Escape> {destroy .settings}
    bind .settings <Return> {ann::settings_apply}
    ann::settings_refresh_coverage
    return .settings
}

proc ann::settings_open {} {
    ann::settings_build
    update idletasks
    # els convention: centered on the parent, 1/3 down, modal grab
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth  .settings]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .settings]) / 3}]
    wm geometry .settings +${x}+${y}
    wm deiconify .settings
    raise .settings
    focus .settings.f.lf.list
    catch {grab .settings}
}

# ---- the dialog's folder model: a list of {path prio} pairs -------------------
# The pairs list is the source of truth; the listbox renders it (● = priority
# ON: scanned fast and first; ○ = OFF: the throttled background tier). The
# selection index maps 1:1 onto the pairs list.
proc ann::settings_current_roots {} {
    if {[ann::has annindex::get_roots] && ![catch {annindex::get_roots} r]} { return $r }
    return {}
}
proc ann::settings_pairs {} { return $::ann::set_pairs }
proc ann::settings_set_pairs {pairs} {
    set ::ann::set_pairs $pairs
    set l .settings.f.lf.list
    if {![winfo exists $l]} return
    set keep [$l curselection]
    $l delete 0 end
    foreach pr $pairs {
        lassign $pr p prio
        $l insert end [expr {$prio ? "● $p" : "○ $p"}]
    }
    foreach i $keep { catch {$l selection set $i} }
    ann::settings_refresh_coverage
}
# flip the priority flag of every selected folder (the user is fully in control)
proc ann::settings_toggle_priority {} {
    set l .settings.f.lf.list
    set pairs $::ann::set_pairs
    foreach i [$l curselection] {
        lassign [lindex $pairs $i] p prio
        lset pairs $i [list $p [expr {!$prio}]]
    }
    ann::settings_set_pairs $pairs
}

# ---- root coverage of the priority locations (DESIGN §7.2 amendment) ----------
# Pure + unit-tested: is `path` equal to or under `root`? (case-insensitive,
# both slash kinds, component boundary: C:\Foo covers C:\Foo\bar, not C:\Foobar)
proc ann::path_covers {root path} {
    set r [string tolower [string map {/ \\} [string trim $root]]]
    set p [string tolower [string map {/ \\} [string trim $path]]]
    while {[string length $r] > 3 && [string index $r end] eq "\\"} {
        set r [string range $r 0 end-1]
    }
    if {$r eq "" || $p eq ""} { return 0 }
    if {$r eq $p} { return 1 }
    if {[string index $r end] ne "\\"} { append r "\\" }
    return [string equal -length [string length $r] $r $p]
}

# the seed/default scan folders: the Windows startable-item locations
proc ann::default_roots {} {
    if {[ann::has annindex::priority_paths] && ![catch {annindex::priority_paths} p]} { return $p }
    return {}
}

# the priority locations NOT covered by the given roots (the Settings hint)
proc ann::uncovered_priorities {roots} {
    if {![ann::has annindex::priority_paths]} { return {} }
    if {[catch {annindex::priority_paths} prio]} { return {} }
    set out {}
    foreach pp $prio {
        set cov 0
        foreach r $roots {
            if {[ann::path_covers $r $pp]} { set cov 1 ; break }
        }
        if {!$cov} { lappend out $pp }
    }
    return $out
}

# refresh the dialog's coverage hint from the CURRENT listbox content; the user
# is guided to include startable-item locations, never forced (§7.2)
proc ann::settings_refresh_coverage {} {
    if {![winfo exists .settings.f.cov]} return
    set unc [ann::uncovered_priorities [lmap pr $::ann::set_pairs { lindex $pr 0 }]]
    if {![llength $unc]} {
        grid remove .settings.f.cov.w .settings.f.cov.t .settings.f.cov.inc
        return
    }
    set names {}
    foreach p $unc {
        set t [file tail $p]
        if {$t ni $names} { lappend names $t }   ;# Desktop + Public Desktop -> one
    }
    .settings.f.cov.t configure -text "Not indexed: [join $names {, }]"
    # plain re-grid restores the remembered row/column from settings_build
    grid .settings.f.cov.w .settings.f.cov.t .settings.f.cov.inc
}

proc ann::settings_include_uncovered {} {
    set pairs $::ann::set_pairs
    foreach p [ann::uncovered_priorities [lmap pr $pairs { lindex $pr 0 }]] {
        lappend pairs [list $p 1]          ;# default locations come back as fast
    }
    ann::settings_set_pairs $pairs
}

# the folder list's scrollbar: els autohide — exists only while the view is
# partial (it used to be packed unconditionally and showed without need)
proc ann::settings_vs_set {first last} {
    set sb .settings.f.lf.sb
    if {![winfo exists $sb]} return
    $sb set $first $last
    if {$first > 0.0001 || $last < 0.9999} {
        pack $sb -side right -fill y -before .settings.f.lf.list
    } else {
        pack forget $sb
    }
}

proc ann::settings_add_folder {} {
    set dir [tk_chooseDirectory -parent .settings -title "Add folder to scan"]
    if {$dir eq ""} return
    set dir [file nativename $dir]
    set pairs $::ann::set_pairs
    if {$dir in [lmap pr $pairs { lindex $pr 0 }]} return
    lappend pairs [list $dir 0]            ;# user-added folders: priority OFF
    ann::settings_set_pairs $pairs
}
proc ann::settings_remove_folder {} {
    set pairs $::ann::set_pairs
    foreach i [lreverse [.settings.f.lf.list curselection]] {
        set pairs [lreplace $pairs $i $i]
    }
    ann::settings_set_pairs $pairs
}
# re-inject the default startable-item folders (dedup; priority ON, like first run)
proc ann::settings_add_defaults {} {
    set pairs $::ann::set_pairs
    set have [lmap pr $pairs { string tolower [lindex $pr 0] }]
    foreach p [ann::default_roots] {
        if {[string tolower $p] ni $have} { lappend pairs [list $p 1] }
    }
    ann::settings_set_pairs $pairs
}

proc ann::settings_apply {} {
    if {![winfo exists .settings]} return
    set roots $::ann::set_pairs            ;# {path prio} pairs
    set hk    [string trim [.settings.f.o.hk get]]
    set rl    [.settings.f.o.rl get]
    destroy .settings
    if {[catch {ann::settings_save $roots $hk $rl} e]} {
        ann::log ERROR "settings save: $e"
        ann::status "settings not saved: $e" error
        return
    }
    # the config watcher will hot-reload too; apply now for instant feedback
    ann::load_config
    ann::status "settings saved"
}

# Persist dialog-controlled options into ann.config.tcl inside ONE managed block
# (everything outside the markers is the user's and is preserved verbatim; the
# block sits at the END so it wins over earlier hand-written values).
proc ann::settings_save {roots hotkey result_limit} {
    set path [ann::config_path]
    set body ""
    if {[file exists $path]} {
        set fh [open $path r] ; fconfigure $fh -encoding utf-8 ; set body [read $fh] ; close $fh
        regsub {(?s)# >>> ann settings.*?# <<< ann settings[^\n]*\n?} $body "" body
        set body [string trimright $body]
        if {$body ne ""} { append body "\n\n" }
    }
    append body "# >>> ann settings (managed by the Settings dialog — edits inside are overwritten)\n"
    append body "ann::option hotkey [list $hotkey]\n"
    append body "ann::option result_limit [list $result_limit]\n"
    append body "ann::option watched_roots [list $roots]\n"
    append body "# <<< ann settings\n"
    # Atomic save: write a sibling temp, then rename over the target (atomic on
    # NTFS). A crash/kill mid-write loses only the temp, never the live config.
    set tmp "$path.tmp"
    set fh [open $tmp w]
    fconfigure $fh -encoding utf-8 -translation lf
    puts -nonewline $fh $body
    close $fh
    file rename -force $tmp $path
}

# key router. While the (native) context menu is posted, ITS grab handles
# every key — arrows, Enter, Esc never reach the entry, so no panel branch.
proc ann::key_nav {action} {
    switch -- $action {
        up     { ann::move_sel -1 }
        down   { ann::move_sel 1 }
        enter  { ann::launch_selected }
        escape { ann::hide }
        tab    { ann::panel_toggle }
    }
    return 1
}

# notified (GUI thread) by the indexer when the catalog changes (DESIGN §9.6).
# NEVER yank the UI out from under an interaction: with the panel open the
# refresh is skipped (the next keystroke re-queries anyway), and the selection
# is re-anchored to the same result id, not reset to 0.
proc ann::on_catalog_updated {} {
    if {[ann::has annindex::stats] && ![catch {annindex::stats} st]} {
        ann::log INFO "catalog updated: $st"
        # feed the statusbar's indexing-activity line (its idle text)
        set ::ann::last_stats $st
        set ::ann::last_scan_at [clock format [clock seconds] -format %H:%M]
        # the empty-list "indexing…" hint tracks the LIVE phase (a phase-start
        # notify precedes any rows; results are incomplete until phase 1 ends)
        set ::ann::indexing [expr {[ann::led_phase] == 1}]
        ann::led_update
        if {$::ann::status_after eq ""} { ann::status "" }   ;# refresh unless a transient is up
        if {[dict exists $st capped_bulk] && [dict get $st capped_bulk] && [dict get $st bulk_done]} {
            ann::log WARN "file index cap reached ([dict get $st files_bulk] bulk rows) — narrow watched_roots if results look incomplete"
        }
    }
    if {$::ann::visible && !$::ann::panel_open} {
        ann::do_query -keepsel
    } else {
        ann::update_foot
    }
    after idle ann::prefetch_icons
}

# Warm the C-side icon LRU for the most relevant items in small idle chunks, so
# a fresh popup paints icons without per-row extraction stalls (keystroke budget
# DESIGN §6.6). Pure cache warming: no Tk photo images are created here.
proc ann::prefetch_icons {} {
    variable reader
    if {$reader eq "" || ![ann::has annicon::fill] || ![ann::has anndb::search]} return
    if {[catch {anndb::search $reader "" 40} top]} return
    set specs [lmap r $top { ann::icon_spec $r }]
    ann::prefetch_chunk $specs
}
proc ann::prefetch_chunk {specs} {
    if {![llength $specs]} return
    if {![winfo exists .c.q]} return
    # warm via a scratch photo (filled then left for reuse; blobs live in the C LRU)
    if {[lsearch [image names] annprefetch] < 0} { image create photo annprefetch }
    foreach s [lrange $specs 0 3] { catch {annicon::fill annprefetch $s 32} }
    after 15 [list ann::prefetch_chunk [lrange $specs 4 end]]
}

proc ann::toggle {} {
    if {$::ann::visible} { ann::hide } else { ann::show }
}

# callbacks invoked from the hotkey thread bridge (run on the GUI thread)
proc ann::on_hotkey {} { ann::log INFO "hotkey fired (visible=$::ann::visible)" ; ann::toggle }
proc ann::on_show {}   { ann::log INFO "show requested by another instance" ; ann::show }

proc ann::quit {} {
    ann::log INFO "quit requested"
    ann::tray_teardown
    if {[ann::has annindex::stop]}  { catch {annindex::stop} }
    if {$::ann::reader ne "" && [ann::has anndb::close]} { catch {anndb::close $::ann::reader} }
    if {[ann::has annhotkey::stop]} { catch {annhotkey::stop} }
    exit 0
}

# ============================================================================
#  LIFECYCLE
# ============================================================================
# Open the read-only reader and kick off the background indexer (DESIGN §3.2).
# The indexer's watcher also watches the config file for hot reload (§11.2).
proc ann::start_indexer {} {
    variable db
    set db [file join $::ann::dir ann.db]
    if {[ann::has annindex::start]} {
        if {[catch {annindex::start $db ::ann::on_catalog_updated \
                        [ann::config_path] ::ann::on_config_changed} e]} {
            ann::log ERROR "indexer start failed: $e" ; set ::ann::indexing 0
        } else {
            ann::log INFO "indexer started ($db)"
        }
    } else {
        set ::ann::indexing 0
    }
    # reader: a read-only WAL snapshot (never blocks the writer). If the DB does
    # not exist yet (no indexer in this build), create it empty so search works.
    if {[ann::has anndb::open]} {
        if {[catch {anndb::open $db -readonly} rc]} {
            if {![catch {anndb::open $db} rw]} { catch {anndb::schema $rw} ; set ::ann::reader $rw } \
            else { ann::log ERROR "reader open failed: $rc | $rw" }
        } else {
            set ::ann::reader $rc
        }
    }
}

proc ann::main {} {
    if {[lindex $::argv 0] eq "--selftest"} {
        set out [lindex $::argv 1]
        if {$out eq ""} { set out [file join $::ann::dir ann-selftest.txt] }
        exit [expr {[ann::selftest_report $out] ? 0 : 1}]
    }
    # single-instance: if another copy in THIS folder is live, ask it to show + exit.
    # Tooling (x shot, tests) sets ANN_NO_SINGLE_INSTANCE to launch a throwaway
    # instance that coexists with a running one instead of bouncing to it.
    if {[ann::has annhotkey::acquire] && ![info exists ::env(ANN_NO_SINGLE_INSTANCE)]} {
        if {![annhotkey::acquire [ann::instance_tag]]} {
            catch {annhotkey::signal [ann::instance_tag]}
            ann::log INFO "another instance is live; signaled it to show; exiting"
            exit 0
        }
    }
    ann::build
    ann::load_config           ;# first run writes the template; sets roots/tuning
    ann::start_indexer         ;# scans with the configured roots; watches config
    ann::apply_hotkey          ;# no-op if the config already registered it
    ann::tray_setup            ;# resident presence: click = open, right-click = menu
    ann::show
    after 1500 ann::check_update   ;# els's startup update check (best-effort)
}

# Run main only when this file IS the program (startup script / wish), NOT when a
# test suite sources it. Any uncaught error is logged, never surfaced as a dialog.
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {ann::main} e]} {
        ann::log FATAL "main: $e | [string map {\n { }} $::errorInfo]"
        catch {exit 1}
    }
}

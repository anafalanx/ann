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
    variable version "0.1"     ;# major.minor, two natural numbers
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
    # near-black ink, flat white fields with hairlines, ONE red flourish (the
    # caret), and a cool calm selection tint.
    variable C
    array set C {
        bg "#F2F2F2"  panel "#FFFFFF"  ink "#1A1A1A"  muted "#767676"
        accent "#DC322F"  good "#3C8A50"  bad "#DC322F"  sel "#D6E2F2"
        hair "#D9D9D9"  focus "#BFCFE3"
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

# Watched roots for the file index. Default: the Windows-11 startable-item
# locations — Desktop (+ Public), Downloads, Documents, %LOCALAPPDATA%/Programs,
# and both Program Files. Those are always indexed first and fast; anything
# beyond them (e.g. a whole drive, if you add C:/) follows in a throttled
# background walk. %VARS% are expanded; / and \ both work.
# ann::option watched_roots {
#     C:/
#     {%USERPROFILE%/Projects}
# }

# ---- a keyword alias (§6.7): typing exactly "cfg" pins this file to the top --
ann::alias cfg [file join $ann::dir ann.config.tcl]

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
            if {[catch {llength $value} n]} {
                ann::log WARN "watched_roots is not a list, ignored" ; return
            }
            set roots {}
            foreach r $value {
                if {[string first % $r] >= 0 && [ann::has annplat::expand_env]} {
                    catch { set r [annplat::expand_env $r] }
                }
                lappend roots $r
            }
            if {[ann::has annindex::set_roots]} { catch {annindex::set_roots $roots} }
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
    catch {font create annQuery   -family "Segoe UI" -size 15}
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
proc ann::build_statusbar {} {
    variable C
    frame .status -bg $C(bg)
    frame .status.sep -bg $C(hair) -height 1
    pack .status.sep -side top -fill x
    frame .status.in -bg $C(bg) -padx 12 -pady 4
    pack .status.in -fill x
    label .status.in.info -bg $C(bg) -fg $C(muted) -anchor e -font annStatus -text ""
    pack .status.in.info -side right -padx {10 0}
    # a normally-empty notice; lights up red when a newer release is detected
    # (els's .sb.update, verbatim mechanism) — click opens the download page
    label .status.in.update -bg $C(bg) -fg $C(accent) -anchor e -font annStatus \
        -text "" -cursor hand2
    pack .status.in.update -side right -padx {10 0}
    bind .status.in.update <Button-1> \
        {ann::open_url "https://github.com/anafalanx/ann/releases/latest"}
    label .status.in.msg -bg $C(bg) -fg $C(muted) -anchor w -font annStatus -text "" -width 1
    pack .status.in.msg -side left -fill x -expand 1
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
proc ann::status_idle_text {} {
    variable last_stats ; variable last_scan_at ; variable indexing
    if {![dict size $last_stats]} { return [expr {$indexing ? "indexing…" : ""}] }
    set apps  [expr {[dict get $last_stats lnk_found] + [dict get $last_stats uwp_found]}]
    set txt "[ann::ncomma $apps] apps · [ann::ncomma [dict get $last_stats files_found]] files"
    if {![dict get $last_stats bulk_done] && ![dict get $last_stats bulk_aborted]} {
        append txt " · indexing in background…"
    } else {
        if {$last_scan_at ne ""} { append txt " · updated $last_scan_at" }
        if {[dict get $last_stats capped_bulk]} { append txt " · file cap reached" }
    }
    return $txt
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
            [expr {$q ne "" ? "  No results" : "  (catalog empty)"}]}]
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
proc ann::bucketize {cands limit} {
    set apps {} ; set wins {} ; set files {}
    foreach c $cands {
        switch -- [dict get $c kind] {
            window      { lappend wins  $c }
            file - folder { lappend files $c }
            default     { lappend apps  $c }
        }
    }
    # Each bucket is sorted by score (stable: equal scores keep arrival order, so
    # the C-ranked DB rows stay ranked and provider rows slot in competitively).
    foreach v {apps wins files} {
        set pairs [lmap c [set $v] {
            list [expr {[dict exists $c score] ? [dict get $c score] : 0}] $c
        }]
        set $v [lmap p [lsort -real -decreasing -index 0 $pairs] { lindex $p 1 }]
    }
    # Decide the per-bucket COUNTS first (reserve 1 window + 1 file when those
    # buckets match, fill the rest by priority, reclaim unused), then emit the
    # buckets as contiguous slices — the presented order is STRICTLY apps ->
    # windows -> files (§6.5 locked decision; the counts never interleave).
    set na [llength $apps] ; set nw [llength $wins] ; set nf [llength $files]
    # reserves never crowd out the last app slot and never exceed the limit
    set rcap [expr {max(0, $limit - ($na > 0 ? 1 : 0))}]
    set tw [expr {min($nw > 0 ? 1 : 0, $rcap)}]
    set tf [expr {min($nf > 0 ? 1 : 0, $rcap - $tw)}]
    set ta [expr {min($na, max(0, $limit - $tw - $tf))}]
    set rem [expr {$limit - $ta - $tw - $tf}]
    if {$rem > 0} { set add [expr {min($rem, $na - $ta)}] ; incr ta $add ; incr rem -$add }
    if {$rem > 0} { set add [expr {min($rem, $nw - $tw)}] ; incr tw $add ; incr rem -$add }
    if {$rem > 0} { set add [expr {min($rem, $nf - $tf)}] ; incr tf $add ; incr rem -$add }
    return [concat [lrange $apps 0 [expr {$ta - 1}]] \
                   [lrange $wins 0 [expr {$tw - 1}]] \
                   [lrange $files 0 [expr {$tf - 1}]]]
}

# Apply the exact-alias top-pin (§6.7) then bucket. The C search already returns
# candidates sorted by the fuzzy+frecency blend; an exact alias pins its target to
# the top of its bucket regardless of fuzzy competition. A target may be a catalog
# path, a plain file/folder path, or a command prefix (§11.4 shows all three).
proc ann::rank {cands query} {
    set nq [string tolower [string trim $query]]
    if {$nq ne "" && [dict exists $::ann::aliases $nq]} {
        set target [dict get $::ann::aliases $nq]
        set item ""
        if {$::ann::reader ne "" && [ann::has anndb::get]} {
            catch { set item [anndb::get $::ann::reader $target] }
        }
        if {$item eq "" && [file exists $target]} {
            # the whole target string is a real path (spaces included); the pin
            # score keeps it on top through the per-bucket sort (§6.7)
            set item [dict create id "alias:$nq" name [file tail $target] path $target \
                kind [expr {[file isdirectory $target] ? "folder" : "file"}] \
                launch path target $target score 1e9]
        }
        if {$item eq "" && ![catch {lindex $target 0} word0] && $word0 ne "" \
                && [llength [info commands $word0]]} {
            # a command prefix (one word or more) -> a tclproc result
            set item [dict create id "alias:$nq" name $nq path "alias:$nq" \
                kind app launch tclproc target "alias" score 1e9 script $target]
        }
        if {$item ne ""} {
            set tpath [dict get $item path]
            set cands [lmap c $cands { if {[dict get $c path] eq $tpath} continue ; set c }]
            set cands [linsert $cands 0 $item]
        }
    }
    return [ann::bucketize $cands $::ann::result_max]
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

proc ann::panel_toggle {} {
    variable panel_open
    if {$panel_open} { ann::panel_close ; return }
    variable results ; variable sel
    if {![llength $results]} return
    set ::ann::panel_actions [ann::actions_for [lindex $results $sel]]
    set ::ann::panel_sel 0
    set ::ann::panel_confirm -1
    set panel_open 1
    ann::panel_render
}

proc ann::panel_close {} {
    variable panel_open
    if {!$panel_open} return
    set panel_open 0
    set ::ann::panel_confirm -1
    catch {destroy .c.panel}
}

proc ann::panel_render {} {
    variable C ; variable panel_actions ; variable panel_sel ; variable panel_confirm
    catch {destroy .c.panel}
    if {!$::ann::panel_open} return
    set p [frame .c.panel -bg $C(panel) -padx 2 -pady 2 \
               -highlightthickness 1 -highlightbackground $C(hair)]
    set i 0
    foreach a $panel_actions {
        set txt [dict get $a label]
        if {$i == $panel_confirm} { set txt "Confirm: $txt — Enter again, Esc cancels" }
        set bg [expr {$i == $panel_sel ? $C(sel) : $C(panel)}]
        set fg [expr {[dict get $a destructive] && $i == $panel_confirm ? $C(bad) : $C(ink)}]
        label $p.a$i -text "  $txt  " -bg $bg -fg $fg -anchor w -font annName -width 1
        pack $p.a$i -fill x
        incr i
    }
    # bottom-right by default; if the panel is taller than the popup body, anchor
    # at the TOP-right instead so the selected first rows are never clipped off
    update idletasks
    if {[winfo exists .c] && [winfo reqheight $p] > [winfo height .c] - 40} {
        place $p -relx 1.0 -rely 0.0 -x -4 -y 4 -anchor ne -relwidth 0.62
    } else {
        place $p -relx 1.0 -rely 1.0 -x -4 -y -30 -anchor se -relwidth 0.62
    }
    raise $p
}

proc ann::panel_move {d} {
    variable panel_actions ; variable panel_sel
    set n [llength $panel_actions]
    if {!$n} return
    set panel_sel [expr {($panel_sel + $d) % $n}]
    if {$panel_sel < 0} { incr panel_sel $n }
    set ::ann::panel_confirm -1          ;# moving disarms a pending confirm
    ann::panel_render
}

proc ann::panel_invoke {} {
    variable panel_actions ; variable panel_sel ; variable panel_confirm
    if {![llength $panel_actions]} return
    set a [lindex $panel_actions $panel_sel]
    if {[dict get $a destructive] && $panel_confirm != $panel_sel} {
        set panel_confirm $panel_sel     ;# arm: the next Enter executes (§9.5)
        ann::panel_render
        return
    }
    ann::panel_close
    if {[catch {uplevel #0 [dict get $a script]} e]} {
        ann::log ERROR "action '[dict get $a label]': $e"
        ann::status "action failed: $e" error
    }
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
    foreach r [ann::settings_current_roots] { $f.lf.list insert end $r }

    ttk::frame $f.lb
    ttk::button $f.lb.add -text "Add folder…" -style Dialog.TButton -command ann::settings_add_folder
    ttk::button $f.lb.rm  -text "Remove"      -style Dialog.TButton -command ann::settings_remove_folder
    pack $f.lb.add $f.lb.rm -side left -padx {0 6} -pady 6
    pack $f.lb -fill x

    # coverage guidance (§7.2): priority locations not under any listed root
    ttk::frame $f.cov
    ttk::label $f.cov.w -text "⚠" -foreground $C(accent)
    ttk::label $f.cov.t -text "" -anchor w
    ttk::button $f.cov.inc -text "Include" -style Dialog.TButton -command ann::settings_include_uncovered
    grid $f.cov.w -row 0 -column 0 -padx {0 4}
    grid $f.cov.t -row 0 -column 1 -sticky we
    grid $f.cov.inc -row 0 -column 2 -padx {8 0}
    grid columnconfigure $f.cov 1 -weight 1
    pack $f.cov -fill x -pady {0 4}

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

# the roots shown in the dialog: live indexer roots (resolved defaults included)
proc ann::settings_current_roots {} {
    if {[ann::has annindex::get_roots] && ![catch {annindex::get_roots} r]} { return $r }
    return {}
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
    set unc [ann::uncovered_priorities [.settings.f.lf.list get 0 end]]
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
    set l .settings.f.lf.list
    foreach p [ann::uncovered_priorities [$l get 0 end]] { $l insert end $p }
    ann::settings_refresh_coverage
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
    set dir [tk_chooseDirectory -parent .settings -title "Add folder to index"]
    if {$dir eq ""} return
    set dir [file nativename $dir]
    set l .settings.f.lf.list
    if {$dir in [$l get 0 end]} return
    $l insert end $dir
    ann::settings_refresh_coverage
}
proc ann::settings_remove_folder {} {
    set l .settings.f.lf.list
    foreach i [lreverse [$l curselection]] { $l delete $i }
    ann::settings_refresh_coverage
}

proc ann::settings_apply {} {
    if {![winfo exists .settings]} return
    set roots [.settings.f.lf.list get 0 end]
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
    set fh [open $path w]
    fconfigure $fh -encoding utf-8 -translation lf
    puts -nonewline $fh $body
    close $fh
}

# key router: the panel captures navigation while open
proc ann::key_nav {action} {
    if {$::ann::panel_open} {
        switch -- $action {
            up     { ann::panel_move -1 }
            down   { ann::panel_move 1 }
            enter  { ann::panel_invoke }
            escape { ann::panel_close }
            tab    { ann::panel_close }
        }
        return 1
    }
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
    set ::ann::indexing 0
    if {[ann::has annindex::stats] && ![catch {annindex::stats} st]} {
        ann::log INFO "catalog updated: $st"
        # feed the statusbar's indexing-activity line (its idle text)
        set ::ann::last_stats $st
        set ::ann::last_scan_at [clock format [clock seconds] -format %H:%M]
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
    if {[ann::has annhotkey::acquire]} {
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

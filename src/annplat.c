/*
 * ann_plat.c -- Win32 platform layer for ann (M0 subset).
 *
 * The hard Windows integration is C (DESIGN §3.3). M0 establishes the riskiest
 * pieces of the threading + window model so later milestones build on proven
 * ground:
 *   annplat::active_monitor_rect ?hwnd?  -> {x y w h} work area of the active
 *                                           monitor (DESIGN §9.1)
 *   annplat::force_foreground <hwnd>     -> AttachThreadInput + SetForegroundWindow
 *                                           so an overrideredirect popup gets focus
 *                                           (DESIGN §7.3, §9.3)
 *   annplat::dwm_round <hwnd>            -> best-effort rounded corners on a
 *                                           frameless window (DESIGN §9.2)
 *   annplat::thread_roundtrip            -> proves the worker -> GUI-thread event
 *                                           bridge: Tcl_ThreadQueueEvent +
 *                                           Tcl_ThreadAlert (DESIGN §3.4)
 *
 * Compiled INTO ann.exe (ANN_STATIC_PLAT, registered in ann_main.c) and also
 * buildable as a dev stubs .dll by `x build-ext`.
 */

#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <shellapi.h>   /* ShellExecuteW — excluded by WIN32_LEAN_AND_MEAN otherwise */
#include <shobjidl.h>   /* IApplicationActivationManager */
#include <shlobj.h>     /* SHParseDisplayName, SHOpenFolderAndSelectItems, SHEmptyRecycleBin */
#include <powrprof.h>   /* SetSuspendState */
#undef WIN32_LEAN_AND_MEAN
#include <string.h>
#include <stdio.h>

/* Local GUIDs (mingw's libuuid may not export them; INITGUID lives in annindex.c
 * only — DESIGN §4.3): ApplicationActivationManager for AUMID launches. */
static const GUID ANN_CLSID_AAM =
    { 0x45BA127D, 0x10A8, 0x46EA, { 0x8A, 0xB7, 0x56, 0xEA, 0x90, 0x78, 0x94, 0x3C } };
static const GUID ANN_IID_IAAM =
    { 0x2e941141, 0x7f97, 0x4756, { 0xba, 0x1d, 0x9d, 0xec, 0xde, 0x89, 0x4a, 0x3d } };

/* DWM constant shims (DESIGN §4.3): older MinGW headers may lack the Win11 set. */
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif
#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
#endif

/* ------- hwnd parsing -------------------------------------------------------
 * Tk's `winfo id` yields a hex string like "0x04A21B3C"; Tcl's integer parser
 * accepts the 0x prefix, so a wide int round-trips to an HWND. */
static int GetHwnd(Tcl_Interp *ip, Tcl_Obj *o, HWND *out) {
    Tcl_WideInt w;
    if (Tcl_GetWideIntFromObj(ip, o, &w) != TCL_OK) return TCL_ERROR;
    *out = (HWND)(intptr_t) w;
    return TCL_OK;
}

/* ------- active monitor work-area ------------------------------------------ */
static int Plat_MonitorRect(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    HMONITOR mon;
    if (objc == 2) {
        HWND h;
        if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
        mon = MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST);
    } else if (objc == 1) {
        /* the monitor with the foreground window, else the one under the cursor */
        HWND fg = GetForegroundWindow();
        if (fg) {
            mon = MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
        } else {
            POINT p; GetCursorPos(&p);
            mon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        }
    } else {
        Tcl_WrongNumArgs(ip, 1, objv, "?hwnd?");
        return TCL_ERROR;
    }
    MONITORINFO mi; mi.cbSize = sizeof mi;
    if (!GetMonitorInfo(mon, &mi)) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("GetMonitorInfo failed", -1));
        return TCL_ERROR;
    }
    RECT r = mi.rcWork;   /* work area excludes the taskbar */
    Tcl_Obj *res[4] = {
        Tcl_NewIntObj(r.left), Tcl_NewIntObj(r.top),
        Tcl_NewIntObj(r.right - r.left), Tcl_NewIntObj(r.bottom - r.top)
    };
    Tcl_SetObjResult(ip, Tcl_NewListObj(4, res));
    return TCL_OK;
}

/* ------- force foreground (overrideredirect popups don't get WM focus) ------ */
static int Plat_ForceForeground(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;

    if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
    HWND fg = GetForegroundWindow();
    DWORD me = GetCurrentThreadId();
    DWORD ft = fg ? GetWindowThreadProcessId(fg, NULL) : me;
    BOOL attached = FALSE;
    if (ft != me) attached = AttachThreadInput(me, ft, TRUE);
    BringWindowToTop(h);
    BOOL ok = SetForegroundWindow(h);
    if (attached) AttachThreadInput(me, ft, FALSE);
    if (!ok) SwitchToThisWindow(h, TRUE);   /* documented fallback */
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(ok));
    return TCL_OK;
}

/* ------- best-effort DWM rounded corners on a frameless window -------------- */
static int Plat_DwmRound(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    DWORD pref = DWMWCP_ROUND;
    HRESULT hr = DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &pref, sizeof pref);
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(SUCCEEDED(hr)));   /* best-effort, never fatal */
    return TCL_OK;
}

/* ------- UTF-8 -> heap UTF-16 helper ---------------------------------------- */
static wchar_t *u8w(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = (wchar_t *) Tcl_Alloc((size_t)(n > 0 ? n : 1) * sizeof(wchar_t));
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    else w[0] = 0;
    return w;
}

/* ------- launch (DESIGN §7.1/§7.3) -------------------------------------------
 * Desktop targets via ShellExecute; packaged apps via the REAL path:
 * IApplicationActivationManager::ActivateApplication with
 * CoAllowSetForegroundWindow so the activated app may take focus, falling back
 * to shell:AppsFolder if activation is unavailable. */
static int launch_aumid(const char *aumid) {
    int ok = 0;
    IApplicationActivationManager *am = NULL;
    if (CoCreateInstance(&ANN_CLSID_AAM, NULL, CLSCTX_LOCAL_SERVER,
                         &ANN_IID_IAAM, (void **) &am) == S_OK && am) {
        CoAllowSetForegroundWindow((IUnknown *) am, NULL);
        wchar_t *wa = u8w(aumid);
        DWORD pid = 0;
        if (am->lpVtbl->ActivateApplication(am, wa, NULL, AO_NONE, &pid) == S_OK) ok = 1;
        Tcl_Free((char *) wa);
        am->lpVtbl->Release(am);
    }
    if (!ok) {
        /* fallback: the AppsFolder shell namespace */
        char full[2048];
        snprintf(full, sizeof full, "shell:AppsFolder\\%s", aumid);
        wchar_t *wf = u8w(full);
        AllowSetForegroundWindow(ASFW_ANY);
        HINSTANCE r = ShellExecuteW(NULL, L"open", wf, NULL, NULL, SW_SHOWNORMAL);
        Tcl_Free((char *) wf);
        ok = ((INT_PTR) r > 32);
    }
    return ok;
}

static int Plat_Launch(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 3 || objc > 4) { Tcl_WrongNumArgs(ip, 1, objv, "launch_kind path ?args?"); return TCL_ERROR; }
    const char *lk = Tcl_GetString(objv[1]);
    const char *path = Tcl_GetString(objv[2]);
    const char *args = (objc == 4) ? Tcl_GetString(objv[3]) : NULL;

    if (strcmp(lk, "aumid") == 0) {
        if (!launch_aumid(path)) {
            Tcl_SetObjResult(ip, Tcl_NewStringObj("UWP activation failed", -1));
            return TCL_ERROR;
        }
        Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
        return TCL_OK;
    }

    wchar_t *wpath = u8w(path);
    wchar_t *wargs = (args && *args) ? u8w(args) : NULL;
    AllowSetForegroundWindow(ASFW_ANY);   /* let the launched app take focus (§7.3) */
    HINSTANCE r = ShellExecuteW(NULL, L"open", wpath, wargs, NULL, SW_SHOWNORMAL);
    Tcl_Free((char *) wpath);
    if (wargs) Tcl_Free((char *) wargs);
    if ((INT_PTR) r <= 32) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("ShellExecute failed (%lld)", (long long) (INT_PTR) r));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

/* ------- Run-box style query splitting (gap-analysis #1) ---------------------
 * annplat::run_split <raw> -> {file args}.  PURE (no execution), so it is fully
 * testable; the caller hands the pieces to annplat::launch.  Splitting mirrors
 * the Windows Run box: a leading double-quote delimits the file exactly; else
 * the LONGEST space-joined token prefix that exists on disk wins (so
 * `C:\Program Files\Foo\foo.exe -x` finds the spaced path without quotes);
 * else first token = file, rest = args (ShellExecute then resolves PATH, App
 * Paths, and URI schemes like ms-settings:).                                  */
static int Plat_RunSplit(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "raw"); return TCL_ERROR; }
    const char *raw = Tcl_GetString(objv[1]);
    while (*raw == ' ' || *raw == '\t') raw++;
    size_t len = strlen(raw);
    while (len && (raw[len-1] == ' ' || raw[len-1] == '\t')) len--;
    char *buf = Tcl_Alloc(len + 1);
    memcpy(buf, raw, len);
    buf[len] = 0;
    Tcl_Obj *file = NULL, *args = NULL;
    if (buf[0] == '"') {                        /* quoted first token wins */
        char *end = strchr(buf + 1, '"');
        if (end) {
            const char *rest = end + 1;
            while (*rest == ' ') rest++;
            file = Tcl_NewStringObj(buf + 1, (int) (end - (buf + 1)));
            args = Tcl_NewStringObj(rest, -1);
        }
    }
    if (!file && len) {                         /* greedy longest-existing prefix */
        size_t cut = len;
        while (cut > 0) {
            char saved = buf[cut];
            buf[cut] = 0;
            wchar_t *w = u8w(buf);
            DWORD at = GetFileAttributesW(w);
            Tcl_Free((char *) w);
            buf[cut] = saved;
            if (at != INVALID_FILE_ATTRIBUTES) {
                const char *rest = buf + cut;
                while (*rest == ' ') rest++;
                file = Tcl_NewStringObj(buf, (int) cut);
                args = Tcl_NewStringObj(rest, -1);
                break;
            }
            while (cut > 0 && buf[cut-1] == ' ') cut--;   /* skip space run */
            while (cut > 0 && buf[cut-1] != ' ') cut--;   /* skip the word  */
            while (cut > 0 && buf[cut-1] == ' ') cut--;   /* end of prev word */
        }
    }
    if (!file) {                                /* first token; ShellExecute resolves */
        char *sp = strchr(buf, ' ');
        if (sp) {
            const char *rest = sp + 1;
            while (*rest == ' ') rest++;
            file = Tcl_NewStringObj(buf, (int) (sp - buf));
            args = Tcl_NewStringObj(rest, -1);
        } else {
            file = Tcl_NewStringObj(buf, -1);
            args = Tcl_NewStringObj("", 0);
        }
    }
    Tcl_Free(buf);
    Tcl_Obj *pair[2] = { file, args };
    Tcl_SetObjResult(ip, Tcl_NewListObj(2, pair));
    return TCL_OK;
}

/* ------- run-as-administrator (DESIGN §9.5/§15.2) ----------------------------
 * `runas` verb; a cancelled UAC prompt (ERROR_CANCELLED) is the NORMAL
 * "user declined" outcome -> returns "cancelled", never an error. */
static int Plat_Runas(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR; }
    wchar_t *wpath = u8w(Tcl_GetString(objv[1]));
    SHELLEXECUTEINFOW sei;
    memset(&sei, 0, sizeof sei);
    sei.cbSize = sizeof sei;
    /* DOENVSUBST: .lnk targets resolved with SLGP_RAWPATH may carry %VAR% */
    sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_DOENVSUBST;
    sei.lpVerb = L"runas";
    sei.lpFile = wpath;
    sei.nShow = SW_SHOWNORMAL;
    AllowSetForegroundWindow(ASFW_ANY);
    BOOL ok = ShellExecuteExW(&sei);
    DWORD err = ok ? 0 : GetLastError();
    if (sei.hProcess) CloseHandle(sei.hProcess);
    Tcl_Free((char *) wpath);
    if (!ok && err == ERROR_CANCELLED) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("cancelled", -1));
        return TCL_OK;
    }
    if (!ok) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("runas failed (error %lu)", err));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

/* ------- open containing folder with the item selected (DESIGN §9.5) -------- */
static int Plat_OpenFolderSelect(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR; }
    wchar_t *wpath = u8w(Tcl_GetString(objv[1]));
    PIDLIST_ABSOLUTE pidl = NULL;
    HRESULT hr = SHParseDisplayName(wpath, NULL, &pidl, 0, NULL);
    Tcl_Free((char *) wpath);
    if (FAILED(hr) || !pidl) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("path not found", -1));
        return TCL_ERROR;
    }
    AllowSetForegroundWindow(ASFW_ANY);
    hr = SHOpenFolderAndSelectItems(pidl, 0, NULL, 0);
    CoTaskMemFree(pidl);
    if (FAILED(hr)) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("SHOpenFolderAndSelectItems failed", -1));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

/* ------- the running-windows switcher (DESIGN §7.3) -------------------------- */
typedef struct { Tcl_Interp *ip; Tcl_Obj *list; DWORD ourPid; } EnumCtx;

static BOOL CALLBACK enum_proc(HWND h, LPARAM lp) {
    EnumCtx *cx = (EnumCtx *) lp;
    if (!IsWindowVisible(h)) return TRUE;
    int tlen = GetWindowTextLengthW(h);
    if (tlen <= 0) return TRUE;
    LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
    if (ex & WS_EX_TOOLWINDOW) return TRUE;
    HWND owner = GetWindow(h, GW_OWNER);
    if (owner != NULL && !(ex & WS_EX_APPWINDOW)) return TRUE;
    /* not cloaked: check BOTH the HRESULT and the value (§7.3) */
    DWORD cloaked = 0;
    if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof cloaked) == S_OK && cloaked != 0)
        return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid == cx->ourPid) return TRUE;          /* never list our own popup */

    wchar_t title[512];
    GetWindowTextW(h, title, 512);
    char *ut = NULL;
    { int n = WideCharToMultiByte(CP_UTF8, 0, title, -1, NULL, 0, NULL, NULL);
      ut = (char *) Tcl_Alloc(n > 0 ? n : 1);
      if (n > 0) WideCharToMultiByte(CP_UTF8, 0, title, -1, ut, n, NULL, NULL); else ut[0] = 0; }

    /* process image name for the subtitle */
    char exe[260] = "";
    HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (hp) {
        wchar_t img[1024]; DWORD len = 1024;
        if (QueryFullProcessImageNameW(hp, 0, img, &len)) {
            const wchar_t *base = wcsrchr(img, L'\\');
            base = base ? base + 1 : img;
            WideCharToMultiByte(CP_UTF8, 0, base, -1, exe, sizeof exe, NULL, NULL);
        }
        CloseHandle(hp);
    }

    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(cx->ip, d, Tcl_NewStringObj("hwnd", -1),  Tcl_NewWideIntObj((Tcl_WideInt)(intptr_t) h));
    Tcl_DictObjPut(cx->ip, d, Tcl_NewStringObj("title", -1), Tcl_NewStringObj(ut, -1));
    Tcl_DictObjPut(cx->ip, d, Tcl_NewStringObj("exe", -1),   Tcl_NewStringObj(exe, -1));
    Tcl_ListObjAppendElement(cx->ip, cx->list, d);
    Tcl_Free(ut);
    return TRUE;
}

static int Plat_Windows(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    EnumCtx cx = { ip, Tcl_NewListObj(0, NULL), GetCurrentProcessId() };
    EnumWindows(enum_proc, (LPARAM) &cx);
    Tcl_SetObjResult(ip, cx.list);
    return TCL_OK;
}

/* activate: revalidate (IsWindow + IsWindowVisible) -> restore -> AttachThreadInput
 * -> BringWindowToTop -> SetForegroundWindow -> SwitchToThisWindow fallback.
 * Returns 1 activated, 0 STALE (caller silently drops + re-enumerates, §7.3). */
static int Plat_Activate(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    if (!IsWindow(h) || !IsWindowVisible(h)) {
        Tcl_SetObjResult(ip, Tcl_NewBooleanObj(0));
        return TCL_OK;
    }
    if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
    HWND fg = GetForegroundWindow();
    DWORD me = GetCurrentThreadId();
    DWORD ft = fg ? GetWindowThreadProcessId(fg, NULL) : me;
    BOOL attached = FALSE;
    if (ft != me) attached = AttachThreadInput(me, ft, TRUE);
    BringWindowToTop(h);
    BOOL ok = SetForegroundWindow(h);
    if (attached) AttachThreadInput(me, ft, FALSE);
    if (!ok) SwitchToThisWindow(h, TRUE);
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(1));
    return TCL_OK;
}

static int Plat_CloseWindow(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    if (!IsWindow(h)) {                       /* stale -> 0, silent drop (§7.3) */
        Tcl_SetObjResult(ip, Tcl_NewBooleanObj(0));
        return TCL_OK;
    }
    PostMessageW(h, WM_CLOSE, 0, 0);
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(1));
    return TCL_OK;
}

/* ------- system commands (DESIGN §8) ------------------------------------------
 * The shutdown family requires SE_SHUTDOWN_NAME enabled on our token first.
 * `-dryrun` validates dispatch + privilege handling without acting (tests). */
static int enable_shutdown_privilege(void) {
    HANDLE tok = NULL;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok))
        return 0;
    TOKEN_PRIVILEGES tp;
    memset(&tp, 0, sizeof tp);
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    int ok = LookupPrivilegeValueW(NULL, L"SeShutdownPrivilege", &tp.Privileges[0].Luid)
          && AdjustTokenPrivileges(tok, FALSE, &tp, 0, NULL, NULL)
          && GetLastError() == ERROR_SUCCESS;
    CloseHandle(tok);
    return ok;
}

static int shell_open(const wchar_t *what) {
    AllowSetForegroundWindow(ASFW_ANY);
    return (INT_PTR) ShellExecuteW(NULL, L"open", what, NULL, NULL, SW_SHOWNORMAL) > 32;
}

static int Plat_Syscmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc < 2 || objc > 3) { Tcl_WrongNumArgs(ip, 1, objv, "id ?-dryrun?"); return TCL_ERROR; }
    const char *id = Tcl_GetString(objv[1]);
    if (strncmp(id, "syscmd:", 7) == 0) id += 7;
    int dry = (objc == 3 && strcmp(Tcl_GetString(objv[2]), "-dryrun") == 0);
    int ok = 1;

    if (strcmp(id, "lock") == 0) {
        if (!dry) ok = LockWorkStation();
    } else if (strcmp(id, "sleep") == 0) {
        ok = enable_shutdown_privilege();
        if (ok && !dry) ok = SetSuspendState(FALSE, FALSE, FALSE);   /* suspend, not hibernate */
    } else if (strcmp(id, "shutdown") == 0) {
        ok = enable_shutdown_privilege();
        if (ok && !dry) ok = ExitWindowsEx(EWX_SHUTDOWN | EWX_FORCEIFHUNG, SHTDN_REASON_FLAG_PLANNED);
    } else if (strcmp(id, "restart") == 0) {
        ok = enable_shutdown_privilege();
        if (ok && !dry) ok = ExitWindowsEx(EWX_REBOOT | EWX_FORCEIFHUNG, SHTDN_REASON_FLAG_PLANNED);
    } else if (strcmp(id, "emptybin") == 0) {
        if (!dry) ok = SUCCEEDED(SHEmptyRecycleBinW(NULL, NULL,
                          SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND));
    } else if (strcmp(id, "settings") == 0) {
        if (!dry) ok = shell_open(L"ms-settings:");
    } else if (strcmp(id, "control") == 0) {
        if (!dry) ok = shell_open(L"control.exe");
    } else if (strcmp(id, "quit") == 0) {
        /* handled by the Tcl layer (ann::quit); dispatch reaching here is a bug */
        Tcl_SetObjResult(ip, Tcl_NewStringObj("quit is handled by the UI layer", -1));
        return TCL_ERROR;
    } else {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("unknown system command \"%s\"", id));
        return TCL_ERROR;
    }
    if (!ok) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("system command \"%s\" failed", id));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj(dry ? "dryrun-ok" : "ok", -1));
    return TCL_OK;
}

/* ------- env-var expansion (cosmetic: %windir% targets in subtitles) --------- */
static int Plat_ExpandEnv(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "str"); return TCL_ERROR; }
    wchar_t *win = u8w(Tcl_GetString(objv[1]));
    wchar_t out[2048];
    DWORD n = ExpandEnvironmentStringsW(win, out, 2048);
    Tcl_Free((char *) win);
    if (n == 0 || n > 2048) {
        Tcl_SetObjResult(ip, objv[1]);          /* unexpandable: hand it back */
        return TCL_OK;
    }
    char *u = NULL;
    int un = WideCharToMultiByte(CP_UTF8, 0, out, -1, NULL, 0, NULL, NULL);
    u = (char *) Tcl_Alloc(un > 0 ? un : 1);
    if (un > 0) WideCharToMultiByte(CP_UTF8, 0, out, -1, u, un, NULL, NULL); else u[0] = 0;
    Tcl_SetObjResult(ip, Tcl_NewStringObj(u, -1));
    Tcl_Free(u);
    return TCL_OK;
}

/* ------- the titlebar-icon menu hook -----------------------------------------
 * Subclasses the toplevel's FRAME window so a left-click on the system-menu icon
 * (hit-test HTSYSMENU) runs OUR callback (the ann menu) instead of opening the
 * standard system menu; the icon double-click (= close) is suppressed as well.
 * Everything runs on the GUI thread (the frame window's owner); the callback is
 * deferred to idle so the menu posts outside the non-client message dispatch. */
static WNDPROC     gSysOld  = NULL;
static HWND        gSysHwnd = NULL;
static Tcl_Interp *gSysIp   = NULL;
static Tcl_Obj    *gSysCb   = NULL;

static void sysmenu_idle(ClientData cd) {
    (void) cd;
    if (gSysIp && gSysCb) {
        if (Tcl_EvalObjEx(gSysIp, gSysCb, TCL_EVAL_GLOBAL) != TCL_OK)
            Tcl_BackgroundException(gSysIp, TCL_ERROR);
    }
}

static LRESULT CALLBACK SysMenuProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_NCLBUTTONDOWN && w == HTSYSMENU) {
        Tcl_DoWhenIdle(sysmenu_idle, NULL);
        return 0;                              /* swallow the standard system menu */
    }
    if (m == WM_NCLBUTTONDBLCLK && w == HTSYSMENU) {
        return 0;                              /* icon double-click must not close */
    }
    return CallWindowProcW(gSysOld, h, m, w, l);
}

/* ---- keep ann OFF the taskbar (owner trick, §9.1) ----------------------------
 * Windows shows taskbar buttons only for UNOWNED top-level windows. Giving the
 * popup a hidden owner removes the button while keeping the normal titlebar
 * (caption icon + min/close — unlike WS_EX_TOOLWINDOW, which would also strip
 * the icon the in-icon menu hangs off). The owner is one tiny never-shown
 * popup window, created on first use and kept for the process lifetime. */
static HWND gHiddenOwner = NULL;

/* annplat::own_window <hwnd> — returns the owner hwnd */
static int Plat_OwnWindow(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    if (!IsWindow(h)) { Tcl_SetObjResult(ip, Tcl_NewStringObj("no such window", -1)); return TCL_ERROR; }
    if (!gHiddenOwner) {
        gHiddenOwner = CreateWindowExW(0, L"STATIC", L"ann_owner", WS_POPUP,
                                       0, 0, 0, 0, NULL, NULL,
                                       GetModuleHandleW(NULL), NULL);
        if (!gHiddenOwner) {
            Tcl_SetObjResult(ip, Tcl_NewStringObj("owner window creation failed", -1));
            return TCL_ERROR;
        }
    }
    SetWindowLongPtrW(h, GWLP_HWNDPARENT, (LONG_PTR) gHiddenOwner);
    /* poke the frame so the shell re-evaluates the (now absent) taskbar button */
    SetWindowPos(h, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj((Tcl_WideInt)(intptr_t) gHiddenOwner));
    return TCL_OK;
}

/* annplat::window_owner <hwnd> — GetWindow(GW_OWNER), 0 = unowned (tests) */
static int Plat_WindowOwner(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj((Tcl_WideInt)(intptr_t) GetWindow(h, GW_OWNER)));
    return TCL_OK;
}

/* annplat::post_message <hwnd> <msg> <wparam> <lparam> — plain PostMessageW
 * (tests + tooling; twapi's raw wrappers want their own typed pointers). */
static int Plat_PostMessage(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 5) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd msg wparam lparam"); return TCL_ERROR; }
    HWND h;
    Tcl_WideInt msg, wp, lp;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    if (Tcl_GetWideIntFromObj(ip, objv[2], &msg) != TCL_OK) return TCL_ERROR;
    if (Tcl_GetWideIntFromObj(ip, objv[3], &wp)  != TCL_OK) return TCL_ERROR;
    if (Tcl_GetWideIntFromObj(ip, objv[4], &lp)  != TCL_OK) return TCL_ERROR;
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(
        PostMessageW(h, (UINT) msg, (WPARAM) wp, (LPARAM) lp) != 0));
    return TCL_OK;
}

static int Plat_HookSysmenu(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "framehwnd callback"); return TCL_ERROR; }
    HWND h;
    if (GetHwnd(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    if (!IsWindow(h)) { Tcl_SetObjResult(ip, Tcl_NewStringObj("no such window", -1)); return TCL_ERROR; }
    /* re-hooking: restore a previous subclass first */
    if (gSysHwnd && IsWindow(gSysHwnd) && gSysOld) {
        SetWindowLongPtrW(gSysHwnd, GWLP_WNDPROC, (LONG_PTR) gSysOld);
    }
    if (gSysCb) { Tcl_DecrRefCount(gSysCb); gSysCb = NULL; }
    gSysIp = ip;
    gSysCb = objv[2]; Tcl_IncrRefCount(gSysCb);
    gSysHwnd = h;
    gSysOld = (WNDPROC) SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR) SysMenuProc);
    if (gSysOld == NULL) {
        Tcl_DecrRefCount(gSysCb); gSysCb = NULL; gSysHwnd = NULL;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("SetWindowLongPtr failed", -1));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

/* ------- cross-thread event bridge proof (DESIGN §3.4) ---------------------
 * The completion flag is HEAP state shared by the command and the queued event
 * handler (both run on the GUI thread; refs is a plain int by design): if the
 * drain loop times out and returns, the event may still be queued — the handler
 * must never write into a dead stack frame, so whoever drops the last ref frees. */
typedef struct { int done; int refs; } RtShared;
typedef struct { Tcl_Event ev; RtShared *sh; } RtEvent;
typedef struct { Tcl_ThreadId gui; RtShared *sh; } RtArg;

static void rt_release(RtShared *sh) {
    if (--sh->refs == 0) Tcl_Free((char *) sh);
}

/* runs on the GUI thread, drained from its event queue */
static int RtHandler(Tcl_Event *e, int flags) {
    (void) flags;
    RtEvent *r = (RtEvent *) e;
    r->sh->done = 1;
    rt_release(r->sh);
    return 1;   /* Tcl_ServiceEvent frees the event */
}

/* runs on the worker thread */
static Tcl_ThreadCreateType RtWorker(ClientData cd) {
    RtArg *a = (RtArg *) cd;
    RtEvent *r = (RtEvent *) Tcl_Alloc(sizeof(RtEvent));
    r->ev.proc = RtHandler;
    r->ev.nextPtr = NULL;
    r->sh = a->sh;
    Tcl_ThreadQueueEvent(a->gui, (Tcl_Event *) r, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(a->gui);
    Tcl_Free((char *) a);
    TCL_THREAD_CREATE_RETURN;
}

static int Plat_ThreadRoundtrip(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 1) { Tcl_WrongNumArgs(ip, 1, objv, NULL); return TCL_ERROR; }

    RtShared *sh = (RtShared *) Tcl_Alloc(sizeof(RtShared));
    sh->done = 0;
    sh->refs = 2;               /* this command + the (future) queued event */
    RtArg *a = (RtArg *) Tcl_Alloc(sizeof(RtArg));
    a->gui = Tcl_GetCurrentThread();
    a->sh = sh;

    Tcl_ThreadId tid;
    if (Tcl_CreateThread(&tid, RtWorker, a, TCL_THREAD_STACK_DEFAULT,
                         TCL_THREAD_NOFLAGS) != TCL_OK) {
        Tcl_Free((char *) a);
        Tcl_Free((char *) sh);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("Tcl_CreateThread failed", -1));
        return TCL_ERROR;
    }

    /* Drain the GUI event queue until the worker's event lands (bounded). */
    DWORD start = GetTickCount();
    while (!sh->done && (GetTickCount() - start) < 2000) {
        if (Tcl_DoOneEvent(TCL_ALL_EVENTS | TCL_DONT_WAIT) == 0) Sleep(1);
    }
    int done = sh->done;
    rt_release(sh);             /* on timeout the queued handler still owns a ref */
    Tcl_SetObjResult(ip, Tcl_NewStringObj(done ? "ok" : "timeout", -1));
    return done ? TCL_OK : TCL_ERROR;
}

int Annplat_Init(Tcl_Interp *ip) {
#ifdef USE_TCL_STUBS
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
#endif
    Tcl_CreateNamespace(ip, "::annplat", NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::active_monitor_rect", Plat_MonitorRect,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::force_foreground",    Plat_ForceForeground,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::dwm_round",           Plat_DwmRound,         NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::thread_roundtrip",    Plat_ThreadRoundtrip,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::launch",              Plat_Launch,           NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::run_split",           Plat_RunSplit,         NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::runas",               Plat_Runas,            NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::open_folder_select",  Plat_OpenFolderSelect, NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::windows",             Plat_Windows,          NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::activate",            Plat_Activate,         NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::close_window",        Plat_CloseWindow,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::syscmd",              Plat_Syscmd,           NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::expand_env",          Plat_ExpandEnv,        NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::hook_sysmenu",        Plat_HookSysmenu,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::post_message",        Plat_PostMessage,      NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::own_window",          Plat_OwnWindow,        NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annplat::window_owner",        Plat_WindowOwner,      NULL, NULL);
    Tcl_PkgProvideEx(ip, "annplat", "0.1", NULL);
    return TCL_OK;
}

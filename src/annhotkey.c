/*
 * annhotkey.c -- global hotkey + single-instance for ann (DESIGN §3.4, §10).
 *
 * The central event-loop problem (DESIGN §3.4): on Windows Tk already owns the
 * GUI thread's Win32 message pump, and a thread-targeted WM_HOTKEY can be
 * swallowed before our code sees it. The robust pattern, implemented here, is a
 * DEDICATED hotkey thread that owns its own message-only HWND (so WM_HOTKEY is
 * delivered to a WndProc we control) and bridges into the GUI thread via
 * Tcl_ThreadQueueEvent + Tcl_ThreadAlert. RegisterHotKey/UnregisterHotKey run on
 * the thread that owns the HWND (this hotkey thread), so the hot-reload rebind is
 * marshalled to it as a thread message (DESIGN §11.2).
 *
 * Commands (all run on the GUI thread):
 *   annhotkey::start <mods> <vk> <tag> <hotkeyCb> <showCb>
 *        -> spawn the hotkey thread, RegisterHotKey(mods|MOD_NOREPEAT, vk) against
 *           an owned message-only window; returns "ok" or errors with the reason.
 *           hotkeyCb is eval'd (global) on the GUI thread for each WM_HOTKEY;
 *           showCb for a "show" request from a second instance.
 *   annhotkey::rebind <mods> <vk>
 *        -> on the hotkey thread: UnregisterHotKey(old) THEN RegisterHotKey(new);
 *           on failure the old chord is restored. Returns "ok" or an error.
 *   annhotkey::stop            -> unregister, tear down the window, join the thread.
 *   annhotkey::active          -> 1 if the hotkey thread is running, else 0.
 *   annhotkey::acquire <tag>   -> single-instance mutex: 1 if we are the first
 *                                 instance, 0 if another already holds it.
 *   annhotkey::signal <tag>    -> (second instance) PostMessage the first
 *                                 instance's window to show itself; 1 if delivered.
 *
 * Compiled INTO ann.exe (ANN_STATIC_HOTKEY) and as a dev stubs .dll (x build-ext).
 */

#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define HK_ID        1
#define WM_ANN_REBIND (WM_APP + 1)   /* window message to gHkWnd: wParam=mods, lParam=vk */
#define WM_ANN_STOP   (WM_APP + 2)   /* window message to gHkWnd: tear down */

/* All of these are written by the hotkey thread before it signals gStartReady,
 * or only on the GUI thread; the event handshakes provide the memory barriers. */
static Tcl_ThreadId gGuiThread = NULL;   /* GUI thread (set on start, used by worker) */
static Tcl_Interp  *gInterp    = NULL;   /* GUI interp (used only on the GUI thread) */
static Tcl_Obj     *gHotkeyCb  = NULL;   /* eval'd on the GUI thread per WM_HOTKEY */
static Tcl_Obj     *gShowCb    = NULL;   /* eval'd on the GUI thread per show request */
static Tcl_ThreadId gHkThread  = NULL;   /* the hotkey thread (for Tcl_JoinThread) */
static DWORD        gHkTid      = 0;      /* Win32 id of the hotkey thread (PostThreadMessage) */
static HWND         gHkWnd      = NULL;   /* owned message-only window */
static UINT         gShowMsg    = 0;      /* RegisterWindowMessage tag for "show" */
static UINT         gCurMods    = 0, gCurVk = 0;
static HANDLE       gMutex      = NULL;   /* single-instance mutex (held for life) */
static char         gClassName[96];

static HANDLE gStartReady = NULL;  /* signaled after the initial RegisterHotKey */
static HANDLE gOpDone     = NULL;  /* signaled after a rebind op completes */
static HANDLE gThreadDone = NULL;  /* signaled by the worker right before it exits */
static BOOL   gStartOk    = FALSE;
static DWORD  gStartErr   = 0;
static BOOL   gOpOk       = FALSE;

/* ---- GUI-thread event: eval a stored callback ---------------------------- */
typedef struct { Tcl_Event ev; int kind; } HkEvent;   /* kind 0=hotkey, 1=show */

static int HkEventProc(Tcl_Event *e, int flags) {
    (void) flags;
    HkEvent *h = (HkEvent *) e;
    Tcl_Obj *cb = (h->kind == 1) ? gShowCb : gHotkeyCb;
    if (gInterp && cb) {
        if (Tcl_EvalObjEx(gInterp, cb, TCL_EVAL_GLOBAL) != TCL_OK) {
            /* route through the (overridden, no-dialog) background error handler */
            Tcl_BackgroundException(gInterp, TCL_ERROR);
        }
    }
    return 1;
}

static int hk_purge_proc(Tcl_Event *e, ClientData cd) {
    (void) cd;
    return e->proc == HkEventProc;
}

static void QueueToGui(int kind) {
    if (!gGuiThread) return;
    HkEvent *e = (HkEvent *) Tcl_Alloc(sizeof(HkEvent));
    e->ev.proc = HkEventProc;
    e->ev.nextPtr = NULL;
    e->kind = kind;
    Tcl_ThreadQueueEvent(gGuiThread, (Tcl_Event *) e, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(gGuiThread);
}

/* ---- hotkey thread ------------------------------------------------------- */
/* All control messages are posted to the owned window (NOT thread messages — a
 * window-owning thread can drop PostThreadMessage), and handled here on the
 * hotkey thread. WM_ANN_STOP breaks the GetMessage loop via PostQuitMessage. */
static LRESULT CALLBACK HkWndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_HOTKEY && w == HK_ID) { QueueToGui(0); return 0; }
    if (gShowMsg && m == gShowMsg)    { QueueToGui(1); return 0; }
    if (m == WM_ANN_REBIND) {
        UINT nm = (UINT) w, nv = (UINT) l;
        UnregisterHotKey(gHkWnd, HK_ID);
        BOOL rr = RegisterHotKey(gHkWnd, HK_ID, nm | MOD_NOREPEAT, nv);
        if (rr) { gCurMods = nm; gCurVk = nv; gOpOk = TRUE; }
        else    { RegisterHotKey(gHkWnd, HK_ID, gCurMods | MOD_NOREPEAT, gCurVk); gOpOk = FALSE; }
        SetEvent(gOpDone);
        return 0;
    }
    if (m == WM_ANN_STOP) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

typedef struct { UINT mods, vk; } HkStart;

static Tcl_ThreadCreateType HkThreadProc(ClientData cd) {
    HkStart *s = (HkStart *) cd;
    UINT mods = s->mods, vk = s->vk;
    Tcl_Free((char *) s);

    gHkTid = GetCurrentThreadId();

    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = HkWndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    /* class name is ASCII in gClassName; widen it */
    WCHAR wclass[96];
    MultiByteToWideChar(CP_UTF8, 0, gClassName, -1, wclass, 96);
    wc.lpszClassName = wclass;
    RegisterClassExW(&wc);   /* ignore "already registered" on a restart */

    gHkWnd = CreateWindowExW(0, wclass, wclass, 0, 0, 0, 0, 0,
                             HWND_MESSAGE, NULL, GetModuleHandleW(NULL), NULL);

    BOOL ok = FALSE;
    if (gHkWnd) {
        ok = RegisterHotKey(gHkWnd, HK_ID, mods | MOD_NOREPEAT, vk);
    }
    gStartOk = ok;
    gStartErr = ok ? 0 : GetLastError();
    if (ok) { gCurMods = mods; gCurVk = vk; }
    SetEvent(gStartReady);

    /* On failure (no window, or the chord was taken) do NOT enter the pump with no
     * hotkey registered — clean up and exit so start() can join+reset and retry. */
    if (!ok) {
        if (gHkWnd) { DestroyWindow(gHkWnd); gHkWnd = NULL; }
        SetEvent(gThreadDone);
        TCL_THREAD_CREATE_RETURN;
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    /* tear down via a LOCAL copy: if this worker was orphaned by a handshake
     * timeout, a successor's gHkWnd must never be clobbered by us. */
    HWND mine = gHkWnd;
    if (gHkWnd == mine) gHkWnd = NULL;
    if (mine) {
        UnregisterHotKey(mine, HK_ID);
        DestroyWindow(mine);
    }
    SetEvent(gThreadDone);
    TCL_THREAD_CREATE_RETURN;
}

/* ---- commands (GUI thread) -----------------------------------------------
 * Handshake policy (review findings #3/#17/#18/#27/#28/#29): every wait result
 * is CHECKED, and we NEVER CloseHandle/reset state while the worker might still
 * be alive. A handshake timeout (pathological: starved loader, hung shell) marks
 * the subsystem WEDGED: handles are deliberately leaked once, start() refuses
 * until the orphan signals gThreadDone, and no recycled-handle corruption is
 * possible. */
static int gWedged = 0;

/* if a previously-wedged orphan has since exited, reclaim its state */
static void hk_reclaim_if_done(void) {
    if (!gWedged || gThreadDone == NULL) return;
    if (WaitForSingleObject(gThreadDone, 0) != WAIT_OBJECT_0) return;
    if (gStartReady) { CloseHandle(gStartReady); gStartReady = NULL; }
    if (gOpDone)     { CloseHandle(gOpDone);     gOpDone = NULL; }
    if (gThreadDone) { CloseHandle(gThreadDone); gThreadDone = NULL; }
    if (gHotkeyCb) { Tcl_DecrRefCount(gHotkeyCb); gHotkeyCb = NULL; }
    if (gShowCb)   { Tcl_DecrRefCount(gShowCb);   gShowCb = NULL; }
    gHkThread = NULL; gHkTid = 0; gWedged = 0;
}

static int Hk_Start(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 6) {
        Tcl_WrongNumArgs(ip, 1, objv, "mods vk tag hotkeyCb showCb");
        return TCL_ERROR;
    }
    hk_reclaim_if_done();
    if (gWedged) { Tcl_SetObjResult(ip, Tcl_NewStringObj("hotkey subsystem wedged (earlier handshake timeout); restart ann", -1)); return TCL_ERROR; }
    if (gHkTid != 0) { Tcl_SetObjResult(ip, Tcl_NewStringObj("hotkey already started", -1)); return TCL_ERROR; }

    int mods, vk;
    if (Tcl_GetIntFromObj(ip, objv[1], &mods) != TCL_OK) return TCL_ERROR;
    if (Tcl_GetIntFromObj(ip, objv[2], &vk)   != TCL_OK) return TCL_ERROR;
    const char *tag = Tcl_GetString(objv[3]);

    snprintf(gClassName, sizeof gClassName, "AnnHotkeyWnd_%s", tag);
    char showName[96];
    snprintf(showName, sizeof showName, "AnnShow_%s", tag);
    gShowMsg = RegisterWindowMessageA(showName);

    gGuiThread = Tcl_GetCurrentThread();
    gInterp = ip;
    if (gHotkeyCb) { Tcl_DecrRefCount(gHotkeyCb); }
    if (gShowCb)   { Tcl_DecrRefCount(gShowCb); }
    gHotkeyCb = objv[4]; Tcl_IncrRefCount(gHotkeyCb);
    gShowCb   = objv[5]; Tcl_IncrRefCount(gShowCb);

    gStartOk = FALSE; gStartErr = 0;        /* reset BEFORE the thread can write */
    gStartReady = CreateEventW(NULL, FALSE, FALSE, NULL);
    gOpDone     = CreateEventW(NULL, FALSE, FALSE, NULL);
    gThreadDone = CreateEventW(NULL, TRUE,  FALSE, NULL);   /* manual-reset */

    HkStart *s = (HkStart *) Tcl_Alloc(sizeof(HkStart));
    s->mods = (UINT) mods; s->vk = (UINT) vk;

    /* Detached (NOFLAGS): the worker self-cleans on exit; we learn it has exited
     * via gThreadDone (bounded wait), never an unbounded Tcl_JoinThread. */
    if (Tcl_CreateThread(&gHkThread, HkThreadProc, s, TCL_THREAD_STACK_DEFAULT,
                         TCL_THREAD_NOFLAGS) != TCL_OK) {
        Tcl_Free((char *) s);
        CloseHandle(gStartReady); gStartReady = NULL;
        CloseHandle(gOpDone);     gOpDone = NULL;
        CloseHandle(gThreadDone); gThreadDone = NULL;
        Tcl_DecrRefCount(gHotkeyCb); gHotkeyCb = NULL;
        Tcl_DecrRefCount(gShowCb);   gShowCb = NULL;
        gHkThread = NULL;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("Tcl_CreateThread failed", -1));
        return TCL_ERROR;
    }
    DWORD w = WaitForSingleObject(gStartReady, 5000);
    if (w != WAIT_OBJECT_0) {
        /* handshake timeout: the worker is in an unknown state — never touch its
         * handles. Ask it to die when it gets there, mark wedged, leak once. */
        if (gHkWnd) PostMessageW(gHkWnd, WM_ANN_STOP, 0, 0);
        gWedged = 1;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("hotkey start timed out; subsystem wedged", -1));
        return TCL_ERROR;
    }
    if (!gStartOk) {
        /* confirmed failure: the worker signaled ready and exits on its own. */
        DWORD wd = WaitForSingleObject(gThreadDone, 3000);
        if (wd != WAIT_OBJECT_0) { gWedged = 1;
            Tcl_SetObjResult(ip, Tcl_NewStringObj("hotkey start failed and worker did not exit; wedged", -1));
            return TCL_ERROR; }
        gHkThread = NULL; gHkTid = 0;
        Tcl_DecrRefCount(gHotkeyCb); gHotkeyCb = NULL;
        Tcl_DecrRefCount(gShowCb);   gShowCb = NULL;
        CloseHandle(gStartReady); gStartReady = NULL;
        CloseHandle(gOpDone);     gOpDone = NULL;
        CloseHandle(gThreadDone); gThreadDone = NULL;
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("RegisterHotKey failed (error %lu — chord likely in use)", gStartErr));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Hk_Rebind(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "mods vk"); return TCL_ERROR; }
    if (gWedged)    { Tcl_SetObjResult(ip, Tcl_NewStringObj("hotkey subsystem wedged", -1)); return TCL_ERROR; }
    if (gHkTid == 0) { Tcl_SetObjResult(ip, Tcl_NewStringObj("hotkey not started", -1)); return TCL_ERROR; }
    int mods, vk;
    if (Tcl_GetIntFromObj(ip, objv[1], &mods) != TCL_OK) return TCL_ERROR;
    if (Tcl_GetIntFromObj(ip, objv[2], &vk)   != TCL_OK) return TCL_ERROR;
    gOpOk = FALSE;                          /* reset: a timed-out wait must not read stale ok */
    if (!PostMessageW(gHkWnd, WM_ANN_REBIND, (WPARAM) mods, (LPARAM) vk)) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("rebind: PostMessage failed", -1));
        return TCL_ERROR;
    }
    DWORD w = WaitForSingleObject(gOpDone, 5000);
    if (w != WAIT_OBJECT_0) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("rebind timed out (hotkey thread unresponsive)", -1));
        return TCL_ERROR;
    }
    if (!gOpOk) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("rebind failed (new chord in use); old chord kept", -1));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Hk_Stop(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    hk_reclaim_if_done();
    if (gHkTid == 0 && !gWedged) { Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1)); return TCL_OK; }
    if (gWedged) { Tcl_SetObjResult(ip, Tcl_NewStringObj("stop-timeout", -1)); return TCL_OK; }
    if (!PostMessageW(gHkWnd, WM_ANN_STOP, 0, 0)) {
        /* window already gone? give the done-event a brief chance, else wedge */
        if (WaitForSingleObject(gThreadDone, 500) != WAIT_OBJECT_0) {
            gWedged = 1;
            Tcl_SetObjResult(ip, Tcl_NewStringObj("stop-timeout", -1));
            return TCL_OK;
        }
    } else if (WaitForSingleObject(gThreadDone, 3000) != WAIT_OBJECT_0) {
        /* worker still alive: do NOT close handles under it — wedge + leak once. */
        gWedged = 1;
        Tcl_SetObjResult(ip, Tcl_NewStringObj("stop-timeout", -1));
        return TCL_OK;
    }
    gHkThread = NULL; gHkTid = 0;
    /* purge stale queued hotkey/show events so they cannot fire into a future
     * instance's callbacks (queue is owned by this GUI thread) */
    Tcl_DeleteEvents(hk_purge_proc, NULL);
    if (gStartReady) { CloseHandle(gStartReady); gStartReady = NULL; }
    if (gOpDone)     { CloseHandle(gOpDone);     gOpDone = NULL; }
    if (gThreadDone) { CloseHandle(gThreadDone); gThreadDone = NULL; }
    if (gHotkeyCb) { Tcl_DecrRefCount(gHotkeyCb); gHotkeyCb = NULL; }
    if (gShowCb)   { Tcl_DecrRefCount(gShowCb);   gShowCb = NULL; }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

static int Hk_Active(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(gHkTid != 0 && !gWedged));
    return TCL_OK;
}

static int Hk_Acquire(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "tag"); return TCL_ERROR; }
    const char *tag = Tcl_GetString(objv[1]);
    char name[110];
    snprintf(name, sizeof name, "Local\\AnnMutex_%s", tag);
    WCHAR wname[110];
    MultiByteToWideChar(CP_UTF8, 0, name, -1, wname, 110);
    gMutex = CreateMutexW(NULL, TRUE, wname);
    if (gMutex == NULL) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("CreateMutex failed", -1));
        return TCL_ERROR;
    }
    int first = (GetLastError() != ERROR_ALREADY_EXISTS);
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(first));
    return TCL_OK;
}

static int Hk_Signal(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "tag"); return TCL_ERROR; }
    const char *tag = Tcl_GetString(objv[1]);
    char cls[96], showName[96];
    snprintf(cls, sizeof cls, "AnnHotkeyWnd_%s", tag);
    snprintf(showName, sizeof showName, "AnnShow_%s", tag);
    WCHAR wcls[96];
    MultiByteToWideChar(CP_UTF8, 0, cls, -1, wcls, 96);
    HWND h = FindWindowExW(HWND_MESSAGE, NULL, wcls, NULL);
    int delivered = 0;
    if (h) {
        UINT msg = RegisterWindowMessageA(showName);
        delivered = PostMessageW(h, msg, 0, 0) ? 1 : 0;
    }
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(delivered));
    return TCL_OK;
}

/* ---- test support: occupy a chord so start/rebind failure paths are testable.
 * Registers hotkey id 2 against the calling (GUI) thread's queue — we never pump
 * it; the point is only that the chord is TAKEN system-wide. */
static int Hk_Occupy(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "mods vk"); return TCL_ERROR; }
    int mods, vk;
    if (Tcl_GetIntFromObj(ip, objv[1], &mods) != TCL_OK) return TCL_ERROR;
    if (Tcl_GetIntFromObj(ip, objv[2], &vk)   != TCL_OK) return TCL_ERROR;
    if (!RegisterHotKey(NULL, 2, (UINT) mods, (UINT) vk)) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("occupy failed (already taken?)", -1));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}
static int Hk_Release(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd; (void) objc; (void) objv;
    UnregisterHotKey(NULL, 2);
    Tcl_SetObjResult(ip, Tcl_NewStringObj("ok", -1));
    return TCL_OK;
}

int Annhotkey_Init(Tcl_Interp *ip) {
#ifdef USE_TCL_STUBS
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
#endif
    Tcl_CreateNamespace(ip, "::annhotkey", NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::start",   Hk_Start,   NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::rebind",  Hk_Rebind,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::stop",    Hk_Stop,    NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::active",  Hk_Active,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::acquire", Hk_Acquire, NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::signal",  Hk_Signal,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::occupy",  Hk_Occupy,  NULL, NULL);
    Tcl_CreateObjCommand(ip, "::annhotkey::release_occupied", Hk_Release, NULL, NULL);
    Tcl_PkgProvideEx(ip, "annhotkey", "0.1", NULL);
    return TCL_OK;
}

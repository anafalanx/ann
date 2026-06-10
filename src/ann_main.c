/*
 * ann_main.c -- custom Windows entry point for ann.
 *
 * A GUI (no-console) WinMain that lets TclZipfs_AppHook self-mount the zipfs
 * archive appended to THIS executable -- which carries main.tcl (= ann.tcl), the
 * Tcl and Tk script libraries, and resources/ -- then hands off to Tk_Main, which
 * runs main.tcl as the startup script. ann's C extensions (the SQLite bridge and
 * the Win32 platform layer) are statically linked and registered in the app-init
 * below; there are no loadable DLLs in the shipped exe.
 *
 * Build requirements (see toolchain.md / DESIGN §4):
 *   -DUNICODE -D_UNICODE -municode  : TclZipfs_AppHook uses the WCHAR signature;
 *                                     without UNICODE the self-mount silently
 *                                     no-ops and main.tcl is never found.
 *   -DSTATIC_BUILD=1                : tcl.h/tk.h must not mark symbols dllimport.
 *   USE_TCL_STUBS undefined         : the host links the real Tcl/Tk libs and
 *                                     calls the real entry points (not stubs).
 *   -mwindows                       : GUI subsystem (no console window).
 *   -D_WIN32_WINNT=0x0A00           : unlock the Win10 Shell/DWM/activation API.
 * ANN_STATIC_DB / ANN_STATIC_PLAT compile the SQLite bridge (src/ann_db.c) and
 * the platform layer (src/ann_plat.c) straight in.
 */

#undef USE_TCL_STUBS
#include "tk.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN
#include <locale.h>
#include <tchar.h>

#if defined(__GNUC__)
int _CRT_glob = 0;          /* keep the mingw CRT from glob-expanding argv */
#endif

#ifdef ANN_STATIC_DB
extern int Anndb_Init(Tcl_Interp *interp);      /* src/anndb.c -- ::anndb::* */
#endif
#ifdef ANN_STATIC_PLAT
extern int Annplat_Init(Tcl_Interp *interp);    /* src/annplat.c -- ::annplat::* */
#endif
#ifdef ANN_STATIC_HOTKEY
extern int Annhotkey_Init(Tcl_Interp *interp);  /* src/annhotkey.c -- ::annhotkey::* */
#endif
#ifdef ANN_STATIC_INDEX
extern int Annindex_Init(Tcl_Interp *interp);   /* src/annindex.c -- ::annindex::* */
#endif
#ifdef ANN_STATIC_ICON
extern int Annicon_Init(Tcl_Interp *interp);    /* src/annicon.c -- ::annicon::* */
#endif

static int Ann_AppInit(Tcl_Interp *interp);

/*
 * Ann_Run -- shared startup: self-mount the appended zipfs at //zipfs:/app
 * (registering //zipfs:/app/main.tcl as the startup script; UNICODE-only WCHAR
 * signature), then hand off to Tk_Main (sources main.tcl, runs the event loop,
 * never returns).
 */
static int Ann_Run(int argc, TCHAR **argv) {
    setlocale(LC_ALL, "C");
    for (TCHAR *p = argv[0]; *p != '\0'; p++) {
        if (*p == '\\') *p = '/';
    }
#if defined(UNICODE)
    TclZipfs_AppHook(&argc, &argv);
#endif
    Tk_Main(argc, argv, Ann_AppInit);
    return 0;
}

#ifdef ANN_CONSOLE
/*
 * Console-subsystem twin entry point (`x build-con`). Identical app, but with a
 * real console: ann::log's stderr writes are visible and a startup error prints
 * as text instead of a modal dialog. The everyday debug build.
 */
int _tmain(int argc, TCHAR **argv) {
    return Ann_Run(argc, argv);
}
#else
/*
 * GUI (no-console) entry point — the shipped ann.exe. Args come from the CRT
 * (wide under -municode); lpszCmdLine is ignored.
 */
int APIENTRY
_tWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
          LPTSTR lpszCmdLine, int nCmdShow) {
    (void) hInstance; (void) hPrevInstance; (void) lpszCmdLine; (void) nCmdShow;
    return Ann_Run(__argc, __targv);
}
#endif

/*
 * Ann_AppInit -- per-interpreter init: Tcl, then Tk (registered as a static
 * library), then ann's statically-linked C extensions.
 */
static int
Ann_AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) == TCL_ERROR) return TCL_ERROR;
    if (Tk_Init(interp) == TCL_ERROR) return TCL_ERROR;
    Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);

#ifdef ANN_STATIC_DB
    if (Anndb_Init(interp) == TCL_ERROR) return TCL_ERROR;
    Tcl_StaticLibrary(interp, "anndb", Anndb_Init, NULL);
#endif
#ifdef ANN_STATIC_PLAT
    if (Annplat_Init(interp) == TCL_ERROR) return TCL_ERROR;
    Tcl_StaticLibrary(interp, "annplat", Annplat_Init, NULL);
#endif
#ifdef ANN_STATIC_HOTKEY
    if (Annhotkey_Init(interp) == TCL_ERROR) return TCL_ERROR;
    Tcl_StaticLibrary(interp, "annhotkey", Annhotkey_Init, NULL);
#endif
#ifdef ANN_STATIC_INDEX
    if (Annindex_Init(interp) == TCL_ERROR) return TCL_ERROR;
    Tcl_StaticLibrary(interp, "annindex", Annindex_Init, NULL);
#endif
#ifdef ANN_STATIC_ICON
    if (Annicon_Init(interp) == TCL_ERROR) return TCL_ERROR;
    Tcl_StaticLibrary(interp, "annicon", Annicon_Init, NULL);
#endif

    return TCL_OK;
}

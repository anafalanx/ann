#!/usr/bin/env tclsh
# tools/genres.tcl -- generate the native build's PE resource inputs from Tcl, so
# they are build artifacts (gitignored), not committed .rc/.manifest source. This
# keeps the repo strictly Tcl + C + one .cmd (the language policy): the only
# Windows-resource/XML content lives here, in Tcl, and is emitted at build time —
# the same way tools/mkico.tcl emits ann.ico.
#
#   tclsh90.exe tools/genres.tcl [outdir]   (default: <root>/build)
#
# Writes <outdir>/ann.exe.manifest and <outdir>/ann.rc. The version is read from
# ann.tcl's `variable version` (single source of truth). windres compiles ann.rc
# with --include-dir <outdir> so it finds the sibling ann.exe.manifest and ann.ico.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set OUT  [lindex $argv 0]
if {$OUT eq ""} { set OUT [file join $ROOT build] }
file mkdir $OUT

# --- version, straight from ann.tcl ------------------------------------------
set fh [open [file join $ROOT ann.tcl] r] ; set src [read $fh] ; close $fh
if {![regexp {variable version "([0-9][0-9.]*)"} $src -> ver]} {
    error "genres: could not read `variable version` from ann.tcl"
}
set parts [split $ver .]
while {[llength $parts] < 4} { lappend parts 0 }
set fv4  [join [lrange $parts 0 3] ,]     ;# FILEVERSION    0,1,0,0
set vdot [join [lrange $parts 0 3] .]     ;# manifest "version"  0.1.0.0

proc emit {path text} {
    set fh [open $path w] ; fconfigure $fh -translation lf
    puts -nonewline $fh $text ; close $fh
}

# --- application manifest -----------------------------------------------------
# Per-Monitor-V2 DPI awareness (DESIGN §9.8: awareness must be set before any HWND
# exists; the popup is positioned via a C-computed monitor rect and tk scaling),
# common-controls v6, UTF-8 active code page, long-path aware.
set manifest [string map [list @VER@ $vdot] {<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"
	xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
    <assemblyIdentity version="@VER@" processorArchitecture="AMD64" name="anafalanx.ann" type="win32"/>
    <description>ann - a keystroke-driven application launcher for Windows</description>
    <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
	<security>
	    <requestedPrivileges>
		<requestedExecutionLevel level="asInvoker" uiAccess="false"/>
	    </requestedPrivileges>
	</security>
    </trustInfo>
    <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
	<application>
	    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
	    <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
	    <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
	    <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
	</application>
    </compatibility>
    <asmv3:application>
	<asmv3:windowsSettings>
	    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
	    <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2, PerMonitor</dpiAwareness>
	    <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
	    <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
	</asmv3:windowsSettings>
    </asmv3:application>
    <dependency>
	<dependentAssembly>
	    <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="AMD64" publicKeyToken="6595b64144ccf1df" language="*"/>
	</dependentAssembly>
    </dependency>
</assembly>
}]
emit [file join $OUT ann.exe.manifest] $manifest

# --- resource script: icon + manifest + version info --------------------------
set rc [string map [list @FV4@ $fv4 @VER@ $ver] {#include <windows.h>

/* app icon (resource name "ann" so Explorer shows the lens, not Tk's feather) */
ann ICON "ann.ico"

/* application manifest: CREATEPROCESS_MANIFEST_RESOURCE_ID (1), RT_MANIFEST (24) */
1 24 "ann.exe.manifest"

VS_VERSION_INFO VERSIONINFO
  FILEVERSION    @FV4@
  PRODUCTVERSION @FV4@
  FILEFLAGSMASK  0x3fL
  FILEFLAGS      0x0L
  FILEOS         VOS_NT_WINDOWS32
  FILETYPE       VFT_APP
  FILESUBTYPE    VFT2_UNKNOWN
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName",      "anafalanx"
            VALUE "FileDescription",  "ann - keystroke launcher"
            VALUE "FileVersion",      "@VER@"
            VALUE "InternalName",     "ann"
            VALUE "LegalCopyright",   "Copyright (C) 2026. MIT/BSD licensed."
            VALUE "OriginalFilename", "ann.exe"
            VALUE "ProductName",      "ann"
            VALUE "ProductVersion",   "@VER@"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
}]
emit [file join $OUT ann.rc] $rc

puts "generated ann.rc + ann.exe.manifest (v$ver) in [file nativename $OUT]"

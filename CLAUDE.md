# Claude / agent instructions

The canonical instructions for this repo live in **[`AGENTS.md`](AGENTS.md)** —
read it first.

Most important: the **full Tcl 9 & Tk 9 manual** (incl. the C-API) ships as
Markdown inside `..\r\tcltk\9.0.3\manual\` (run `z x env` to print the resolved
runtime path; start at `manual/INDEX.md`). It is the authoritative Tcl/Tk
reference for this codebase — before writing or changing Tcl/Tk code (or the C
that drives the embedded interpreter), open the manual pages relevant to your
change (grep the tree). Prefer it over training-data recall, which may be stale
or describe Tcl 8.x.

The product design — what `ann` is and how every subsystem must behave — is in
**[`docs/DESIGN.md`](docs/DESIGN.md)**. Treat it as the spec.

Use the z workspace only through `z.exe` / `z`; do not invoke paths under `..\r\...`,
`..\t\...`, `..\s\...`, or vendored binaries directly. The hosted layout is
`C:\dev\_ann`; from `_ann` run `z <command>` or `..\z.exe <command>`, and
from the z workspace root run `z in ann <command>`.
Strongly avoid PowerShell and Windows cmd for z-backed work. If a shell
snippet is genuinely needed, use `z bash -c "..."`; keep PowerShell and Windows
cmd as only the outer launcher for `z.exe`.

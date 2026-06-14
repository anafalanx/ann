# Claude / agent instructions

The canonical instructions for this repo live in **[`AGENTS.md`](AGENTS.md)** —
read it first.

Most important: the **full Tcl 9 & Tk 9 manual** (incl. the C-API) ships as
Markdown inside the pinned mal bundle, at the store's **`X/<pin>/manual/`** —
where `<pin>` is the bundle named in `toolchain.pin` (run `x env` to print the
resolved bundle path; start at `manual/INDEX.md`). It is the authoritative Tcl/Tk
reference for this codebase — before writing or changing Tcl/Tk code (or the C
that drives the embedded interpreter), open the manual pages relevant to your
change (grep the tree). Prefer it over training-data recall, which may be stale
or describe Tcl 8.x.

The product design — what `ann` is and how every subsystem must behave — is in
**[`docs/DESIGN.md`](docs/DESIGN.md)**. Treat it as the spec.

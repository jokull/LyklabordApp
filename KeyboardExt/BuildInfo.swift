//
//  BuildInfo.swift
//  LyklabordKeyboard
//
//  The KEYBOARD EXTENSION's own build stamp — distinct from App/BuildInfo.swift
//  (App target). iOS caches the running keyboard appex, so a fresh app install
//  doesn't guarantee a fresh extension; this lets the extension self-identify
//  the commit it was actually compiled from (shown on the spacebar in DEBUG,
//  see `DevSpaceContent`) so "which build is really running?" is answerable at
//  a glance.
//
//  ┌─ GENERATED — DO NOT EDIT BY HAND ───────────────────────────────────────┐
//  │ Rewritten on every build by the "Stamp keyboard commit" preBuildScript   │
//  │ on the LyklabordKeyboard target (project.yml), which runs                 │
//  │ `git rev-parse --short HEAD` (+ "+dirty" for an uncommitted tree) before  │
//  │ Compile Sources, in place, only when the value changed.                  │
//  └──────────────────────────────────────────────────────────────────────────┘
//

enum BuildInfo {
    /// Short git commit the extension binary was built from; "+dirty" if the
    /// tree had uncommitted changes at build time.
    static let engineCommit = "fddbed8+dirty"
}

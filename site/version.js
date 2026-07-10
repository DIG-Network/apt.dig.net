// version.js — build-version exposure (CLAUDE.md §6.7). %%APP_VERSION%% is a
// build-time token replaced by packaging/inject-site-version.sh (invoked from the
// Makefile's `repo` target) with the real package.json version — never hand-maintained
// here, so it can't drift. Read by the bug-report widget's auto-detect.
'use strict';
window.__APP_VERSION__ = "%%APP_VERSION%%";

#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "${0%/*}" && pwd)

if ! command -v pwsh >/dev/null 2>&1; then
    echo "CANNOT-RUN: pwsh is not installed or not on PATH; suite not executed." >&2
    exit 2
fi

pwsh -NoLogo -NoProfile -NonInteractive -File "$script_dir/run-tests.ps1"
rc=$?
case "$rc" in
    0) exit 0 ;;
    1) exit 1 ;;
    2) exit 2 ;;
    *)
        echo "FAILED: pwsh exited with unexpected status $rc." >&2
        exit 1
        ;;
esac

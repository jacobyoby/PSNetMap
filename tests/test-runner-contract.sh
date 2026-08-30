#!/bin/sh
set -eu

tests_dir=$(CDPATH= cd -- "${0%/*}" && pwd)
runner="$tests_dir/run-tests.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/empty" "$tmp/bin"

set +e
output=$(PATH="$tmp/empty" "$runner" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
    echo "expected missing pwsh to exit 2, got $rc" >&2
    exit 1
fi
case "$output" in
    CANNOT-RUN:*) ;;
    *)
        echo "missing pwsh did not report CANNOT-RUN" >&2
        exit 1
        ;;
esac

cat > "$tmp/bin/pwsh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_PWSH_ARGS"
exit "${FAKE_PWSH_EXIT:-0}"
SH
chmod +x "$tmp/bin/pwsh"

for expected in 0 1 2; do
    set +e
    FAKE_PWSH_ARGS="$tmp/args" FAKE_PWSH_EXIT="$expected" \
        PATH="$tmp/bin" "$runner" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne "$expected" ]; then
        echo "expected pwsh status $expected to remain $expected, got $rc" >&2
        exit 1
    fi
done

case "$(cat "$tmp/args")" in
    *-NoProfile*-NonInteractive*-File*run-tests.ps1) ;;
    *)
        echo "wrapper did not invoke the canonical PowerShell runner" >&2
        exit 1
        ;;
esac

echo "PASS: runner distinguishes PASS, FAILED, and CANNOT-RUN."

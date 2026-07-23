#!/usr/bin/env bash
# Tests for the ask() input resolver in init.sh.
#
# ask() decides where a value comes from: an INIT_* env var, an interactive
# prompt, or nothing (piped runs with no env var must abort, not hang). These
# three branches are the whole contract, so each gets one named case.
#
# Run: bash tests/ask_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# INIT_SELFTEST makes init.sh define its helpers and return before doing any
# provisioning, so we can exercise ask() in isolation.
INIT_SELFTEST=1 source "${SCRIPT_DIR}/../init.sh"
set +e  # init.sh enables `set -e`; the harness wants to run every case and tally.

pass=0
fail=0

# Assertion guard: compares actual against an explicit expectation, fails on mismatch.
expect() { # <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 — expected '$2', got '$3'"
        fail=$((fail + 1))
    fi
}

# Case 1: env value present → used verbatim, even when non-interactive.
# Catches an inverted/ignored env check.
INTERACTIVE=0
ask GOT1 "oz" "username: "
expect "env value is used when set" "oz" "${GOT1:-}"

# Case 2: env value absent + non-interactive → returns 1, leaves outvar untouched.
# Catches a missing no-TTY guard that would hang or silently default.
INTERACTIVE=0
GOT2="UNTOUCHED"
ask GOT2 "" "username: "
rc=$?
expect "non-interactive + unset returns rc 1" "1" "$rc"
expect "non-interactive + unset leaves outvar untouched" "UNTOUCHED" "$GOT2"

# Case 3: env value absent + interactive → reads the answer from stdin.
# Catches a broken prompt path.
INTERACTIVE=1
ask GOT3 "" "username: " <<< "typed-user"
expect "interactive read populates outvar from stdin" "typed-user" "${GOT3:-}"

echo "----"
echo "${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]

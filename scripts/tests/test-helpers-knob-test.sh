#!/bin/sh
# test-helpers.sh が source のときに test の knob を外すことの self-test (#571)。
# 親の環境に FAKE_* と WAM_EXTRA・REPORT_TZ・RECORD_DIR があっても、source の後の suite には残らない。knob でない
# env は値ごと残す。値に改行や空白を含んでも壊れない。network access なし。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helpers="$script_dir/lib/test-helpers.sh"
[ -f "$helpers" ] || { echo "FAIL: missing $helpers" >&2; exit 1; }

# 親の環境を作って、別の sh で helper を source し (helper の契約どおり script_dir を渡す)、残った knob と、
# 残すべき env の値を出す。knob は source の前に立てる。
# KNOB_TEST_MULTI の 2 行目は knob の名前の形だが、別の env の値の一部 (その名前の env は無い)。
multi='line1
FAKE_NOT_A_VAR=1'
out=$(env FAKE_GH_RC=1 FAKE_CODEX_RC_VERSION=1 'FAKE_SPACED=a b' WAM_EXTRA='extra: 1' REPORT_TZ=EST5 RECORD_DIR=/tmp/x \
  KNOB_TEST_KEEP=kept KNOB_TEST_MULTI="$multi" script_dir="$script_dir" sh -c '
  set -eu
  . "$1"
  for v in FAKE_GH_RC FAKE_CODEX_RC_VERSION FAKE_SPACED WAM_EXTRA REPORT_TZ RECORD_DIR _th_knob; do
    eval "[ -z \"\${$v+x}\" ]" || printf "left: %s\n" "$v"
  done
  printf "keep=%s\n" "${KNOB_TEST_KEEP-}"
  printf "multi=%s\n" "${KNOB_TEST_MULTI-}"
' sh "$helpers")

expected="keep=kept
multi=$multi"
if [ "$out" != "$expected" ]; then
  echo "FAIL: test-helpers.sh did not clear the test knobs (or changed other env). got:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "ok: test-helpers-knob"

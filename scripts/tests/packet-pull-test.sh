#!/bin/sh
# personal-packet pull の self-test (#291)。network は使わず、fake gh の前で実 reader を通す。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# 親の環境の test の knob (PACKET_ENVELOPE_* など) を外してから Ruby の test に渡す (#571。外し方は helper が持つ)。
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"
exec ruby "$script_dir/lib/packet-pull-test.rb" "$script_dir/../../shared/scripts/personal-packet.rb" "$script_dir/../../shared/scripts/personal-safe-gh.rb" "$@"

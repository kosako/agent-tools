#!/bin/sh
# personal-packet pull の self-test (#291)。network は使わず、配備形の sibling reader を fake にする。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/lib/packet-pull-test.rb" "$script_dir/../../shared/scripts/personal-packet.rb" "$@"

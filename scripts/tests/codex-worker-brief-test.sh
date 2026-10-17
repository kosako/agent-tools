#!/bin/sh
# personal-codex-worker の brief の節 (SKILL.md の「## 4. brief」の最初の bullet の一覧) が、worker の一時 file の
# 置き場を clone の外の $TMPDIR に示していることを検査する (#510)。
# 禁止事項が「clone の外への書込」だけだと、作業ツリーに置けば commit に混ざるので、worker は一時 file (safe-run の
# --report や TMPDIR) を clone の .git の下に置き、回収の前の .git の snapshot の照合で止まる。
# - 一時 file の置き場の bullet があり、mktemp -d・$TMPDIR・--report・.git・TMPDIR を向け直さないことを挙げている
# - 禁止事項の bullet の「clone の外への書込」に一時 file の置き場の例外がある (無いと 2 つの bullet が食い違う)
# brief の節の外にだけ語があっても worker には届かないので、child-brief-boundary-test と同じく節の一覧に絞って見る。
# 引数で worker の skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

worker_dir=${1:-"$repo_root/shared/skills/personal-codex-worker"}
[ -f "$worker_dir/SKILL.md" ] || fail "missing $worker_dir/SKILL.md"

ruby - "$worker_dir/SKILL.md" <<'RUBY'
path = ARGV.fetch(0)
lines = File.read(path, encoding: "UTF-8").split("\n")

# 節 (見出しから次の H2 の前まで) の中の最初の一覧 (最初の「- 」から空行の前まで)。
start = lines.index { |l| l =~ /\A## 4\. brief\s*\z/ }
abort "FAIL: codex-worker-brief: SKILL.md に「## 4. brief」の節が無い" if start.nil?
section = lines[(start + 1)..-1]
section = section[0, section.index { |l| l.start_with?("## ") } || section.length]
first = section.index { |l| l.start_with?("- ") }
abort "FAIL: codex-worker-brief: brief の節に一覧が無い" if first.nil?
list = section[first..-1]
list = list[0, list.index { |l| l =~ /\A\s*\z/ } || list.length]

# 一覧を行頭の「- 」で bullet に分け、続きの行は前の bullet に足す。
bullets = []
list.each { |l| l.start_with?("- ") ? bullets << l.dup : bullets[-1] << " " << l.strip }

def find(bullets, label)
  bullets.find { |b| b.start_with?("- #{label}:") }
end

errors = []
tmp = find(bullets, "一時 file の置き場")
if tmp.nil?
  errors << "brief の一覧に「一時 file の置き場:」の bullet が無い"
else
  missing = ["mktemp -d", "`$TMPDIR`", "`--report`", "`.git`", "向け直さない"].reject { |w| tmp.include?(w) }
  errors << "一時 file の置き場の bullet に #{missing.inspect} が無い" unless missing.empty?
end
ban = find(bullets, "禁止事項")
if ban.nil?
  errors << "brief の一覧に「禁止事項:」の bullet が無い"
elsif !ban.include?("clone の外への書込 (下の一時 file の置き場を除く)")
  errors << "禁止事項の「clone の外への書込」に一時 file の置き場の例外が無い"
end

abort "FAIL: codex-worker-brief\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: codex-worker-brief"
RUBY

#!/bin/sh
# personal-codex-worker の brief の節 (SKILL.md の「## 4. brief」の最初の bullet の一覧) が、worker の一時 file の
# 置き場を clone の外の $TMPDIR に示していることを検査する (#510)。
# 禁止事項が「clone の外への書込」だけだと、作業ツリーに置けば commit に混ざるので、worker は一時 file (safe-run の
# --report や TMPDIR) を clone の .git の下に置き、回収の前の .git の snapshot の照合で止まる。
# - 一時 file の置き場の bullet が、置き場 ($TMPDIR の下、--report を含む)・作業ツリーと .git に置かないこと・
#   TMPDIR を向け直さないことを、それぞれ句として書いている (語の有無だけでは、規則を反転した文も通るため)
# - 禁止事項の bullet の「clone の外への書込」に一時 file の置き場の例外がある (無いと 2 つの bullet が食い違う)
# - commit 規則の bullet が、test・build を safe-run 経由で上限を付けて走らせ、safe-run が起動できないときは上限なしで
#   走らせないことを、それぞれ句として書いている (#512。運用 instruction の「test と長時間の command」を worker に届ける)
# - session の記録の bullet に CLI と client の指定が届くことを確かめる (#682)。更新の時機、失敗時の継続、
#   完了の判定と転記への不使用は evals の scenario で確かめる。
# 句は空白を除いて比べ (行の折り返しの位置に依らない)、句の直後が区切り (。、( か末尾) であることも求める (否定は
# 句の後ろに付くので、「置くな」のような反転を部分一致で通さない)。brief の節の外にだけ句があっても worker には届かないので、
# child-brief-boundary-test と同じく節の最初の一覧の項目に絞って見る。節と一覧の取り方は lib/markdown_units.rb が持つ (#685)。
# 引数で worker の skill の directory を差し替えられる (変異での確認用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/test-helpers.sh
. "$script_dir/lib/test-helpers.sh"

worker_dir=${1:-"$repo_root/shared/skills/personal-codex-worker"}
[ -f "$worker_dir/SKILL.md" ] || fail "missing $worker_dir/SKILL.md"

ruby -r"$script_dir/lib/markdown_units" - "$worker_dir/SKILL.md" <<'RUBY'
# encoding: UTF-8
MU = MarkdownUnits
path = ARGV.fetch(0)

# 節の中の最初の一覧の最上位の項目を、子の項目を外した本文で見る (本文を子の項目へ切り出した変更と、項目を丸ごと子の項目に
# 下げた変更を通さない)。
section = MU.section(File.read(path, encoding: "UTF-8"), "## 4. brief")
abort "FAIL: codex-worker-brief: SKILL.md に「## 4. brief」の節が無い" if section.nil?
first = MU.lists(section).first
abort "FAIL: codex-worker-brief: brief の節に一覧が無い" if first.nil?
bullets = first.map { |item| MU.bullets(item).first }

# 句が空白を除いた本文にあり、直後が区切りか末尾であること (helper の clause?)。
def clause?(text, clause)
  MU.clause?(text, clause)
end

# 「- <label>:」で始まる項目 (空白を除いて比べる)。
def find(bullets, label)
  bullets.find { |b| MU.squash(b).start_with?(MU.squash("- #{label}:")) }
end

CLAUSES = {
  "置き場" => "一時 file (`personal-safe-run` の `--report` を含む) は、`mktemp -d` で `$TMPDIR` の下に作った directory に置く",
  "作業ツリーと .git に置かない" => "clone の作業ツリーと `.git` の中には置かず",
  "TMPDIR を向け直さない" => "`TMPDIR` を clone の中へ向け直さない",
}.freeze
EXCEPTION = "clone の外への書込 (下の一時 file の置き場を除く)"
LIMITS = {
  "safe-run 経由" => "test runner・build など長く動く command は、配備済みの `personal-safe-run` " \
                    "(`~/.codex/agent-tools/scripts/personal-safe-run`) 経由で memory と時間の上限を付けて走らせる",
  "起動できないときは走らせない" => "safe-run が command を起動できない (exit 2 で report を書かない) ときは上限なしで走らせない",
}.freeze

errors = []
progress = find(bullets, "session の記録")
if progress.nil?
  errors << "brief の一覧に「session の記録:」の bullet が無い"
else
  ["personal-session-progress", "update --client codex --stdin", "--help", "CODEX_THREAD_ID"].each do |token|
    errors << "session の記録の bullet に #{token} が無い" unless progress.include?("`#{token}`")
  end
end
tmp = find(bullets, "一時 file の置き場")
if tmp.nil?
  errors << "brief の一覧に「一時 file の置き場:」の bullet が無い"
else
  missing = CLAUSES.reject { |_, clause| clause?(tmp, clause) }.keys
  errors << "一時 file の置き場の bullet に句 #{missing.inspect} が無い" unless missing.empty?
end
ban = find(bullets, "禁止事項")
if ban.nil?
  errors << "brief の一覧に「禁止事項:」の bullet が無い"
elsif !clause?(ban, EXCEPTION)
  errors << "禁止事項の「clone の外への書込」に一時 file の置き場の例外が無い"
end
commit = find(bullets, "commit 規則")
if commit.nil?
  errors << "brief の一覧に「commit 規則:」の bullet が無い"
else
  missing = LIMITS.reject { |_, clause| clause?(commit, clause) }.keys
  errors << "commit 規則の bullet に test の上限の句 #{missing.inspect} が無い" unless missing.empty?
end

abort "FAIL: codex-worker-brief\n  " + errors.join("\n  ") unless errors.empty?
puts "ok: codex-worker-brief"
RUBY

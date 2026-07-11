#!/bin/sh
# Credential 隔離 acceptance harness の probe runner (実機・PR-2)。
# Spec: docs/credential-isolation-acceptance.md / 外部 planning tool の設計メモ P3-02。
#
# canonical チャネル (gh / git-https / git-ssh / curl) を private リソースに対し
#   - negative: 隔離 session (lib/credential_isolation_recipe.sh の iso_run) で叩く
#   - positive: 通常 session (ambient credential) で同一コマンドを叩く
#   - reachability control: 隔離 session で同一ホストへ認証なしアクセスを 1 回叩く (#185)
# を観測し、judge 入力の results.json を生成する。
#
# 責務境界 (honest):
#   - runner は「観測」だけを行う。negative と positive は iso_run の有無だけが違う
#     同一コマンドにする (operation identity)。判定は check-credential-isolation.sh
#     (判定コア) の責務、緑/赤の解釈は人間の責務。
#   - probe target は local config 由来 (public repo にハードコードしない)。不在時は
#     明示 fail (silent skip しない)。CI では実行できない (credential 不在) ので、
#     hard 保証は本 runner の実機ログ (PR 添付) が正本。CI 緑を根拠にしない。
#
# 認証成否の判定: private リソースへの認証必須アクセスが成功 (exit 0) すれば
# authenticated=true。隔離 session でこれが false、通常 session で true になるのが
# 隔離が効いている状態。
#
# reachability control (#185): negative は失敗を exit 非ゼロでしか観測しないので、
# 「credential を剥いだから失敗」と「そもそも到達できないから失敗」(一過性障害 /
# proxy が env 隔離で落ちる proxy-delta) を区別できない。そこで隔離 session 内で
# 同一ホストへの認証なしアクセスを 1 回観測し、judge が 3 分岐する (認証成功=leak /
# 認証のみ失敗=緑 / 到達も失敗=indeterminate)。到達成否は transport の成否だけを見て、
# エラー種別 (DNS/TLS/proxy) は解釈しない (4-state taxonomy 不採用)。
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/credential_isolation_recipe.sh
. "$script_dir/lib/credential_isolation_recipe.sh"

CONFIG_DEFAULT="$HOME/.config/dotfiles/github-isolation-probe.local"

usage() {
  cat <<EOF
usage: probe-credential-isolation.sh [--config PATH] [--out FILE] [--dry-run]

canonical チャネル (gh / git-https / git-ssh / curl) を private リソースに対し
隔離 / 非隔離で叩き、認証成否を results.json (judge 入力) として出力する。
各チャネルでは隔離 session 内の認証なし同一ホストアクセス (reachability control) も
1 回観測する (#185。到達不能なら judge が indeterminate に倒す)。

probe target は local config (既定 $CONFIG_DEFAULT) から読む。必須キー (required channels):
  PROBE_GH_REPO=owner/private-repo          # gh api repos/<value>
  PROBE_GIT_HTTPS=https://github.com/owner/private-repo.git
任意キー (git-ssh は ssh-agent、curl は ~/.netrc 依存の opt-in channel。設定時のみ probe):
  PROBE_GIT_SSH=git@github.com:owner/private-repo.git   # scp 形式のみ (reachability の host 抽出)
  PROBE_CURL_URL=https://api.github.com/repos/owner/private-repo

  --config PATH   probe target config (既定: 上記、または GITHUB_ISOLATION_PROBE_CONFIG)
  --out FILE      results.json の出力先 (既定: stdout)
  --dry-run       probe command は実行せず、各チャネルの隔離/非隔離コマンドを表示する
                  (probe は credential に触らないが、config は shell として source 済み。
                   config 検証と組み立ての確認用)

判定は scripts/check-credential-isolation.sh --judge <results.json> で行う。
EOF
}

config="${GITHUB_ISOLATION_PROBE_CONFIG:-$CONFIG_DEFAULT}"
out="-"
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    --config) config=${2:?--config needs a path}; shift 2 ;;
    --out) out=${2:?--out needs a path}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f "$config" ]; then
  echo "error: probe target config not found: $config" >&2
  echo "       local config に PROBE_GH_REPO / PROBE_GIT_HTTPS / PROBE_GIT_SSH / PROBE_CURL_URL を定義してください (--help)。" >&2
  exit 2
fi

# config は private target (owner/repo・URL) の宣言のみ。secret は含めない前提。
# 注意: この config は data ではなく shell として source される (KEY=value 以外に関数
# 定義も評価され、iso_run / amb_run / iso_resolve_bin を override できてしまう)。判定を
# 捏造されないよう、この file は probe 実行者本人が所有する信頼できる local file
# ($HOME/.config 配下・repo 外) に限る。attacker-supplied な file を --config に渡さない
# (H-03: config を書ける主体は results.json も runner 本体も書き換えられるので trust
# boundary は跨がないが、data を装う label と実挙動の乖離をここで honest-label する)。
# shellcheck source=/dev/null
. "$config"

missing=""
for var in PROBE_GH_REPO PROBE_GIT_HTTPS; do
  eval "val=\${$var:-}"
  [ -n "$val" ] || missing="$missing $var"
done
if [ -n "$missing" ]; then
  echo "error: probe target config is missing required keys:$missing ($config)" >&2
  exit 2
fi
# git-ssh (ssh-agent) / curl (~/.netrc) は opt-in。ambient 認証源はセッション依存なので、
# config に target が無ければ probe しない (judge も required 扱いしない)。
probe_ssh=false
[ -n "${PROBE_GIT_SSH:-}" ] && probe_ssh=true
probe_curl=false
[ -n "${PROBE_CURL_URL:-}" ] && probe_curl=true

# 実行バイナリを canonical PATH で 1 度だけ絶対パスに解決し、negative/positive の両方に渡す。
# これで同一 argv だけでなく実行バイナリも一致し、ambient PATH 上の wrapper / 別版で positive
# だけ通る偽の安心を排除する (operation identity, #168 レビュー)。
# curl は opt-in channel の probe に加えて gh / git-https の reachability control でも使うため
# 常に解決する (#185)。git-ssh の reachability は nc (TCP 到達確認)。
GH_BIN=$(iso_resolve_bin gh)   || { echo "error: gh not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
GIT_BIN=$(iso_resolve_bin git) || { echo "error: git not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
CURL_BIN=$(iso_resolve_bin curl) || { echo "error: curl not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
if [ "$probe_ssh" = true ]; then
  NC_BIN=$(iso_resolve_bin nc) || { echo "error: nc not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
  # reachability control 用に host を取り出す。scp 形式 (git@host:path) のみ対応し、
  # それ以外は推測せず明示 fail (fail fast。ssh:// 形式の需要が出たら契約ごと拡張する)。
  case "$PROBE_GIT_SSH" in
    *@*:*) SSH_REACH_HOST=${PROBE_GIT_SSH#*@}; SSH_REACH_HOST=${SSH_REACH_HOST%%:*} ;;
    *)
      echo "error: PROBE_GIT_SSH must be scp-style (git@host:path) so the reachability control can extract the host: $PROBE_GIT_SSH" >&2
      exit 2
      ;;
  esac
fi

# 各チャネルの (negative=隔離 / positive=非隔離) を **同一コマンド** で走らせる。
# negative = iso_run (env 隔離 + 非 repo cwd)、positive = amb_run (ambient env + 非 repo cwd)。
# コマンド・cwd の種類・argv は完全に同一で、唯一の差分は env 隔離の有無 (operation
# identity)。positive は ambient credential (gh keyring / git osxkeychain / ssh-agent /
# ~/.netrc) をそのまま使う。git の per-invocation hardening flags は付けない (env+cwd 隔離が
# config source ごと断つので冗長で、negative だけに付けると identity が崩れる, #168 レビュー)。
#
# gh:        gh api repos/<repo> --silent
# git-https: git ls-remote <https-url>
# git-ssh:   git ls-remote <ssh-url>
# curl:      curl -sfS --netrc -o /dev/null <api-url>  (認証源 = ~/.netrc。--netrc が
#            無いと curl は netrc を一切参照せず、この channel が netrc auth を行使しない, #180)
#
# reachability control (#185) は隔離 session 内で認証なしの同一ホストアクセスを 1 回叩く:
# gh:        curl -sS --max-time 20 -o /dev/null https://api.github.com/repos/<repo>
#            (gh api と同一 host+path を認証なしで。gh binary は credential 不在だと
#             network 前に拒否するため curl で到達を観測する。-f を付けないので 404/403
#             等の HTTP 応答完了 = exit 0 = 到達、transport 失敗のみ非ゼロ)
# git-https: curl -sS --max-time 20 -o /dev/null <https-url>  (同上・同一 host)
# git-ssh:   nc -z -w 20 <host> 22  (TCP 到達確認のみ。ssh 認証の成否は解釈しない)
# curl:      curl -sS --max-time 20 -o /dev/null <api-url>  (--netrc を付けない = 認証なし
#            の同一 URL。-f なし)
# 到達確認だけは応答が返らないとき hang しないよう timeout を付ける (auth probe は
# 人間が見ている手動実行前提のまま・operation identity も崩さないため据え置き)。

# 隔離 session で command を実行し成否 (true/false) を返す。
# negative probe (認証成否) と reachability control (到達成否) の両方が使う。
run_isolated() {
  scratch=$(iso_make_scratch)
  if iso_run "$scratch" "$@" >/dev/null 2>&1; then result=true; else result=false; fi
  rm -rf "$scratch"
  printf '%s\n' "$result"
}

# positive control: ambient session (非 repo cwd) で同一 command を実行し認証成否を返す。
run_positive() {
  if amb_run "$@" >/dev/null 2>&1; then result=true; else result=false; fi
  printf '%s\n' "$result"
}

# dry-run: 実行せず、各チャネルの隔離/非隔離コマンドを表示して終わる。
if [ "$dry_run" = true ]; then
  echo "# dry-run: probe command は実行しません (config は既に shell source 済み)。config=$config"
  echo "# negative = iso_run <scratch> <cmd> (env 隔離 + 非 repo cwd)"
  echo "# positive = amb_run <cmd> (ambient env + 非 repo cwd)。cmd は negative と同一。"
  echo "# reachability = iso_run <scratch> <reach cmd> (隔離 session 内・認証なし同一ホスト, #185)"
  echo "# pinned binaries (negative/positive/reachability 共通): gh=$GH_BIN git=$GIT_BIN curl=$CURL_BIN${NC_BIN:+ nc=$NC_BIN}"
  echo "# gh        cmd: $GH_BIN api repos/$PROBE_GH_REPO --silent"
  echo "# gh        reach: $CURL_BIN -sS --max-time 20 -o /dev/null https://api.github.com/repos/$PROBE_GH_REPO"
  echo "# git-https cmd: $GIT_BIN ls-remote $PROBE_GIT_HTTPS"
  echo "# git-https reach: $CURL_BIN -sS --max-time 20 -o /dev/null $PROBE_GIT_HTTPS"
  if [ "$probe_ssh" = true ]; then
    echo "# git-ssh   cmd: $GIT_BIN ls-remote $PROBE_GIT_SSH"
    echo "# git-ssh   reach: $NC_BIN -z -w 20 $SSH_REACH_HOST 22"
  else
    echo "# git-ssh   skipped: PROBE_GIT_SSH 未設定 (opt-in channel)"
  fi
  if [ "$probe_curl" = true ]; then
    echo "# curl      cmd: $CURL_BIN -sfS --netrc -o /dev/null $PROBE_CURL_URL"
    echo "# curl      reach: $CURL_BIN -sS --max-time 20 -o /dev/null $PROBE_CURL_URL"
  else
    echo "# curl      skipped: PROBE_CURL_URL 未設定 (opt-in channel)"
  fi
  exit 0
fi

gh_neg=$(run_isolated "$GH_BIN" api "repos/$PROBE_GH_REPO" --silent)
gh_pos=$(run_positive "$GH_BIN" api "repos/$PROBE_GH_REPO" --silent)
gh_reach=$(run_isolated "$CURL_BIN" -sS --max-time 20 -o /dev/null "https://api.github.com/repos/$PROBE_GH_REPO")
gith_neg=$(run_isolated "$GIT_BIN" ls-remote "$PROBE_GIT_HTTPS")
gith_pos=$(run_positive "$GIT_BIN" ls-remote "$PROBE_GIT_HTTPS")
gith_reach=$(run_isolated "$CURL_BIN" -sS --max-time 20 -o /dev/null "$PROBE_GIT_HTTPS")
if [ "$probe_ssh" = true ]; then
  giths_neg=$(run_isolated "$GIT_BIN" ls-remote "$PROBE_GIT_SSH")
  giths_pos=$(run_positive "$GIT_BIN" ls-remote "$PROBE_GIT_SSH")
  giths_reach=$(run_isolated "$NC_BIN" -z -w 20 "$SSH_REACH_HOST" 22)
fi
if [ "$probe_curl" = true ]; then
  # --netrc を明示しないと curl は netrc を一切参照しない。この channel の認証源は netrc
  # なので必須 (#180 M-07)。negative 側の netrc 遮断は curl の版で経路が違う: 8.7.1 は NETRC env
  # を見ず $HOME/.netrc を読むので空 HOME (scratch) が断ち、8.16.0+ は NETRC を netrc file 指定に
  # 使うので NETRC=/dev/null が効く。recipe は両方 (空 HOME + NETRC=/dev/null) を設定するので新旧とも遮断される。
  curl_neg=$(run_isolated "$CURL_BIN" -sfS --netrc -o /dev/null "$PROBE_CURL_URL")
  curl_pos=$(run_positive "$CURL_BIN" -sfS --netrc -o /dev/null "$PROBE_CURL_URL")
  # reachability は --netrc を付けない同一 URL (認証なし)。-f も付けない (HTTP 応答完了 = 到達)。
  curl_reach=$(run_isolated "$CURL_BIN" -sS --max-time 20 -o /dev/null "$PROBE_CURL_URL")
fi

# one JSON probe object を出力する。第 5 引数が空でなければ末尾にカンマを付ける。
probe_obj() {
  printf '    { "channel": "%s", "mode": "%s", "operation": "%s", "authenticated": %s }%s\n' "$1" "$2" "$3" "$4" "$5"
}

# one JSON reachability object。operation はペアと別コマンドなので別 id (<pair-op>-reach)。
# 第 4 引数が空でなければ末尾にカンマを付ける。
reach_obj() {
  printf '    { "channel": "%s", "mode": "reachability", "operation": "%s", "reachable": %s }%s\n' "$1" "$2" "$3" "$4"
}

emit() {
  echo '{'
  echo '  "probes": ['
  probe_obj gh        negative gh-api-repo        "$gh_neg"  ,
  probe_obj gh        positive gh-api-repo        "$gh_pos"  ,
  reach_obj gh        gh-api-repo-reach           "$gh_reach" ,
  probe_obj git-https negative git-https-lsremote "$gith_neg" ,
  probe_obj git-https positive git-https-lsremote "$gith_pos" ,
  # required の最後の要素の末尾カンマは、opt-in を続けるかどうかで決まる。
  if [ "$probe_ssh" = true ] || [ "$probe_curl" = true ]; then
    reach_obj git-https git-https-lsremote-reach "$gith_reach" ,
  else
    reach_obj git-https git-https-lsremote-reach "$gith_reach" ""
  fi
  if [ "$probe_ssh" = true ]; then
    probe_obj git-ssh negative git-ssh-lsremote "$giths_neg" ,
    probe_obj git-ssh positive git-ssh-lsremote "$giths_pos" ,
    if [ "$probe_curl" = true ]; then
      reach_obj git-ssh git-ssh-lsremote-reach "$giths_reach" ,
    else
      reach_obj git-ssh git-ssh-lsremote-reach "$giths_reach" ""
    fi
  fi
  if [ "$probe_curl" = true ]; then
    probe_obj curl negative curl-api-repo "$curl_neg" ,
    probe_obj curl positive curl-api-repo "$curl_pos" ,
    reach_obj curl curl-api-repo-reach   "$curl_reach" ""
  fi
  echo '  ]'
  echo '}'
}

if [ "$out" = "-" ]; then
  emit
else
  emit > "$out"
  echo "wrote $out" >&2
fi

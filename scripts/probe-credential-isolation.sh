#!/bin/sh
# Credential 隔離 acceptance harness の probe runner (実機・PR-2)。
# Spec: docs/credential-isolation-acceptance.md / 外部 planning tool の設計メモ P3-02。
#
# canonical チャネル (gh / git-https / git-ssh / curl) を private リソースに対し
#   - negative: 隔離 session (lib/credential_isolation_recipe.sh の iso_run) で叩く
#   - positive: 通常 session (ambient credential) で同一コマンドを叩く
# 両方で認証成否を観測し、judge 入力の results.json を生成する。
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

probe target は local config (既定 $CONFIG_DEFAULT) から読む。必須キー (required channels):
  PROBE_GH_REPO=owner/private-repo          # gh api repos/<value>
  PROBE_GIT_HTTPS=https://github.com/owner/private-repo.git
任意キー (git-ssh は ssh-agent、curl は ~/.netrc 依存の opt-in channel。設定時のみ probe):
  PROBE_GIT_SSH=git@github.com:owner/private-repo.git
  PROBE_CURL_URL=https://api.github.com/repos/owner/private-repo

  --config PATH   probe target config (既定: 上記、または GITHUB_ISOLATION_PROBE_CONFIG)
  --out FILE      results.json の出力先 (既定: stdout)
  --dry-run       実行せず、各チャネルの隔離/非隔離コマンドを表示する
                  (credential に触らない。config 検証と組み立ての確認用)

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
GH_BIN=$(iso_resolve_bin gh)   || { echo "error: gh not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
GIT_BIN=$(iso_resolve_bin git) || { echo "error: git not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
if [ "$probe_curl" = true ]; then
  CURL_BIN=$(iso_resolve_bin curl) || { echo "error: curl not found in canonical PATH ($ISO_PATH)" >&2; exit 2; }
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
# curl:      curl -sfS -o /dev/null <api-url>  (認証源 = ~/.netrc)

# negative probe: 隔離 session で command を実行し認証成否 (true/false) を返す。
run_negative() {
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
  echo "# dry-run: 実行しません (credential に触れません)。config=$config"
  echo "# negative = iso_run <scratch> <cmd> (env 隔離 + 非 repo cwd)"
  echo "# positive = amb_run <cmd> (ambient env + 非 repo cwd)。cmd は negative と同一。"
  echo "# pinned binaries (negative/positive 共通): gh=$GH_BIN git=$GIT_BIN"
  echo "# gh        cmd: $GH_BIN api repos/$PROBE_GH_REPO --silent"
  echo "# git-https cmd: $GIT_BIN ls-remote $PROBE_GIT_HTTPS"
  if [ "$probe_ssh" = true ]; then
    echo "# git-ssh   cmd: $GIT_BIN ls-remote $PROBE_GIT_SSH"
  else
    echo "# git-ssh   skipped: PROBE_GIT_SSH 未設定 (opt-in channel)"
  fi
  if [ "$probe_curl" = true ]; then
    echo "# curl      cmd: $CURL_BIN -sfS -o /dev/null $PROBE_CURL_URL"
  else
    echo "# curl      skipped: PROBE_CURL_URL 未設定 (opt-in channel)"
  fi
  exit 0
fi

gh_neg=$(run_negative "$GH_BIN" api "repos/$PROBE_GH_REPO" --silent)
gh_pos=$(run_positive "$GH_BIN" api "repos/$PROBE_GH_REPO" --silent)
gith_neg=$(run_negative "$GIT_BIN" ls-remote "$PROBE_GIT_HTTPS")
gith_pos=$(run_positive "$GIT_BIN" ls-remote "$PROBE_GIT_HTTPS")
if [ "$probe_ssh" = true ]; then
  giths_neg=$(run_negative "$GIT_BIN" ls-remote "$PROBE_GIT_SSH")
  giths_pos=$(run_positive "$GIT_BIN" ls-remote "$PROBE_GIT_SSH")
fi
if [ "$probe_curl" = true ]; then
  curl_neg=$(run_negative "$CURL_BIN" -sfS -o /dev/null "$PROBE_CURL_URL")
  curl_pos=$(run_positive "$CURL_BIN" -sfS -o /dev/null "$PROBE_CURL_URL")
fi

# one JSON probe object を出力する。第 5 引数が空でなければ末尾にカンマを付ける。
probe_obj() {
  printf '    { "channel": "%s", "mode": "%s", "operation": "%s", "authenticated": %s }%s\n' "$1" "$2" "$3" "$4" "$5"
}

emit() {
  echo '{'
  echo '  "probes": ['
  probe_obj gh        negative gh-api-repo        "$gh_neg"  ,
  probe_obj gh        positive gh-api-repo        "$gh_pos"  ,
  probe_obj git-https negative git-https-lsremote "$gith_neg" ,
  # required の最後の要素の末尾カンマは、opt-in を続けるかどうかで決まる。
  if [ "$probe_ssh" = true ] || [ "$probe_curl" = true ]; then
    probe_obj git-https positive git-https-lsremote "$gith_pos" ,
  else
    probe_obj git-https positive git-https-lsremote "$gith_pos" ""
  fi
  if [ "$probe_ssh" = true ]; then
    probe_obj git-ssh negative git-ssh-lsremote "$giths_neg" ,
    if [ "$probe_curl" = true ]; then
      probe_obj git-ssh positive git-ssh-lsremote "$giths_pos" ,
    else
      probe_obj git-ssh positive git-ssh-lsremote "$giths_pos" ""
    fi
  fi
  if [ "$probe_curl" = true ]; then
    probe_obj curl negative curl-api-repo "$curl_neg" ,
    probe_obj curl positive curl-api-repo "$curl_pos" ""
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

# shellcheck shell=sh
# Credential 隔離 recipe の single source (SSOT)。
# Spec: docs/credential-isolation-acceptance.md P0-B / 外部 planning tool の設計メモ P3-02。
#
# 「隔離機構」は独立 launcher ではなく、この recipe を通過する env 構成として
# operationally 定義する (設計 D1)。probe runner (probe-credential-isolation.sh) が
# source して隔離 session を組む。doc に散らばっていた recipe をここへ集約し、
# 実行される recipe と doc の drift を無くす (doc は「正本は此処」と参照する)。
#
# この file は関数定義のみ。source して使う。network / credential には触らない
# (触るのは runner が組む隔離 session であって、この recipe の構築自体ではない)。

# 隔離 scratch を作り、その path を stdout に返す。
# home/xdg/gh/curl は空の隔離先、cwd は「非 repo の作業ディレクトリ」。
# 非 repo cwd で実行するのは、git に GIT_CONFIG_NOLOCAL が無く、repo 内で走らせると
# cwd の .git/config の credential.helper / http.extraHeader / core.sshCommand 等が
# 読まれて隔離を bypass するため (設計メモ・実機 recon で確認)。
iso_make_scratch() {
  scratch=$(mktemp -d) || return 1
  mkdir -p "$scratch/home" "$scratch/xdg" "$scratch/gh" "$scratch/curl" "$scratch/cwd"
  printf '%s\n' "$scratch"
}

# 隔離 env で command を実行する。第 1 引数は iso_make_scratch の返す scratch dir、
# 残りが実行する command。認証源 (keychain / git credential helper / OAuth cache /
# ssh-agent / ~/.netrc / gh hosts.yml) を env allowlist (env -i) で構造的に断つ。
# denylist (env -u) は列挙漏れに弱いので使わない (設計メモ・Codex hardening)。
#
# hard に保証する射程 (honest-label): 管理された gh / git / curl invocation の
# 「既定 credential 探索が空」であることまで。keychain 直読み (security) /
# absolute path 読み / MCP・browser の login 済み session は env 隔離の射程外
# (P0-A の tool surface 制限 / OS sandbox tier の担当)。
iso_run() {
  iso_scratch=$1
  shift
  # subshell で cd するので呼び出し側の cwd を汚さない。cwd は非 repo scratch に固定。
  (
    cd "$iso_scratch/cwd" || exit 127
    env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
      HOME="$iso_scratch/home" \
      XDG_CONFIG_HOME="$iso_scratch/xdg" \
      GH_CONFIG_DIR="$iso_scratch/gh" \
      CURL_HOME="$iso_scratch/curl" \
      NETRC=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_SYSTEM=/dev/null \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_TERMINAL_PROMPT=0 \
      GIT_ASKPASS=/usr/bin/false \
      SSH_ASKPASS=/usr/bin/false \
      GH_PROMPT_DISABLED=1 \
      GIT_SSH_COMMAND="/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no" \
      "$@"
  )
}

# git channel 用の追加 hardening 引数。git の途中に差し込む:
#   git $(iso_git_flags) ls-remote <url>
# credential.helper / askpass を空にし、http.extraHeader (Authorization 注入面) /
# proxy / cookieFile を無効化、URL 埋め込み credential を die にする。
# env 隔離だけでは cwd 外の設定経路が残りうるので、invocation ごとに明示 override する。
iso_git_flags() {
  printf '%s' "-c credential.helper= -c core.askPass= -c http.extraHeader= -c http.proxy= -c http.cookieFile= -c transfer.credentialsInUrl=die"
}

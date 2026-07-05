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

# canonical PATH。隔離 session の PATH であり、probe の binary 解決の pin 元でもある。
# negative (iso_run) はこの PATH で実行し、runner は iso_resolve_bin でここから gh/git/curl の
# 絶対パスを 1 度だけ解決して negative/positive の両方に渡す。これで同一 argv だけでなく
# **実行バイナリも一致** する (ambient PATH 上の wrapper / 別版で positive だけ通る偽の安心を
# 排除, #168 レビュー)。
ISO_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# canonical PATH で実行ファイルを解決し絶対パスを stdout に返す (見つからなければ非ゼロ)。
iso_resolve_bin() {
  PATH="$ISO_PATH" command -v "$1" 2>/dev/null
}

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
# git の config 由来 credential (osxkeychain helper / http.extraHeader / proxy /
# cookieFile) は、この env 隔離が config source ごと断つ: GIT_CONFIG_NOSYSTEM=1 (system
# gitconfig 無効) + GIT_CONFIG_GLOBAL/SYSTEM=/dev/null (global/system 無効) + 空 HOME +
# **非 repo scratch cwd** (repo-local .git/config を読ませない)。config source が空なので
# `git -c credential.helper=` 等の per-invocation override は不要 (冗長)。かつ per-invocation
# flag を negative だけに付けると positive と operation identity が崩れる (#168 レビュー) ため
# 使わない。
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
      PATH="$ISO_PATH" \
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

# ambient (非隔離) env で command を中立な非 repo cwd で実行する。
# negative (iso_run) と positive の唯一の差分を「env 隔離の有無」だけにするため、cwd は
# positive も非 repo に固定する (repo-local .git/config が差分にならないよう、operation
# identity を保つ, #168 レビュー)。ambient なので keychain / keyring / ssh-agent は生きる。
amb_run() {
  amb_cwd=$(mktemp -d) || return 1
  (
    cd "$amb_cwd" || exit 127
    "$@"
  )
  amb_status=$?
  rm -rf "$amb_cwd"
  return $amb_status
}

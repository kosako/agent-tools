# credential 隔離 acceptance harness (P0-B)

> **Status: PR-1 (skeleton)** — 判定コア + 契約 + recipe 下書き。probe runner (実機実行)・
> 実機 acceptance ログ・reader 配線は **PR-2**。強度ラベルの正本は
> [runtime-injection-defense.md](runtime-injection-defense.md)、設計 spec 正本は外部 planning tool の設計メモ。

untrusted な GitHub content を読む隔離 reader (P0-A) は「secret も write token も持たない隔離
session で読む」前提で成り立つ。その **credential 隔離床 (P0-B)** が実際に効いているか —
隔離 session で GitHub の private access が構造的に失敗するか — を実機で検証する harness。

## 何が hard で何が hard でないか (honest-label)

- **hard に保証するのは**: 管理された `gh` / `git` / `curl` invocation の **既定 credential
  探索が空** であること (実機 negative + positive control で証明)。
- **射程外 (OS sandbox tier が必須・本 Phase スコープ外)**: keychain 直読み (`security`)、
  absolute path 読み、browser / MCP / connector の login 済み session、任意コマンド実行。
  これらに対する構造的遮断は env / config 隔離では不能。
- arbitrary-escape の防止は **P0-A (reader の tool surface 制限)** の担当。P0-B (env 隔離)
  単独では床にならない。両者を合わせて床。
- **MCP GitHub token store の扱い (正本との差分・PR-2 で是正)**: 正本
  [runtime-injection-defense.md](runtime-injection-defense.md) と #129 は P0-B acceptance の
  認証源に MCP token store を挙げているが、MCP token は shell env の認証源ではなく agent の
  MCP context 側にある。env 隔離 harness (本 doc) の射程外で、reader の tool surface 制限
  (P0-A) が担当する。この分界の齟齬は **PR-2 の doc 確定で正本側を honest-label に是正** する。
- 強度ラベルと層別の正本は [runtime-injection-defense.md](runtime-injection-defense.md)。

## 隔離 recipe (env -i allowlist)

recon (2026-07-01・macOS) で各認証チャネルの遮断を実機検証した結果。denylist (`env -u`) は
列挙漏れに弱いため allowlist (`env -i`) に寄せる。

```sh
iso="$(mktemp -d)"; mkdir -p "$iso/home" "$iso/xdg" "$iso/gh" "$iso/curl"
env -i \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
  HOME="$iso/home" XDG_CONFIG_HOME="$iso/xdg" GH_CONFIG_DIR="$iso/gh" \
  CURL_HOME="$iso/curl" NETRC=/dev/null \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null \
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
  GH_PROMPT_DISABLED=1 \
  GIT_SSH_COMMAND="/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no" \
  <command>
```

git チャネルは追加で `git -c credential.helper= -c core.askPass= -c http.extraHeader= -c http.proxy= -c http.cookieFile= -c transfer.credentialsInUrl=die`。

### チャネル別の要点 (recon 検証済み)

| チャネル | 遮断機構 | 取りこぼしがちな偽の安心 |
|---|---|---|
| gh | `GH_CONFIG_DIR=<空>` で keyring ごと断 (host 未登録で keyring 不参照) | env-strip だけでは keyring 認証が残る |
| git-https | `GIT_CONFIG_NOSYSTEM=1` で system gitconfig の osxkeychain helper を断 | `GIT_CONFIG_SYSTEM=/dev/null` では切れない (別経路 load) |
| git-ssh | `unset SSH_AUTH_SOCK` + `GIT_SSH_COMMAND`(`IdentityAgent=none`) | `SSH_AUTH_SOCK` だけでは agent 経由で残る |
| curl | `HOME` / `NETRC` 隔離 | `.netrc` / `.curlrc` / proxy env |

さらに **非 repo の scratch cwd で実行** する (git に `GIT_CONFIG_NOLOCAL` はなく、cwd の
`.git/config` の credential.helper / http.extraHeader / core.sshCommand 等が読まれ bypass に
なるため)。実行前に `git config --show-origin` の scan と `type -a git gh ...` で binary /
config を pin する。

## acceptance 契約 (判定)

harness は隔離 session と非隔離 session で probe を **対に** 走らせ、結果を判定コアに渡す。

- **negative probe**: 隔離 session で private リソースへの認証必須アクセスが **失敗する** こと
  (成功したら credential leak)。public リソースは未認証でも通るので probe 対象にしない。
- **positive control**: 非隔離 session で **同一 operation の** probe が **成功する** こと
  (失敗したら空振り緑 = テストが無意味)。negative と positive は「隔離の有無だけが違う同一
  operation」であること (別操作だと control にならない)。
- **チャネル被覆**: canonical チャネル (gh / git-https / git-ssh / curl) の **すべて** に、
  同一 operation の negative/positive ペアが1組あること。この required set は判定コアに固定して
  あり、呼び出し側 (PR-2 runner) は縮められない (チャネル丸ごとの欠落 = 偽の安心 を弾く)。
- probe 対象の private リソースは **local config / env 由来** (public repo にハードコードしない)。
  不在時は明示エラーにする (silent skip しない)。
- **judge / runner の信頼境界 (honest)**: judge は結果を消費するだけで再実行しないため、runner が
  付けた `operation` ラベルの真正性 (negative と positive が本当に同一コマンドだったか) を構造的に
  検証できない。judge が縛れるのは pair の operation 一致・polarity・チャネル被覆までで、operation
  が実コマンドを正しく指すことの保証は **PR-2 runner の責務** (実機ログが証跡)。judge 側で
  これ以上「検証」したフリをしない (それ自体が偽の安心になる)。

判定は `scripts/check-credential-isolation.sh --judge <results.json>` が行う
(exit `0`=隔離確認 / `1`=破れ検出 / `2`=入力エラー)。`results.json` の形は lib の USAGE を参照:

```json
{
  "probes": [
    { "channel": "gh", "mode": "negative", "operation": "<op id>", "authenticated": false },
    { "channel": "gh", "mode": "positive", "operation": "<op id>", "authenticated": true }
  ]
}
```

canonical チャネル (gh / git-https / git-ssh / curl) すべての同一 operation ペアが必要
(required set は判定コアに固定)。`operation` は「隔離の有無だけが違う同一コマンド」を指す識別子。

## PR 分割

- **PR-1 (この skeleton)**: 判定コア (`scripts/lib/check_credential_isolation.rb`) + CLI
  (`scripts/check-credential-isolation.sh`) + self-test
  (`scripts/tests/check-credential-isolation-test.sh`) + 本 recipe 下書き。probe は実行しない。
- **PR-2**: recipe builder (SSOT) + probe runner (隔離 session で gh/git/curl を実行し
  `results.json` を生成) + **実機 acceptance ログの PR 添付 (hard 保証の正本)** + reader skill
  への recipe 参照追記 + 本 doc の確定。

## 検証境界

CI は判定コアの self-test (fixtures) までを走らせる。実際の credential 遮断は CI では踏めない
(credential 不在)。**CI 緑を hard 保証・配布完了の根拠にしない**。hard 保証は PR-2 の実機
acceptance ログ。

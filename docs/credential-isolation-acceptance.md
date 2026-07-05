# credential 隔離 acceptance harness (P0-B)

> **Status: PR-2** — 判定コア (PR-1) に加え、隔離 recipe の SSOT
> ([scripts/lib/credential_isolation_recipe.sh](../scripts/lib/credential_isolation_recipe.sh)) と
> probe runner ([scripts/probe-credential-isolation.sh](../scripts/probe-credential-isolation.sh)) を実装。
> 実機 acceptance ログは各実行時に取得し PR に添付する (hard 保証の正本)。強度ラベルの正本は
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
- **MCP GitHub token store の扱い (是正済み)**: MCP token は shell env の認証源ではなく agent の
  MCP context 側にあり、env 隔離 harness (本 doc) の射程外で、reader の tool surface 制限 (P0-A) /
  OS sandbox tier が担当する。正本 [runtime-injection-defense.md](runtime-injection-defense.md) の
  P0-B 認証源列挙は当初 MCP token store を含めていたが、PR-2 で env 隔離の射程 (shell env / config
  由来) に是正した。
- 強度ラベルと層別の正本は [runtime-injection-defense.md](runtime-injection-defense.md)。

## 隔離 recipe (env -i allowlist)

recon (2026-07-01・macOS) で各認証チャネルの遮断を実機検証した結果。denylist (`env -u`) は
列挙漏れに弱いため allowlist (`env -i`) に寄せる。

**recipe の正本 (SSOT) は
[scripts/lib/credential_isolation_recipe.sh](../scripts/lib/credential_isolation_recipe.sh)**
(`iso_make_scratch` / `iso_run` / `iso_git_flags`)。probe runner がこれを source して隔離
session を組む。実行される recipe と doc の drift を無くすため、env allowlist の実体はこの doc に
複製せず lib を正本とする (以下はチャネル別の要点のみ)。git チャネルは追加で `iso_git_flags`
(`credential.helper=` / `http.extraHeader=` / `transfer.credentialsInUrl=die` 等) を差し込み、
**非 repo scratch cwd** で実行する。

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
- **チャネル被覆**: **required チャネル (gh / git-https)** の **すべて** に、同一 operation の
  negative/positive ペアが **1組以上** あること。この required set は判定コア
  (`REQUIRED_CHANNELS`) に固定してあり、呼び出し側 (runner) は縮められない (チャネル丸ごとの
  欠落 = 偽の安心 を弾く)。被覆は床であって天井ではない: ペアを増やす拡張は妨げない。
- **git-ssh / curl は opt-in チャネル (PR-2 の honest-label な調整)**: required に据えるのは
  **この Mac に永続的に存在する keychain-backed な認証源** — gh (keyring) と git-https
  (osxkeychain) — に限る。これらはどのセッションでも positive control が立ち、再現可能な緑の床に
  なる。一方 git-ssh の ambient 認証源 (ssh-agent / 1Password agent) と curl の `~/.netrc` は
  **セッション・設定依存**で、ロードされていないと positive control が立たない (空振り緑)。これらを
  required にすると「credential を捏造して positive を立てる」か「vacuous pass を許す」かの
  どちらかを強い、隔離 harness の趣旨 (露出を減らす / 正直に検証する) に反する。よって git-ssh /
  curl は **opt-in**: results に含めれば pair / polarity を検証する (含めたなら完全ペア必須で
  骨抜けにしない) が、無くても required 欠落扱いしない。ambient credential がアクティブな環境では
  config に `PROBE_GIT_SSH` / `PROBE_CURL_URL` を足せばそのチャネルも検証される。
  なお `KNOWN_CHANNELS` は閉語彙 (typo guard) で、canonical 外の channel 名は入力エラーで弾く。
  required set の変更は results.json 側からはできず、判定コアの契約変更 (PR) で行う。
- probe 対象の private リソースは **local config / env 由来** (public repo にハードコードしない)。
  不在時は明示エラーにする (silent skip しない)。
- **judge / runner の信頼境界 (honest)**: judge は結果を消費するだけで再実行しないため、runner が
  付けた `operation` ラベルの真正性 (negative と positive が本当に同一コマンドだったか) を構造的に
  検証できない。judge が縛れるのは pair の operation 一致・polarity・チャネル被覆までで、operation
  が実コマンドを正しく指すことの保証は **PR-2 runner の責務** (実機ログが証跡)。judge 側で
  これ以上「検証」したフリをしない (それ自体が偽の安心になる)。

判定は `scripts/check-credential-isolation.sh --judge <results.json>` が行う。exit code は
incident class を分ける:

- `0` = 隔離確認 (完全被覆かつ全 polarity 正)。
- `1` = **観測された破れ** (credential leak / false-green)。probe の実行結果そのものが赤。
- `2` = **入力・構造エラー** (JSON 不正 / スキーマ違反 / チャネル欠落 / ペア不成立 / 重複)。
  runner 側の不備で、破れの証拠ではない。両方あるときは 1 を優先し、全 failure を報告する
  (構造不備の陰で破れの証跡を抑制しない)。

`results.json` の形と channel 一覧の正本は lib の USAGE (`--help`)。以下は例:

```json
{
  "probes": [
    { "channel": "gh", "mode": "negative", "operation": "<op id>", "authenticated": false },
    { "channel": "gh", "mode": "positive", "operation": "<op id>", "authenticated": true }
  ]
}
```

`operation` は「隔離の有無だけが違う同一コマンド」を指す識別子 (制御文字は入力エラー)。

## PR 分割

- **PR-1 (この skeleton)**: 判定コア (`scripts/lib/check_credential_isolation.rb`) + CLI
  (`scripts/check-credential-isolation.sh`) + self-test
  (`scripts/tests/check-credential-isolation-test.sh`) + 本 recipe 下書き。probe は実行しない。
- **PR-2 (このコミット)**: recipe builder SSOT (`scripts/lib/credential_isolation_recipe.sh`) +
  probe runner (`scripts/probe-credential-isolation.sh`。隔離 / 非隔離で gh/git/curl を private
  target に実行し `results.json` を生成。target は local config 由来・不在時 fail) +
  probe runner の self-test (`scripts/tests/probe-credential-isolation-test.sh`。実 credential に
  触れず recipe の env 構造 / config 不在 fail / dry-run を検証) + reader skill への recipe 参照
  追記 + 本 doc の確定 (MCP 分界の是正)。**実機 acceptance ログは実行ごとに PR に添付する
  (hard 保証の正本)**。

### probe target の指定 (local config)

probe target は public repo にハードコードせず local config から読む
(既定 `~/.config/dotfiles/github-isolation-probe.local`、`GITHUB_ISOLATION_PROBE_CONFIG` /
`--config` で上書き)。必須キー (required channels): `PROBE_GH_REPO` (owner/private-repo) /
`PROBE_GIT_HTTPS`。任意キー (opt-in channels・ambient 認証源がアクティブなときだけ設定):
`PROBE_GIT_SSH` / `PROBE_CURL_URL`。いずれも**認証必須の private リソース**を指す (public だと
未認証でも通り negative が空振りになる)。必須キー不在・欠落時は明示 fail (silent skip しない)。

## 検証境界

CI は判定コアの self-test (fixtures) までを走らせる。実際の credential 遮断は CI では踏めない
(credential 不在)。**CI 緑を hard 保証・配布完了の根拠にしない**。hard 保証は PR-2 の実機
acceptance ログ。

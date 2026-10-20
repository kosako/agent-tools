# repo の設定の baseline (personal-repo-baseline)

個人の GitHub repo の設定 (Dependabot、merge の方式、default branch の保護など) を、あるべき姿 (baseline) と
比べてずれを出す script です (#539)。実体は `shared/scripts/personal-repo-baseline.rb` で、配備先は
`<tool home>/agent-tools/scripts/personal-repo-baseline`。

今あるのは確かめるだけ (`--check`) です。直す `--apply` と、sweep (`personal-maintenance-sweep`) への組み込みは
#539 の続きの PR で足します。

## 運用

- **最初に 1 回、全 repo を見る**: `personal-repo-baseline --all` で、自分が owner の repo を全部確かめる。ずれは
  人が承認してから直す (`--apply` ができるまでは画面で直す)。
- **その後は今の repo だけ**: sweep が、その repo に `--check` をかける (sweep の責務はその repo の中に留める)。
  週 1 回の定期実行や、session の冒頭の確認はしない。設定は勝手には変わらず、ずれるのは repo を作ったとき・画面で
  設定を変えたとき・baseline を変えたときに限られるため。
- **repo を作ったら**: その repo で確かめて直す (`--apply` ができたら `--apply` を 1 回かける)。
- **baseline を変えたら**: その PR の merge の後に、人が `--all` を 1 回かける。

結果には private な repo の名前が出ます。Issue や PR、commit message には貼りません (public-safety の gate は
private な repo の名前を知らないので、gate では止まりません)。public な repo のずれも Issue にはしません
(守りの抜けている箇所を公開することになるため)。

## 使い方

```text
usage: personal-repo-baseline [--help] [--check] [--repo OWNER/REPO | --all]
```

- 引数なし: 今の directory の repo (`gh repo view` が返す repo。env の `GH_REPO` は外して解決する)。
- `--repo OWNER/REPO`: その repo。
- `--all`: 認証した user が owner の repo を API で列挙し、fork・archive 済み・設定 file で除外した repo を外す
  (fork を先に数えるので、archive 済みの fork は fork の件数に入る)。
- `--check`: 確かめるだけ (既定。付けても付けなくても同じ)。

fork・archive 済み・設定 file で除外した repo・admin 権限の無い repo は「対象外」として確かめません。

GitHub は REST API の GET だけで読みます (`gh api`。shell を通さない)。env の `GH_REPO` は gh に渡しません。

### 出力と exit

```text
owner/example (public): ずれ 2 件
  - Dependabot alerts (dependency graph を含む): 今 off / あるべき on
  - merge の方式: 今 squash、merge commit、rebase / あるべき squash だけ
画面で確かめる (API で読めない): Malware alerts、Grouped security updates
```

| exit | 意味 |
|---|---|
| 0 | 確かめた repo にずれが無い (対象外だけのときを含む) |
| 1 | ずれが有る |
| 2 | usage、設定 file が不正、今の repo や repo の一覧を解決できない、確かめられない repo が有る (gh の失敗・想定外の応答) |

GitHub の応答の field が欠けている・null・型が違うときは、その repo を「確かめられない」にします (ずれ無しや off
に倒さない)。`--all` で一部の repo を確かめられないときも、残りの repo は確かめて出し、exit 2 にします。`--all` は
最後に集計の行 (対象の repo の件数と、ずれ無し・ずれ有り・確かめられないの内訳、対象外の理由ごとの件数) を出します。
usage と設定 file の不正は stderr に 1 行出し、理由に設定の中身と path は出しません。

## baseline

正本は script の `BASELINE` です (visibility ごとに、確かめる項目と期待値を持つ)。

| 項目 | public | private | 読み方 |
|---|---|---|---|
| Dependabot alerts (dependency graph を含む) | on | on | `GET repos/{repo}/vulnerability-alerts` (204 = on、404 = off) |
| Dependabot security updates | on | on | `GET repos/{repo}/automated-security-fixes` の `enabled` |
| merge の方式 | squash だけ | squash だけ | repo の `allow_squash_merge` / `allow_merge_commit` / `allow_rebase_merge` |
| merge の後に branch を消す | on | on | repo の `delete_branch_on_merge` |
| `.github/dependabot.yml` | 有る | 有る | `GET repos/{repo}/contents/.github/dependabot.yml` (無ければ `.yaml`) |
| Secret scanning と push protection | on | (使えない) | repo の `security_and_analysis` |
| default branch の ruleset: PR を必須にする | 有る (必要な approve 0) | (使えない) | `GET repos/{repo}/rules/branches/{default branch}` |
| default branch の ruleset: force push と削除の禁止 | 有る | (使えない) | 同上 |
| default branch の ruleset: 必須の check | 設定 file に書いた check を含む | (使えない) | 同上 |

- private の「使えない」は、今のプラン (GitHub Free) の private では ruleset と secret scanning が使えないため
  (ruleset の API は 403 を返す)。private では確かめず、出力の末尾に 1 行で添えます。
- PR を必須にする rule の必要な approve は 0 にします。自分の PR は自分で approve できないので、1 以上にすると
  merge できなくなります。複数の ruleset が PR の rule を持つときは、いちばん厳しいものが効く扱いで比べます。
- 必須の check の名前は repo ごとに違うので、設定 file の `required_checks` に書いた repo だけ確かめます。CI の
  無い repo は書きません (ruleset は PR の必須と force push・削除の禁止だけになる)。
- `.github/dependabot.yml` は repo ごとに中身 (ecosystem) が違うので、script では書きません。無い repo は、repo
  ごとの PR で足します。

### API で読めない項目

- **Malware alerts**、**Grouped security updates**: 変える API も読む API も見つからなかったので、確かめずに
  「画面で確かめる」と出します (repo の Settings の Advanced Security)。grouped security updates は
  `dependabot.yml` の `groups` でも決められ、こちらが画面の設定より優先されます。
- **Dependency graph**: 状態を直接読む API がありません。Dependabot alerts の前提なので、alerts が on なら on と
  みなします。

## 設定 file

`${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/repo-baseline.json` (任意。無ければ除外も必須の check も無し)。
repo の名前は tracked な file に書かず、ここに置きます。

```json
{
  "exclude": ["owner/example-sandbox"],
  "required_checks": {
    "owner/example": ["test (3.4)", "test (system)"]
  }
}
```

- key は `exclude` (対象から外す repo の配列) と `required_checks` (repo から、必須にする check の名前の配列への
  object) だけ。知らない key、型の外れ、OWNER/REPO の形でない名前、空の配列、制御文字、`required_checks` の大文字
  小文字だけ違う key の重なりは不正 (exit 2)。
- repo の名前は大文字小文字を区別しません。rename した repo は、API が返す新しい名前でも除外を照合します。
- `XDG_CONFIG_HOME` は絶対 path のときだけ使い、`HOME` も絶対 path でなければ場所を決めずに止めます
  (`personal-usage-reader` の設定 file と同じ扱い)。symlink は辿った先で判定し、regular file でなければ不正です。

## 限界

- 読むには repo の admin 権限が要ります (merge の方式などの field は admin にだけ返る)。自分が owner の repo が
  対象で、admin 権限の無い repo は対象外です。
- gh の呼び出しに時間の上限は付けていません。network が止まると、gh が戻るまで待ちます。
- test (`scripts/tests/repo-baseline-test.sh`) は gh を fixture の応答を返す偽物に差し替えるので、GitHub の
  API の実際の応答の形は確かめません。応答の形は実機で確かめた (2026-10、gh 2.102.0) ものに合わせています。

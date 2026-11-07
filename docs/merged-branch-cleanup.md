# merge 済みの branch の片付け (personal-merged-branch-cleanup)

merge 済みの自分の branch を、消してよい条件を機械で確かめてから消す script です (#640)。実体は
`shared/scripts/personal-merged-branch-cleanup.rb` で、配備先は `<tool home>/agent-tools/scripts/personal-merged-branch-cleanup`。

squash merge の branch は `git branch -d` では消せず、`git branch -D` と `git push --delete` は host の ask 規則で毎回確認に
なります。ask 規則は、未 merge の作業を含む branch の削除を人に確かめるために残します。運用ルール (#563) が確認なしで許す
「tip が merge した PR の head と一致し、失う commit が無いとき」をこの script が確かめ、host の allow にはこの script だけを
置きます (登録は dotfiles の側)。

```text
usage: personal-merged-branch-cleanup [--repo owner/repo] [--remote] [--dry-run] <branch>...
```

## 消す条件

すべて満たす branch だけを消します。

| 条件 | 外れたときの label |
| --- | --- |
| repo の owner の type が `User` で、login が gh で認証している user と一致する | `not-personal-repo` |
| default branch でない | `default-branch` |
| どの worktree でも checkout されていない | `checked-out` |
| `--remote` のとき、origin が同じ repo を指す | `origin-is-another-repo` |
| `--remote` のとき、local と remote の両方にあれば OID が同じ | `remote-differs` |
| 同じ repo を head にした同じ名前の merged の PR がある (fork の PR と `mergedAt` の無い PR は数えない) | `no-merged-pr` |
| その PR の head の OID が tip と一致する | `tip-is-not-merged-head` |
| その PR の base が default branch である (stacked の親に入っただけの branch は消さない) | `base-is-not-default-branch` |

local に branch が無く `--remote` のときは、remote の OID を tip として同じ条件を確かめます。

## 消し方

- 削除は期待する OID を指定した比較つきで行います。local は `git update-ref -d`、remote は `--force-with-lease` です。確かめた
  後に tip が動くと失敗し、branch は残ります (`local-delete-failed` / `remote-delete-failed`)。
- remote を先に消し、失敗したら local は消しません。
- local を消した後に branch の設定 (`branch.<name>.*`) も外します。`git branch -D` と同じ後始末です。
- `--remote` が無いときは remote に触りません。
- `--dry-run` は確かめるだけで、消せるものを `would-delete:` と出します。

## 出力と exit

1 branch に 1 行で、`deleted:` / `would-delete:` / `absent:` / `refused: <branch> (<label>)` です。載せるのは規則の形に合う
branch 名、PR の番号、閉じた表の label だけで、gh と git の stderr は出しません。PR は状態と OID の field だけを読み、title や
本文は取りません。

| exit | 意味 |
| --- | --- |
| 0 | すべて消した (`--dry-run` なら消せる)、または消す branch が無い |
| 1 | 消さなかった branch がある (ほかの branch は処理する) |
| 2 | usage の誤り、gh か git の失敗、判定できない (応答の形が外れる)。`--repo` が無く env の `GH_REPO` が空でないときも止まる |

branch 名は `\A[A-Za-z0-9][A-Za-z0-9._/-]*\z` に合い、`git check-ref-format` を通るものだけを受けます。`@{-1}` のような省略形は
受けません。

## 強度ラベル (偽らない)

手順の守りであって境界ではありません。script は agent と同じ OS user が書き換えられ、gh の応答をそのまま信じます。確かめるのは
PR の head が merge されたことまでで、merge commit の中身は確かめません。host の allow は、この script の path で書かれた
command に当たるだけで、ほかの書き方の `git branch -D` は ask 規則で今までどおり確認になります。

## Test

`scripts/tests/merged-branch-cleanup-test.sh`。一時 directory の git repo と bare の origin、偽の gh で、消せる case と、条件を
1 つずつ外して branch が残る case、判定できないときの exit 2、gh の stderr を出さないことを確かめます。

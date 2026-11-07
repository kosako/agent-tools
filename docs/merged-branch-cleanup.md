# merge 済みの branch の片付け (personal-merged-branch-cleanup)

merge 済みの自分の branch を、消してよい条件を機械で確かめてから消す script です (#640)。実体は
`shared/scripts/personal-merged-branch-cleanup.rb` で、配備先は `<tool home>/agent-tools/scripts/personal-merged-branch-cleanup`。

squash merge の branch は `git branch -d` では消せず、`git branch -D` と `git push --delete` は host の ask 規則で毎回確認に
なります。ask 規則は、未 merge の作業を含む branch の削除を人に確かめるために残します。運用ルール (#563) が確認なしで許す
「tip が merge した PR の head と一致し、失う commit が無いとき」をこの script が確かめ、host の allow にはこの script だけを
置きます (登録は dotfiles の側)。

```text
usage: personal-merged-branch-cleanup [--remote] [--dry-run] <branch>...
```

対象の repo は origin の URL から決めます。gh は host と repo を明示して照会する (`gh api --hostname github.com`、
`gh pr list --repo github.com/<owner>/<repo>`) ので、`GH_HOST` や `GH_REPO`、gh の既定の repo に左右されません。これで、照会した repo と
消す先の repo が揃います。

## 消す条件

すべて満たす branch だけを消します。

| 条件 | 外れたときの label |
| --- | --- |
| origin の fetch の URL がすべて同じ GitHub の repo を指す (`--remote` のときは push の URL も全部。`git push` は push の URL の全部へ送る)。読むのは下の閉じた形だけで、gh が返す repo の名前も同じであること | `origin-unverified` |
| repo の owner の type が `User` で、login が gh で認証している user と一致する | `not-personal-repo` |
| default branch でない | `default-branch` |
| どの worktree でも checkout されていない | `checked-out` |
| `--remote` のとき、local と remote の両方にあれば OID が同じ | `remote-differs` |
| 同じ repo を head にした同じ名前の merged の PR がある (fork の PR と `mergedAt` の無い PR は数えない) | `no-merged-pr` |
| その PR の head の OID が tip と一致する | `tip-is-not-merged-head` |
| その PR の base が default branch である (stacked の親に入っただけの branch は消さない) | `base-is-not-default-branch` |

読む URL の形は `https://github.com/<owner>/<repo>`、`git@github.com:<owner>/<repo>`、`ssh://git@github.com/<owner>/<repo>` (末尾の `.git`
と `/` は省略可) だけです。userinfo・port・query・fragment のある URL、ssh の host の別名、名前を変えた repo の古い URL では止まります。
insteadOf と pushInsteadOf の書き換えは `git remote get-url` の結果に入っているので、書き換えた先で照合します。

local に branch が無く `--remote` のときは、remote の OID を tip として同じ条件を確かめます。local の ref を読めないときと壊れた ref は
「無い」と読まず、exit 2 で止まります。origin の URL を読めないときも同じです。worktree は PR を確かめた後に見ます (gh の照会の間に checkout されうるため)。

## 消し方

- 削除は期待する OID を指定した比較つきで行います。local は `git update-ref -d`、remote は `--force-with-lease` です。確かめた
  後に tip が動くと失敗し、branch は残ります (`local-delete-failed` / `remote-delete-failed`)。
- 消す直前に checkout されると比較では止まらないので、消した後に worktree を見直し、使われていれば同じ OID で戻して `checked-out` に
  します。消した後の checkout は ref が無いので失敗します。
- remote を先に消し、失敗したら local は消しません。local の削除に失敗しても remote は戻しません (merge 済みの head なので、失う
  commit はありません)。
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
| 2 | usage の誤り、gh か git の失敗、判定できない (応答の形が外れる、origin の URL を読めない) |

branch 名は `\A[A-Za-z0-9][A-Za-z0-9._/-]*\z` に合い、`git check-ref-format` を通るものだけを受けます。`@{-1}` のような省略形は
受けません。

## 強度ラベル (偽らない)

手順の守りであって境界ではありません。script は agent と同じ OS user が書き換えられ、gh の応答をそのまま信じます。確かめるのは
PR の head が merge されたことまでで、merge commit の中身は確かめません。rebase や bisect の途中の branch は worktree の一覧に出ないので
checkout 中と読みません (tip が merge 済みの head と同じなので、消しても commit は失いません)。進行中の checkout が、消した後の確認の後に HEAD を
更新する窓は残ります。`git branch -D` も確認と削除の間に排他を取らないので同じで、起きても HEAD が消えた ref を指すだけで commit は失いません
(`git branch <name> <oid>` で戻せます)。host の allow は、この script の path で書かれた
command に当たるだけで、ほかの書き方の `git branch -D` は ask 規則で今までどおり確認になります。

## Test

`scripts/tests/merged-branch-cleanup-test.sh`。一時 directory の git repo と bare の origin、偽の gh で、消せる case と、条件を
1 つずつ外して branch が残る case、判定できないときの exit 2、gh の stderr を出さないことを確かめます。

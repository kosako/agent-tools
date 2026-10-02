# personal-maintenance-sweep — 規模の決め方 (BUDGET)

`SKILL.md` 手順 2 (規模を決める) と手順 3 (単位ごとの読み直しと停止) の式と値です。手順の正本は
`SKILL.md`、式と既定値の正本はこの file。**数字はすべて実験値**で、消費の実績 (local の state) を見て
直します。固定の仕様として扱いません。

## 残量の読み方

- 読み取り口は personal-project-operating-loop の「割当」と同じものです (各 repo root の
  `.agent-context.local.md` に書かれた command)。書かれていなければ、残量は読めないものとして扱います。
  非公開の usage endpoint や credential を自分で読みに行きません。
- tool ごと (claude-code / codex)、window ごと (5h / 週) に、使った割合と reset の時刻を読み、
  **残り = 100 − 使った割合** に直します。
- 次のどれかなら、その tool の値は使いません (「読めない」として扱う)。
  - 読み取り口が無い・失敗した、値が無い
  - 従量課金 (枠が無い)
  - 古いことの印が立っている、または その window の reset の時刻を過ぎている
- **tool の間で % を比べません** (枠の大きさが違うため)。比べるのは、同じ tool の残りと、その tool の
  予約分・推定消費だけです。

## 設定 (local)

`${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/maintenance-sweep.json` に置きます (repo には置かない)。
無ければ下の既定値を使います。在るのに JSON として読めない、または値の型が違うときは、既定値に黙って
倒さず、開始せずにその旨を報告します。

```json
{
  "reserve": {
    "claude-code": { "floor_pct": 10, "daily_pct": 12 },
    "codex": { "floor_pct": 10, "daily_pct": 6 }
  },
  "start_5h_min_pct": 30,
  "stop_5h_min_pct": 10,
  "issue_cap": 5
}
```

- `floor_pct`: 週の枠で、reset まで常に残しておく床 (%)。
- `daily_pct`: その tool を普段 1 日に使う量 (週の枠に対する %)。reset までの日常の作業の分を予約する。
- `start_5h_min_pct`: 開始の条件。動かす tool の 5h の残りがこれ未満なら開始しない。
- `stop_5h_min_pct`: 停止の条件。単位の終わりに読み直して、5h の残りがこれ未満なら止める。
- `issue_cap`: 1 run で起票する Issue の上限。

## 使える量

tool ごとに、週の window について計算します。

```text
reset までの日数 = (週の reset の時刻 − 今) / 24 時間   (小数のまま)
予約分           = floor_pct + reset までの日数 × daily_pct
使える量         = 週の残り − 予約分
```

例: 週の残り 48%、reset まで 1.9 日、floor 10、daily 12 なら、予約分 = 10 + 1.9 × 12 = 32.8、
使える量 = 48 − 32.8 = 15.2 (%)。

## プリセット

| プリセット | 観点 | 領域 (単位の分け方) | 推定消費 (監査役 / 検証役、週の %) | Codex の effort |
| --- | --- | --- | --- | --- |
| small | 2 (docs、設計・一貫性) | 依頼の範囲。無ければ、変更の多い上位の directory 1 つ | 2 / 2 | low |
| medium | 4 (correctness、security、docs、テスト) | repo 全体 (観点ごとに 1 単位) | 6 / 3 | medium |
| large | 6 (repo-audit の既定の全観点) | repo 全体 (観点ごとに 1 単位。大きい repo は top-level の directory ごとにも分ける) | 12 / 5 | medium |

- 依頼で観点や範囲が指定されたら、それを優先し、プリセットは推定消費の目安にだけ使います。
- Codex に監査・反証させるときの model は、Codex home の `agent-tools-review.config.toml`、無ければ
  user の `config.toml` の top-level の `model = "<値>"` の行から読みます。値が `\A[A-Za-z0-9._-]+\z` に
  合わない、または行が無いときは model を渡さず Codex の既定に任せます (`CODEX-LAUNCH.md` の
  `--ignore-user-config` で user の設定は読まれないため、ここで明示する)。
- Claude の側は今の session の model のまま動きます (skill は model を切り替えない)。

## 選び方

1. 監査役と検証役の tool について、使える量を計算する。
2. 両方の tool の使える量が推定消費 (監査役の値 / 検証役の値) 以上になる、いちばん大きいプリセットを選ぶ。
3. どちらかの tool の値が読めないときは、余りを根拠に広げない: 依頼の範囲、無ければ small。
4. 読める値で small も収まらないときは開始しない。依頼で範囲が指定されていれば、その範囲だけで続けるかを
   確認する。

## 開始と停止の条件

- **開始**: 監査役と検証役の tool のうち、値が読めるものは 5h の残りが `start_5h_min_pct` 以上。読めない
  tool はこの条件を確かめられないので、規模を small に限る。
- **単位の終わりの読み直し**: 次のどれかに当たったら、今の単位で止め、残りの単位を state に残す。
  - 動かしている tool の 5h の残りが `stop_5h_min_pct` 未満
  - 週の使える量が、次の単位の推定消費 (プリセットの推定 ÷ 単位の数) 未満
  - Codex が usage limit で止まった (`codex exec` の出力が `ERROR: You've hit your usage limit` で始まる
    行を含み、exit が 0 でない)。自動では再実行しない
- 止めた run は、それまでの所見の反証・重複の照合・起票・記録まで進めます (読み直しで止めたのは監査の
  単位だけ)。検証役の枠が尽きて反証できない所見は起票せず、state に残します。

## 消費の記録

単位ごとに、始める前と終わった後の、動かした tool の各 window の使った割合を local の state に残します
([RECORD.md](RECORD.md))。何回か溜まったら、プリセットの推定消費と既定値をこの file で直します。

honest-label: 読み取り口の値は、それが最後に更新された時点のもの (例: Codex は最後に Codex を動かした
時点) です。同じ account を別の machine で使った分は、次に読むまで反映されないことがあります。止める
判断の最後の砦は、limit 到達の検知です。

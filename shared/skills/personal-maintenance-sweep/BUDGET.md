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
- **有効かどうかは window ごとに判定します**。次のどれかに当たる window の値は使いません (「読めない」
  として扱う)。同じ tool の別の window の値は、それぞれの判定で使えます。
  - 読み取り口が無い・失敗した、その window の値が無い
  - その tool が従量課金 (枠が無い)
  - 古いことの印が立っている、または その window の reset の時刻を過ぎている
- **tool の間で % を比べません** (枠の大きさが違うため)。比べるのは、同じ tool の残りと、その tool の
  予約分・推定消費だけです。

## 設定 (local)

`${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/maintenance-sweep.json` に置きます (repo には置かない)。
key は省いてよく、省いた key は既定値を使います。在る key の値が範囲の外、知らない key がある、JSON と
して読めない、のどれかなら、**既定値に黙って倒さず、開始せずに**その旨を報告します。

| key | 既定値 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `reserve.<tool>.floor_pct` | claude-code 10 / codex 10 | 0〜100 の数 | 週の枠で、reset まで常に残しておく床 (%) |
| `reserve.<tool>.daily_pct` | claude-code 12 / codex 6 | 0〜100 の数 | その tool を普段 1 日に使う量 (週の枠に対する %)。reset までの日常の作業の分を予約する |
| `start_5h_min_pct` | 30 | 0〜100 の数 | 開始の条件。動かす tool の 5h の残りがこれ未満なら開始しない |
| `stop_5h_min_pct` | 10 | 0〜100 の数で、`start_5h_min_pct` 以下 | 停止の条件。単位の終わりに読み直して、5h の残りがこれ未満なら止める |
| `issue_cap` | 5 | 1〜20 の整数 | 1 run で起票する Issue の上限 |

`<tool>` は `claude-code` と `codex` だけです。次の command で、検証した実効値を出します (exit 0 で実効値の
JSON、exit 2 で理由を stderr に出す)。

```sh
ruby -rjson -e '
DEFAULTS = {
  "reserve" => {
    "claude-code" => { "floor_pct" => 10, "daily_pct" => 12 },
    "codex" => { "floor_pct" => 10, "daily_pct" => 6 },
  },
  "start_5h_min_pct" => 30, "stop_5h_min_pct" => 10, "issue_cap" => 5,
}
base = ENV["XDG_CONFIG_HOME"].to_s.empty? ? File.join(Dir.home, ".config") : ENV["XDG_CONFIG_HOME"]
path = File.join(base, "agent-tools", "maintenance-sweep.json")
fail_with = ->(msg) { warn "maintenance-sweep.json: #{msg}"; exit 2 }
pct = ->(v) { v.is_a?(Numeric) && v >= 0 && v <= 100 }
eff = JSON.parse(JSON.generate(DEFAULTS))
if File.exist?(path)
  user = begin
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    fail_with.call("JSON として読めない")
  end
  fail_with.call("top-level が object でない") unless user.is_a?(Hash)
  unknown = user.keys - DEFAULTS.keys
  fail_with.call("知らない key: #{unknown.join(", ")}") unless unknown.empty?
  if user.key?("reserve")
    r = user["reserve"]
    fail_with.call("reserve が object でない") unless r.is_a?(Hash)
    r.each do |tool, v|
      fail_with.call("reserve の知らない tool: #{tool}") unless DEFAULTS["reserve"].key?(tool)
      fail_with.call("reserve.#{tool} が object でない") unless v.is_a?(Hash)
      v.each do |k, x|
        fail_with.call("reserve.#{tool} の知らない key: #{k}") unless %w[floor_pct daily_pct].include?(k)
        fail_with.call("reserve.#{tool}.#{k} が 0〜100 の数でない") unless pct.call(x)
        eff["reserve"][tool][k] = x
      end
    end
  end
  %w[start_5h_min_pct stop_5h_min_pct].each do |k|
    next unless user.key?(k)
    fail_with.call("#{k} が 0〜100 の数でない") unless pct.call(user[k])
    eff[k] = user[k]
  end
  if user.key?("issue_cap")
    c = user["issue_cap"]
    fail_with.call("issue_cap が 1〜20 の整数でない") unless c.is_a?(Integer) && c >= 1 && c <= 20
    eff["issue_cap"] = c
  end
end
fail_with.call("stop_5h_min_pct が start_5h_min_pct より大きい") if eff["stop_5h_min_pct"] > eff["start_5h_min_pct"]
puts JSON.generate(eff)'
```

## 使える量

tool ごとに、週の window の値が有効なときだけ計算します。

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

- 依頼で観点や範囲が指定されたら、その範囲を監査します。推定消費は、**その範囲を覆う最小のプリセット**
  (観点の数がプリセット以下で、領域がプリセットの領域に収まるもの) の値を使います。例: repo 全体・6 観点
  → large、repo 全体・3 観点 → medium、1 つの directory・2 観点 → small。依頼の範囲を small の値で
  見積もって、分かっている不足を通すことはしません。
- Codex に監査・反証させるときの model は、Codex home の `agent-tools-review.config.toml`、無ければ
  user の `config.toml` の top-level の `model = "<値>"` の行から読みます。値が `\A[A-Za-z0-9._-]+\z` に
  合わない、または行が無いときは model を渡さず Codex の既定に任せます (`CODEX-LAUNCH.md` の
  `--ignore-user-config` で user の設定は読まれないため、ここで明示する)。
- Claude の側は今の session の model のまま動きます (skill は model を切り替えない)。

## 判定の順番

監査役と検証役の tool について、上から順に当てます。先に当たったものが決まりです。

1. **設定が不正**: 開始しない (上の「設定」)。
2. **既知の 5h の不足**: どちらかの tool の 5h の値が有効で、残りが `start_5h_min_pct` 未満 → 開始しない。
   その window の reset の時刻を伝える。週の値が読めないことより先に当てる (読めない値による縮小で、
   分かっている不足を押し切らない)。
3. **読めない値**: どちらかの tool の 5h か週の値が読めない → 余りを根拠に広げない。候補の規模は、依頼の
   範囲があればそれ、無ければ small。読めない理由を伝える。ただし、週の値が読める tool については、候補の
   規模の推定消費 (依頼の範囲なら、それを覆う最小のプリセットの値) が使える量に収まることを確かめる。
   収まらなければ開始しない (依頼の範囲なら、範囲を縮めるかを確認する)。読めない値があることで、
   分かっている週の不足を飛ばさない。
4. **使える量**: 依頼の範囲があれば、その推定消費 (覆う最小のプリセットの値) が両方の tool の使える量に
   収まるかを確かめ、収まれば開始し、収まらなければ範囲を縮めるかを確認する。依頼の範囲が無ければ、両方の
   tool の使える量が推定消費 (監査役の値 / 検証役の値) 以上になる、いちばん大きいプリセットを選ぶ。small も
   収まらなければ開始しない。

## 単位の終わりの読み直しと停止

単位が終わるたびに残量を読み直し、次のどれかに当たったら、今の単位で止め、残りの単位を state に残します。

- 動かしている tool の 5h の値が有効で、残りが `stop_5h_min_pct` 未満
- 週の値が有効で、使える量が次の単位の推定消費 (プリセットの推定 ÷ 単位の数) 未満
- 開始のときは読めた値が、読み直しで読めなくなった (それ以降は余りを根拠に続けない)
- Codex が usage limit で止まった (`codex exec` の出力が `ERROR: You've hit your usage limit` で始まる
  行を含み、exit が 0 でない)。自動では再実行しない

止めた run は、それまでの所見の反証・重複の照合・起票・記録まで進めます (読み直しで止めたのは監査の
単位だけ)。検証役の枠が尽きて反証できない所見は起票せず、state に残します。

## 消費の記録

単位ごとに、始める前と終わった後の、動かした tool の各 window の使った割合を local の state に残します
([RECORD.md](RECORD.md))。何回か溜まったら、プリセットの推定消費と既定値をこの file で直します。

honest-label: 読み取り口の値は、それが最後に更新された時点のもの (例: Codex は最後に Codex を動かした
時点) です。同じ account を別の machine で使った分は、次に読むまで反映されないことがあります。止める
判断の最後の砦は、limit 到達の検知です。

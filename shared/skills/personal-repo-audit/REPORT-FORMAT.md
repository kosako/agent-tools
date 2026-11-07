# personal-repo-audit — 報告の形 (REPORT-FORMAT)

`SKILL.md` 手順 3 で子 agent が返す所見の欄と、手順 6 の報告の雛形です。手順の正本は `SKILL.md`、
欄と雛形の正本はこの file。後段 (personal-maintenance-sweep) がこの欄で所見を読むので、欄の名前や
値の集合を変えるときは後段も合わせて変えます。Codex に read-only で監査させるとき (CODEX-LAUNCH.md)
の最終出力は、同じ欄を JSON にした `findings.schema.json` で、欄や値を変えるときはこれも合わせます。

## 所見の欄

所見ごとに、次の欄をすべて書きます。

| 欄 | 値 | 書き方 |
| --- | --- | --- |
| ID | `F01`, `F02`, … | この報告の中だけの通し番号。深刻度順に振る。run をまたいだ識別には fingerprint を使う |
| fingerprint | `<場所の key>#<topic>` | 重複を照合する鍵 (下記) |
| 観点 | correctness / security / design / test / docs / dependency / comparison | 手順 1 の観点を順に bug / security / 設計・一貫性 / テスト / ドキュメント陳腐化 / 依存・ビルド / 要件・類似との比較 に対応させる。手順 1 で足した観点は短い英語の小文字の名前。2 つに当てはまるときは、推奨の対応で手を入れる側で決める (docs を直すなら docs、code・設定・宣言を直すなら design)。ただし、渡された比較対象との比較から出た所見は comparison のまま (種別は下記の defect / docs-drift / proposal の定義で決める。`SKILL.md` 手順 1) |
| 種別 | defect / docs-drift / debt / proposal | 下記 |
| 深刻度 | high / medium / low | 影響の大きさ。観点が security で種別が defect なら下の「security の所見」の基準 |
| 確度 | 確証 / 有力 / 未確証 | 下記 |
| 場所 | `path:line` (repo 相対、複数可) | 行が決まらない (file 全体、file の不在) ときは path だけ |
| 主張 | 1 文 | 何が問題か |
| 根拠 | 1〜3 文 | 何を見てそう判断したか (どの行、どの command の結果)。secret は値を書かず、種別と場所だけ |
| 影響 | 1〜2 文 | 誰に何が起きるか。具体的に書けないときは深刻度を上げない |
| 推奨 | 1〜2 文 | 推奨する対応 |
| 判断が要るか | いいえ / はい: <理由> | 既存の契約や方針を変える、選択肢が拮抗する、優先度を人が決める必要がある、のどれかなら はい |

### 種別

- **defect**: 動作が誤る、壊れる、安全の穴がある (security の穴を含む)。
- **docs-drift**: docs・コメント・宣言が、実装や実態、または他の docs とずれている (docs 同士の
  食い違いは、新しい方か正本とされている方を実態とみなし、根拠にどちらをそう見たかを書く)。
- **debt**: 今は動くが、保守や変更を難しくする (重複、責務の混在、テストの欠落、脆い仕組み)。
- **proposal**: 欠陥ではない改善や機能の提案 (比較から出た提案を含む)。

### 確度

- **確証**: 主張を実物で確かめた (該当箇所と照合先の両方を読んだ、再現した、参照先が無いことを
  確かめた など)。
- **有力**: 該当箇所は読んだが、前提の一部 (実行時の条件など) を確かめていない。
- **未確証**: 状況からの推測。確かめる方法を根拠に書く。観点が security で種別が defect の候補は、未確証なら
  所見にせず未確定として残す (下の「security の所見」)。

### 判断が要るか (docs-drift のとき)

docs を実態に合わせるだけで済むなら いいえ です。実態の側 (code・規則) を docs に戻す可能性が
あるとき、または docs から消えると保証 (安全の検査など) が失われるときは はい にし、どちらに
合わせるかを理由に書きます。

### fingerprint

run をまたいで同じ問題を同じ値で指すための鍵です。行が動いても変わらず、同じ file の別の箇所の
問題とは別の値になるように、次の規則で決めます。

- 形は `<場所の key>#<topic>`。例: `scripts/sync.sh@apply_target#unquoted-path-in-command`、
  `docs/onboarding.md#stale-script-count`、`docs/#broken-relative-links`。
- **場所の key** (次の順に、最初に当てはまるもの):
  1. 問題が 1 つの file の中の名前つきの単位 (関数・method・class・Markdown の見出し) に収まる:
     `<repo 相対の path>@<最も内側の単位の名前>`。見出しは記号を除いた見出しの文字列。
  2. 1 つの file の中だが、名前つきの単位に収まらない (file の先頭の設定、file 全体、file の不在):
     `<repo 相対の path>`。
  3. 複数の file にまたがる: それらの file の最も深い共通の directory に `/` を付けたもの (repo の
     root なら `./`)。
- **topic**: 問題を表す短い英語の kebab-case (小文字・数字・`-`)。値や行番号で変わる語を入れない。
- 入れないもの: 行番号、観点、深刻度、確度、日付 (run ごとに揺れるため)、secret の値と絶対 path
  (public にできないため)。
- 同じ問題には同じ fingerprint を付けます。観点をまたいでまとめた所見は 1 つの fingerprint にします。
- **一致は重複の候補であって、同じ問題の証明ではありません**。fingerprint が一致しても、場所と
  主張を読み比べて同じ問題と確かめてから統合します。別の問題と分かったら、片方の topic を
  区別できる語に変えます (例 `-in-dry-run`)。逆に、関数や見出しの名前が変わると同じ問題でも
  fingerprint が変わるので、照合する側は完全一致に加えて、同じ path を含む fingerprint の所見も
  読み比べます。

## security の所見

観点が security で、種別が defect (安全の穴) の候補は、上の欄に加えて次の条件で扱います。docs-drift・debt・
proposal の所見には当てません。探す場所の類型は [SECURITY-CLASSES.md](SECURITY-CLASSES.md) で、条件と基準の出典も
その冒頭にあります。

### 所見にする条件

次の 6 つを、repo の中の根拠で書けるときだけ defect の所見にします。

1. 誰が: 信頼の低い側 (第三者の Issue や PR の author、fork、依存の配布元、監査対象の file の書き手、MCP の
   server、model の出力など)。
2. 何を: その側が制御できる入力や操作。
3. どの仕組みが: 止めるはずの検査・権限の絞り込み・隔離と、それが効かない場所。
4. どの境界を: 越える信頼の境界。
5. 誰の何に: 影響を受ける主体や resource。
6. 何が起きるか: 結果 (secret が外に出る、write の操作が走る、sandbox の外で command が走る、など)。

根拠には 1〜5 の経路 (入力から結果までの repo の中の道筋と、効かない仕組みの場所) を書き、影響には「誰が、どの
境界を越えて、何ができるか」を 1〜2 文で書きます。確度は 確証 か 有力 に限ります。

次のものは security の defect にしません。

- 推奨の作法が無いだけで、影響を受ける主体も resource も無いもの。残すなら強化の案として種別 proposal・深刻度 low
  にする。
- 同じ主体の中で起きること。例: user が自分で渡した path の file を、user の権限の script が消す。
- prompt injection の文面があるだけのもの。その文面が別の主体の context に入り、その主体の権限で操作や開示を
  起こす経路 (code・設定・手順の上の) を示せたときに所見になる。
- 結果を、確かめたより強く書いたもの (crash を任意の code の実行と書く、自分の操作を権限の取得と書く、など)。

prompt や instruction の文言 (「〜しない」と書いただけの guardrail) は、境界の仕組みとして数えません。数えるのは、
決定的な検査、権限の絞り込み、隔離、承認と操作の対応づけ (承認した操作と実行する操作が同じだと確かめる)、範囲を
絞った credential です。repo が steering (enforcement ではない) と明示している層は、説明と実装が合っているかを見ます
(enforcement と書いていれば docs-drift か defect)。

### 未確定

境界や結果が repo の外の事実 (GitHub の branch protection や Actions の権限、tool の sandbox の設定、配備先の設定、
外部の service の振る舞い) に依るときは、その事実が有るとも無いとも決めません。所見にせず、「判断が要る点」に
未確定として残します。確度が 未確証 にとどまる security の defect の候補も同じです。repo の中の根拠で否定できる
候補は未確定にせず、「問題に見えて実は問題でないもの」に入れます。

- 形: `- 未確定 (security): <場所> — <仮説の境界と結果>。確かめるには: <足りない事実と、安全な確かめ方>`。
  JSON (`findings.schema.json`) では `decisions[]` に入れ、`finding_id` を空文字、`question` を同じ文にする。
- 未確定には深刻度を付けません。
- 攻撃の手順が分かる書き方をしません (結果は public な Issue の材料になりうる)。

### 深刻度

security の defect の深刻度は、示した結果で決めます。示した影響を超えて上げません (「影響」の欄の「具体的に書けない
ときは深刻度を上げない」を、security で具体にしたもの)。

- **high**: 明示した安全の仕組み (gate、sandbox、権限、承認、credential の隔離) を完全に破り、実害のある操作が
  できる。例: 第三者が書いた内容で、user の権限の write や外への送信が走る。secret が public な場所に出る。
  sandbox の外で任意の command が走る。
- **medium**: 境界は越えるが、及ぶ範囲が狭い、前提がまれ、または仕組みを弱めるだけで破らない。
- **low**: secret でない内部の情報が見える、または大きな手間で小さな効果しか得られない。

high と medium の分かれ目は、示した結果が仕組みを完全に破るか、弱めるだけかです。起きる被害を具体的に書けない
なら、感じるより低い深刻度にします。

## 報告の雛形

```text
## サマリ
<全体の健全性と、最も重要な数点>
所見: high N / medium N / low N (判断が要る N)

## 所見 (深刻度順)
### F01 <短い題>
- fingerprint: scripts/sync.sh@apply_target#unquoted-path-in-command
- 観点: security
- 種別: defect
- 深刻度: high
- 確度: 確証
- 場所: scripts/sync.sh:42
- 主張: …
- 根拠: …
- 影響: …
- 推奨: …
- 判断が要るか: いいえ

### F02 …

## 問題に見えて実は問題でないもの
- <場所> — <一見の問題> → <問題でない理由 (根拠)>

## 判断が要る点
- F0N: <何を決める必要があるか、選択肢>
- 未確定 (security): <場所> — <仮説の境界と結果>。確かめるには: <足りない事実と、安全な確かめ方>

## 対象範囲
- 見た範囲: …
- 一部だけ見た範囲: … (どこまで見たか)
- 見ていない範囲: … (理由)
- 未 commit の変更: なし | <含めた file> (作業ツリーを読んだため)
- 下調べ: 変更の多い場所 (期間、上位の file を 3〜5 個) / 壊れた参照の候補 N 件 (所見 N・問題でない N)
```

`|` はどちらか一方を書く、の意味です。下調べを実施できなかったときは、下調べの行を
`- 下調べ: 未実施 (理由)` にします。

中身が無い節は「なし」と書いて残します。

利用できる skill の一覧に personal-maintenance-sweep があるときだけ、最後に次の 1 行を足します。どちらの行に
するかは、この監査を回している session の種類で決めます。種類は model の自認ではなく env の目印で決め、規則は
personal-review-request の Claude route の「どの session で動いているか」と同じです (目印は非空なら立っている。
OpenCode の目印を先に見る)。

Claude Code の session では、次の 1 行です。

```text
この結果から反証・重複の照合・起票へ進むなら、personal-maintenance-sweep で続けられます (この監査結果から始められます)。
```

それ以外 (Codex の session、OpenCode の session、種類を判定できない session) では、次の 1 行です。sweep は、
起動の境界 (connector と MCP を外した起動) の外の session でした監査の結果を反証の入力にしないので、
この結果からは続けられません (#425)。

```text
反証・重複の照合・起票へ進むなら、Claude Code の session で personal-maintenance-sweep を始めてください (この session の監査結果は引き継がず、監査からやり直します)。
```

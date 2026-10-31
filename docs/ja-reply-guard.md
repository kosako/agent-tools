# 答えが英語に逸れたら書き直させる Stop hook (personal-ja-reply-guard)

`shared/scripts/personal-ja-reply-guard.rb` は Claude Code の Stop hook の本体です (#588)。turn の最後の答えが英語に
逸れていたら、1 回だけ終了を止めて日本語で書き直させます。

運用 instruction は対話を日本語にすると決めていますが、Claude Code の答えはたまに英語になります。特に、background
task の通知や command の出力に続けて答えるときに逸れやすく、instruction だけでは止められません。

## 判定

Stop の入力の `last_assistant_message` (最後の答えの text) を読み、数えない区間を除いてから、英字 (`[A-Za-z]`) と
日本語の文字 (ひらがな・カタカナ・漢字・長音) を数えます。

- 数えない区間: fenced code block、inline code、URL、mail、Markdown の link の行き先 (link の本文は数える)、識別子の形
  (英数字の並びを `-` `_` `.` `/` `:` でつないだもの。path・flag・test の名前など)。
- fenced code block は行ごとに読みます。行の頭 (空白の後) の ```` ``` ```` か `~~~` (3 つ以上) で開き、同じ記号が同じ数
  以上並ぶ行で閉じます。閉じていなければ末尾までです。```` ``` ```` の開きの行の後ろに `` ` `` があれば、fence ではなく
  inline code として読みます。
- inline code は、開きの `` ` `` の並びと同じ長さの並びで閉じます (``` `` a`b `` ``` も 1 つの区間)。閉じの無い並びは
  そのまま数えます。
- どの区間も、入力の長さに対して線形の時間で数えます (長い非一致の入力で hook を待たせない)。
- 逸れの条件: 英字が 25 字以上で、日本語の文字の 3 倍を超える。英字が 25 字未満の答えは対象外です。
- 閾値は env で変えられます (下の「env」)。

## 測定 (閾値の根拠)

2026-11-01 に、手元の Claude Code の transcript (12 project・77 session) の各 turn の最後の答え 2421 件に判定を当て
ました。harness や probe の一時 project の答えは除いています。答えの本文は写さず、件数だけを残します。

- 逸れと判定したのは 165 件 (6.8%) です。150 件は日本語の文字を 1 つも含まず、残りの 15 件は日本語を少し含みます
  (英語の文の中に日本語の語を引いた形で、句点は 1 つ以下)。
- 直前の入力で分けると、background task の通知や command の出力への答えが 113 件、日本語の prompt への答えが 49 件、
  英語の prompt への答えが 3 件です。
- 日本語の答え (日本語の文字が 100 字以上で句点が 2 つ以上、1369 件) の英字と日本語の比は、p50 が 0.45、p99 が
  1.16、最大が 1.5 です。閾値の 3 倍とは十分に離れています。
- 識別子の形を数えない区間に入れる前は、日本語の答えを 1 件、逸れと誤って判定していました。backtick の外に
  test の名前を並べた答えです。識別子の形を除くと誤判定は 0 件になり、逸れの判定は 169 件から 165 件に減りました。
  減った 4 件は、どれも識別子を除くと英字が 25 字未満になる答えで、上の誤判定の 1 件を含みます。新たに逸れと
  判定したものはありません。
- 閾値を 2 倍にすると、日本語の文を含む答えも逸れと判定します (句点が 2 つ以上のものが 4 件)。4 倍にしても、逸れの
  判定は 165 件で変わりません。参考にした実装と同じ 3 倍にしました。
- 同じ日に、fenced code と inline code の読み方を上の形に直しました (#606 の review)。直す前と後の判定を、その時点の
  2424 件で比べると同じでした。

## 止め方と loop の防ぎ方

- 逸れていたら、stderr に理由 (日本語で書き直す依頼。答えの text は載せない) を書いて exit 2 で終わります。Claude
  Code は stderr を、続ける理由として Claude に渡します。
- 書き直しは 1 turn に 1 回だけです。`stop_hook_active` が true (stop hook で既に続けている) なら止めません。
  書き直しの後の答えも英語なら、そのまま通します。Claude Code 自体にも、stop hook が続けて 8 回止めたら次の止めを
  無視する上限があります。
- transcript の file は読みません。Claude Code の docs によると、transcript は非同期に書かれ、Stop の時点で最後の
  答えがまだ入っていないことがあるためです。`last_assistant_message` を使うのが docs の推奨です。

## hook が失敗したとき

turn を通します (exit 0)。次のどれでも、何も止めません。

- 入力が JSON でない、object でない、4 MiB を超える、UTF-8 として不正。
- `hook_event_name` が `Stop` でない。
- `last_assistant_message` が無い (この field を持たない古い Claude Code) か、文字列でない。
- 想定外の例外。

この hook は答えの言語の steering で、品質や安全の gate ではないので、hook の失敗で session を塞ぎません。
Claude Code は exit 2 以外の非 0 と timeout でも stop を進めますが、この script はそれに頼らず自分で exit 0 にします。

## env

どれも省略できます。形が外れる値は既定に戻します。

| env | 意味 | 既定 |
| --- | --- | --- |
| `AGENT_TOOLS_JA_GUARD_RATIO` | 英字が日本語の文字の何倍を超えたら逸れか (1 以上の数) | 3 |
| `AGENT_TOOLS_JA_GUARD_MIN_LATIN` | 判定の対象にする英字の最小の数 (1 以上の整数) | 25 |
| `AGENT_TOOLS_JA_GUARD_DISABLE` | 空でなければ何もしない | (無し) |

## 登録 (dotfiles)

本体は agent-tools が `~/.claude/agent-tools/scripts/personal-ja-reply-guard` に配備し、登録は dotfiles が Claude Code の
settings.json で行います ([dotfiles との境界](boundary-with-dotfiles.md))。例:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "~/.claude/agent-tools/scripts/personal-ja-reply-guard", "timeout": 10 } ] }
    ]
  }
}
```

ほかの Stop hook (`personal-changed-scope-qa` など) と並べてよいです。どれかが止めて続けた後は `stop_hook_active` が
true になるので、この hook は書き直しの後の答えを止め直しません。

## 対象にしないもの

- 途中の経過報告と thinking。thinking は書き直しの対象にならず、表示の設定にも左右されます。
- Codex。hook で同じ止め方ができるかを確かめてから、別に決めます (manifest の target は claude-code だけ)。
- user が英語で書いたときに英語で答える場合の区別。測定では英語の prompt への答えは 3 件と少ないので区別せず、英語で
  答えてほしいときは `AGENT_TOOLS_JA_GUARD_DISABLE` で止めます。

## 出典

仕組み (英字と日本語の文字の比、code などを数えない、1 turn に 1 回だけ) と閾値 (3 倍、25 字) は、
[minorun365/claude-code-japanese-guard](https://github.com/minorun365/claude-code-japanese-guard) (Apache-2.0、Python) の
README を参考にしました。code は写さず、Ruby で書き直しています。識別子の形を数えない区間に入れたのは、この repo の
答えに合わせた追加です。

## Test

`scripts/tests/ja-reply-guard-test.sh`。判定は module を require して直接、hook は ruby で起動して stdin の JSON と
exit code と stderr を確かめます。1 MiB 前後の長い非一致の入力は子 process で判定し、15 秒を過ぎたら止めて失敗に
します (二次の時間に戻る退行を捕まえる)。

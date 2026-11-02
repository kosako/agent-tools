# 参照元の pin の検査 (personal-upstream-pin-check)

参照元のある asset (第三者の文書を無改変で写した vendor や、日本語に直した翻案) の参照元が、pin の後に変わったかを
決まった規則で見て、所見を `personal-repo-audit` と同じ形 (`findings.schema.json`) の JSON で出す script です (#623)。
実体は `shared/scripts/personal-upstream-pin-check.rb` で、配備先は `<tool home>/agent-tools/scripts/personal-upstream-pin-check`。

AI を使わず、何も書きません。参照元の本文も読みません (本文は第三者の文章なので、読むのは取り込むかを判断するとき
だけにする)。見るのは、GitHub の API が返す tree の blob の hash だけです。

## 一覧 (`.github/upstream-pins.json`)

今の directory の git repo の HEAD の commit にある `.github/upstream-pins.json` を読みます。作業ツリーの未 commit の
変更は読みません。一覧が無ければ、所見なしで exit 0 です。

```json
{
  "schema_version": 1,
  "upstreams": [
    {
      "name": "takt-policies",
      "repo": "nrslib/takt",
      "pin": "<40 桁の commit の hash>",
      "notice": "shared/skills/personal-production-rail/references/policies/NOTICE.md",
      "files": {
        "builtins/ja/facets/policies/coding.md": "<pin のときの blob の hash (40 桁)>"
      }
    }
  ]
}
```

- `name` は英小文字・数字・`-` (64 字まで)、一覧の中で重ならない。所見の fingerprint (`.github/upstream-pins.json#upstream-<name>`) に使う。
- `repo` は `owner/name`。`pin` は参照元の commit の hash (40 桁の小文字)。
- `notice` は、取り込みの記録 (出典・license・pin) を持つ repo 相対の path。所見の場所に出す。
- `files` は、写しや翻案の元にした参照元の file の path から、pin のときの blob の hash への対応。vendor で include を
  展開した写しなら、include の先の file も並べる。path の segment は英数字と `. _ -` だけで、空・`.`・`..` は不可。
- key の重なり、知らない key、形の外れた値は、どれも run 全体の失敗 (exit 2) にする。上限は参照元 32 件、参照元
  ごとの file 64 個、一覧 64 KiB。一覧は通常の file に限る (symlink は不可)。

blob の hash は、参照元の tree から取ります (例: `gh api repos/<owner>/<name>/git/trees/<pin>?recursive=1` の該当 path の
`sha`)。無改変の写しなら、手元の file の git の blob の hash とも一致します。

## 検査

参照元ごとに、GitHub の API (`gh api`。GET だけ、shell を通さず、env の `GH_REPO` は渡さない) を 3 回呼びます。

1. `repos/<repo>` で default branch を読む (英数字と `. _ -` の名前だけ。外れれば確かめられない)。
2. `repos/<repo>/git/ref/heads/<branch>` で先頭の commit を読む。
3. `repos/<repo>/git/trees/<commit>?recursive=1` で tree を読む。途中で切れた tree (`truncated`) は確かめられない。

一覧の file ごとに、tree の blob の hash を比べます。変わった file か無くなった file (tree に blob として無い) があれば、
その参照元を 1 件の所見 (`dependency` / `debt` / `low`、判断が要る) にします。API の呼び出しは 1 回の実行で 100 回・
120 秒までで、超えた gh は process group ごと止めます。repo を選ぶ git の環境変数 (`GIT_DIR` など) を継承していれば
止めます。

## exit と出力

- 0: 所見なし (一覧が無いときを含む)。
- 1: 所見あり。
- 2: usage、repo を選ぶ git の環境変数の継承、repo や HEAD を解決できない、一覧の形が外れる、確かめられない参照元が
  ある。確かめられない参照元があっても、残りの参照元は確かめて出す (理由は `scope.not_seen`)。run 全体の失敗では
  stdout に何も出さず、stderr に 1 行。

出力に載せるのは、一覧に書かれた (形を確かめた) 名前・repo・path・NOTICE の path と、API の応答の commit の hash
(形を確かめたもの) と決まった文言だけです。

## pin を上げるとき

参照元の更新を取り込む (または、確かめて取り込まないと決める) ときは、写しと NOTICE と一緒に、一覧の `pin` と
`files` の blob の hash を新しい commit のものにします。scripts/tests/upstream-pin-check-test.sh は、一覧の形と、各
`notice` の file に `pin` が書かれていることを CI で確かめます。

## 運用

- sweep (`personal-maintenance-sweep`) が、HEAD に一覧がある repo の run ごとにかけます。AI を使わない `upstream` の
  単位として、この script の出力をその単位の結果にします (sweep の `SKILL.md` 手順 3)。所見は決まった規則の比較で、
  根拠が GitHub の API にしか無いので、反証にかけずに triage・重複の照合・起票へ進めます。script が無い・run 全体が
  失敗したときは、sweep を止めずに「参照元を確かめられない」と報告します。人が repo で直接かけてもかまいません。
- fingerprint は参照元ごとに固定 (`.github/upstream-pins.json#upstream-<name>`) です。取り込まないと決めたときも、
  Issue を not planned で閉じずに、一覧の pin と blob の hash を確かめた commit に進めてから閉じます (not planned で
  閉じると、sweep の重複の照合が同じ fingerprint を却下として扱い、次の更新も起票されなくなるため)。

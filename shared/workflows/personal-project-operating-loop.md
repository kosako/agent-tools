# personal-project-operating-loop

個人 project を AI agent と進めるときの基本 workflow です。

この workflow は public-safe な運用ルールだけを扱います。private Notion URL、local
path、secret、credential、client/work material は含めません。

## 目的

- 設計、計画、アイデア、作業ログを Notion に集約する。
- 実作業を GitHub Issue と PR で追跡する。
- public repository には公開可能な policy、仕様、運用ルールだけを残す。
- agent が毎回同じ進め方を再現できるようにする。

## 基本 loop

1. Notion で背景、目的、判断材料、未決事項を整理する。
2. 作業単位が具体化したら GitHub Issue を作る。
3. Issue ごとに branch を切る。
4. 変更は小さく保ち、関連する docs / assets / scripts だけを触る。
5. commit 前に public safety check を行う。
6. PR を作り、対応する Issue に紐づける。
7. PR の結果や新しい判断は Notion に反映する。

## 置き場所の判断

| 内容 | 置き場所 |
| --- | --- |
| 設計メモ | Notion |
| 計画 | Notion |
| アイデア | Notion |
| 作業ログ | Notion |
| 方針の背景 | Notion |
| 実装 task | GitHub Issue |
| docs 更新 task | GitHub Issue |
| code / docs / asset の変更 | PR |
| public に共有してよい policy | repository docs |
| 再利用可能な agent workflow | `shared/workflows/personal-*` |

## Public safety check

commit / PR 前に、少なくとも以下を確認します。

- private Notion URL が tracked files に入っていない。
- local machine path が tracked files に入っていない。
- secret-like string が tracked files に入っていない。
- generated artifacts が意図せず tracked files に入っていない。
- work / client / customer / third-party confidential material が入っていない。

## PR の完了条件

- 対応する Issue がある。
- PR body に summary と checks がある。
- `Closes #...` などで Issue と紐づいている。
- public safety check が通っている。
- Notion 側に残すべき project-level な判断や作業ログが更新されている。

## 判断に迷ったとき

- 公開してよいか迷う内容は repository に入れない。
- 実装すべきか迷う内容は、先に Notion で検討する。
- 作業単位が曖昧な内容は、GitHub Issue に切る前に Notion で scope を詰める。
- 変更が複数の目的を含み始めたら、Issue / PR を分ける。

# CONTEXT.md の書式

## 構造

```md
# {コンテキスト名}

{このコンテキストが何で、なぜ存在するかを 1〜2 文で。}

## 用語

**Order(注文)**:
{その語を 1〜2 文で説明}
_避ける_: Purchase, transaction

**Invoice(請求書)**:
納品後に顧客へ送る支払い要求。
_避ける_: Bill, payment request

**Customer(顧客)**:
注文を行う個人または組織。
_避ける_: Client, buyer, account
```

## ルール

- **断定的に。** 同じ概念に複数の語があるなら、最良の 1 つを選び、残りを `_避ける_` に列挙する。
- **定義は短く。** 最大 1〜2 文。それが「何であるか」を定義し、「何をするか」は書かない。
- **このプロジェクト固有の語だけ。** 一般的なプログラミング概念(タイムアウト、エラー型、ユーティリティ等)は、多用していても載せない。追加前に「これはこのコンテキスト固有の概念か、一般概念か」を自問し、前者だけ載せる。
- **自然なまとまりが出たら小見出しでグループ化。** 単一の領域に収まるなら平坦なリストでよい。

## 単一 / 複数コンテキスト

**単一コンテキスト(多くの repo)**: root に `CONTEXT.md` 1 つ。

**複数コンテキスト**: root の `CONTEXT-MAP.md` が各コンテキストの所在と相互関係を列挙する:

```md
# Context Map

## Contexts

- [Ordering](./src/ordering/CONTEXT.md) — 顧客注文の受付と追跡
- [Billing](./src/billing/CONTEXT.md) — 請求書生成と支払い処理

## Relationships

- **Ordering → Fulfillment**: Ordering が `OrderPlaced` を emit、Fulfillment が consume してピッキング開始
- **Ordering ↔ Billing**: `CustomerId` と `Money` の型を共有
```

判定:

- `CONTEXT-MAP.md` があれば読んでコンテキストを特定する
- root の `CONTEXT.md` だけなら単一コンテキスト
- どちらも無ければ、最初の用語が固まったときに root `CONTEXT.md` を遅延作成する

複数あるときは、今の話題がどのコンテキストかを推測する。不明なら聞く。

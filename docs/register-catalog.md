# Register / Catalog

register は、shared assets を検証し、tool への反映を許可してよい状態を
catalog に記録する step です。

この document は設計です。`register.sh` の実装は含めません。

## 目的

- build / sync / status が「どの asset を扱ってよいか」を catalog で判断できるようにする。
- 自動 check の結果と human review の関係を機械可読にする。
- tracked manifest を自動書き換えしない。

## Catalog の形式と置き場所

- 形式は JSON。status contract と同じく機械可読を優先する。
- 置き場所は `generated/catalog.json`。`generated/` 配下なので Git では ignore され、
  いつでも再生成できる。
- catalog は commit しない。tracked source は manifest だけが source of truth。

```json
{
  "catalog_version": 1,
  "assets": [
    {
      "name": "personal-example",
      "kind": "workflow",
      "visibility": "public",
      "targets": ["codex", "claude-code"],
      "source": {
        "path": "shared/workflows/personal-example.md",
        "format": "markdown"
      },
      "checks": {
        "manifest_validation": "pass",
        "prompt_injection_static": "pass"
      },
      "registration": "registered"
    }
  ]
}
```

### `registration`

| value | 意味 |
| --- | --- |
| `registered` | build / sync の対象にしてよい。 |
| `human_review_required` | medium finding があり、human review が未解決。build / sync の対象外。 |

## Register の意味論

- 単位は repository 全体。register の実行は catalog を丸ごと再生成する。
- register = manifest validation + static injection check + catalog 書き込み。
- catalog 書き込みが唯一の副作用で、書き込み先は `generated/` のみ。

gate は build と同じ判定に揃える:

- manifest validation error が 1 件でもあれば register は fail し、catalog を更新しない。
- high risk finding があれば register は fail し、catalog を更新しない。
- medium risk finding は asset 単位で解決する (次節)。

## Medium finding と human review の解決

medium finding は「human review 必須」を意味する。register は finding の path を
asset の source path に対応づけ、manifest の `review.human_review` と突き合わせる。

- `review.human_review: approved` → その asset は `registered`。
- それ以外 (`pending` / 欠落) → その asset は `human_review_required`。
- `review.human_review: rejected` の asset は、finding の有無によらず register fail
  とする (reject 済み asset が shared/ に残っている状態は矛盾なので、修正か削除を促す)。

## 宣言 risk の enforce

manifest が宣言する `risk` (prompt_injection / privacy) も schema の rules どおり
enforce する。static finding と宣言 risk の厳しい方が勝つ。

- いずれかが `high` → register fail。catalog を更新しない。
- いずれかが `medium` / `unknown` → human review 必須として扱う
  (`approved` → `registered`、それ以外 → `human_review_required`)。
- 両方 `low` → finding がなければ `registered`。

## Check 結果の書き戻し方針

**manifest には書き戻さない。check 結果は catalog (別 report) に出す。**

理由:

- tracked files を script が自動変更すると、PR ごとに機械的な diff churn が生まれる。
- sidecar manifest は「人間が宣言する metadata」、catalog は「機械が計測した結果」
  という分離を保つ。
- check 結果は manifest より頻繁に変わる。再生成可能な値は `generated/` に置く。

これに伴い、manifest の `review` fields の役割を再定義する:

- `human_review`: 人間が宣言する。register が medium finding の解決に参照する
  唯一の input。
- `static_check` / `llm_review`: informational。自動 check の真実は catalog 側。
  v2 schema で削除を検討する。

## Status / doctor / dotfiles への露出

- catalog は repository 内部の中間生成物。dotfiles は catalog を直接読まない。
- `status.sh` には register summary を追加する (contract_version 2 に bump):
  `"register": {"catalog_present": true, "registered": 1, "human_review_required": 0}`。
- `doctor.sh` は catalog の存在と鮮度 (manifest より新しいか) を check する。
- build / sync は将来、catalog の `registration: registered` を前提条件にできる
  (v1 では build が直接 gate を実行しており、挙動は等価)。

## 実装状態

- `scripts/register.sh`: 実装済み (catalog 生成、human_review 突き合わせ)。
  exit code は 0 (全 registered) / 3 (human_review_required あり) / 1 (gate fail)。
- status contract v2 (register summary): 実装済み。
- doctor での catalog 鮮度 check: 実装済み。

## 後続実装

- build / sync の前提条件を catalog の `registration: registered` に切り替えるか
  の判断 (v1 では build が直接 gate を実行しており、挙動は等価)。

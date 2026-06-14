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

catalog は **target-artifact 単位** (catalog_version 2) です。1 つの asset が複数 target を
持つ場合、target ごとに entry を 1 つずつ出します。各 entry は `target` と
`artifact_kind` を持ち、sync はこれを見て配置先を分岐します。

```json
{
  "catalog_version": 2,
  "assets": [
    {
      "name": "personal-example",
      "target": "claude-code",
      "artifact_kind": "skill",
      "kind": "workflow",
      "visibility": "public",
      "source": {
        "path": "shared/workflows/personal-example.md",
        "format": "markdown"
      },
      "build_id": "sha256:0123456789ab",
      "checks": {
        "manifest_validation": "pass",
        "prompt_injection_static": "pass"
      },
      "registration": "registered"
    }
  ]
}
```

### `build_id`

source content の決定的 hash (build の marker と同じ計算)。doctor が catalog の
鮮度判定に使う。mtime には依存しない。

### `registration`

registration は target-artifact 単位で決まります。

| value | 意味 |
| --- | --- |
| `registered` | sync が配置してよい。 |
| `human_review_required` | medium があり human review が未解決。sync は配置しない。 |
| `unsupported` | その target では artifact を build できない (artifact_kind 非対応 / instruction が directory format など)。sync は配置しない。 |

### ビルド可能性の証明 (registered != buildable を防ぐ)

register は各 target-artifact について artifact_kind を解決し、build できるかを
確認してから registration を決めます (実 build はしません。support matrix /
source format / output path の確認のみ)。build できない target-artifact は
`unsupported` とし、`registered` にしません。これにより「catalog 上は registered
なのに build できない」サイレント断裂を防ぎます。artifact_kind 解決と buildable
判定は `scripts/lib/artifact_targets.rb` に集約し、build / register / check-manifests が
共有します。

## Gate は build / register / sync で一貫させる

安全判定の source of truth は **致命 gate** (`scripts/lib/gate.rb`)。build と register が
同じ判定を共有するので、同じ asset に対して両者の合否は必ず一致する。

致命 gate (どれか 1 つでも該当すれば fail):

- manifest validation error。
- static injection high finding。
- 宣言 risk (prompt_injection / privacy) が `high`。
- `review.human_review: rejected`。

致命 gate を通った後の medium の扱いは段階で異なる:

- **build**: medium では止めない。artifact を `generated/` に生成する (中間物)。
- **register**: medium を `human_review` と突き合わせ、catalog に
  `registered` / `human_review_required` を記録する (次節)。
- **sync**: catalog を読み、`registration: registered` の artifact だけ配置する。
  `human_review_required` / catalog 不在の artifact は配置せず、理由つきで skip する。

これにより「build は生成するが、human review 未解決のものは sync が止める」という
一貫した流れになる。

## Register の意味論

- 単位は repository 全体。register の実行は catalog を丸ごと再生成する。
- register = 致命 gate + medium 突き合わせ + catalog 書き込み。
- catalog 書き込みが唯一の副作用で、書き込み先は `generated/` のみ。

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
- `doctor.sh` は catalog の存在と鮮度 (build_id 比較) を check する。
- sync は catalog の `registration: registered` の artifact だけを配置する。

## 実装状態

- 致命 gate (`scripts/lib/gate.rb`): build と register が共有。
- `scripts/register.sh`: catalog 生成、human_review 突き合わせ。
  exit code は 0 (全 registered) / 3 (human_review_required あり) / 1 (gate fail)。
- `scripts/sync.sh`: catalog を尊重し registered のみ配置。
- status contract v2 (register summary) / doctor の鮮度 check: 実装済み。
- asset discovery/load は `scripts/lib/assets.rb` に集約。

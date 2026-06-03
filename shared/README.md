# Shared Assets

この directory には、複数の agent tools に適用できる source-of-truth assets を置きます。

register / sync 対象になりうる asset names は、すべて `personal-` で始めます。

`workflows/` には、agent が再利用できる進め方や運用 loop も置きます。

asset metadata は sidecar manifest で管理します。
schema は [Asset Manifest Schema](../docs/asset-manifest-schema.md) を参照してください。

single-file asset の例:

```text
shared/workflows/personal-example.md
shared/workflows/personal-example.asset.yml
```

directory asset の例:

```text
shared/skills/personal-example/
  asset.yml
  SKILL.md
```

# Shared Assets

この directory には、複数の agent tools に適用できる source-of-truth assets を置きます。

register / sync 対象になりうる asset names は、すべて `personal-` で始めます。

`workflows/` には、agent が再利用できる進め方や運用 loop も置きます。

将来の実装で推奨する asset metadata:

- `name`
- `kind`
- `audience`
- `visibility`
- `risk`
- `targets`

最初の scaffold phase では、まだ strict schema は定義しません。
registration scripts を実装する前に、follow-up issue で machine-readable manifest を導入します。

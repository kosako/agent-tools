# dotfiles との境界

`dotfiles` と `agent-tools` は、別 repository / 別 project tracking として扱います。

## dotfiles が持つ責務

- AI execution environment policy。
- capability declarations。
- directory conventions。
- local machine setup の safety gates。
- optional companion repositories が存在するかどうかの report-only checks。

## agent-tools が持つ責務

- reusable personal skills。
- prompt libraries。
- workflow definitions。
- agent definitions。
- instruction templates。
- tool-specific generated artifacts。
- registered assets 向け prompt injection review policy。

## どちらの repository も持たないもの

- tokens。
- API keys。
- credentials。
- private endpoints。
- client data。
- work data。
- runtime session state。

これらは secret store または local private config に置くものです。
この repository の scope には含めません。

## 連携 rule

`dotfiles` は `agent-tools` を自動 clone / pull / build / sync しません。

`dotfiles` がこの repository の存在を知る必要がある場合でも、許可するのは expected path に
`agent-tools` が存在するかを知らせる report-only checks までです。

`dotfiles` が report-only で読める status の形式は
[Status / Manifest Contract](status-manifest-contract.md) で定義します。

## expected path(配置先の正本)

`agent-tools` の配置先(clone 先)の正本はここで定義します。`dotfiles` 側はこれを
**参照するだけ**で、独自に別パスを正としません。

- **既定の expected path**: `~/src/agent/agent-tools`
- **根拠**: `dotfiles` の directory convention(`~/src/agent/<repo>`)と、`dotfiles` doctor の
  既定期待パス(`AGENT_TOOLS` env が未設定のときに見る場所)に一致させるため。
- **override**: 別の場所に置く場合は `AGENT_TOOLS` env で実際のパスを指定する。`dotfiles` の
  report-only check / doctor はこの env を尊重する。

`agent-tools` 自体はどのパスに clone しても動作します(script は自分の位置からの相対で動く)。
この expected path は「`dotfiles` 連携(presence / health の report-only check)を成立させる
ための合意パス」であり、配置の強制ではありません。

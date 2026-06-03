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

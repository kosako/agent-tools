# personal-repo-audit — security の類型 (SECURITY-CLASSES)

security の観点で、どこを探すかの手がかりにする類型の一覧です。対象に model や agent が関わるとき (prompt を組む、
model の出力で操作する、MCP、subagent への委譲、持続する memory) は「AI と agent」を、依存の解決・CI・配布・
更新・plugin があるときは「supply chain と release」を読みます。どちらも無い対象では読みません。

類型は候補を探す場所であって、当てはまれば所見になるわけではありません。所見にする条件と深刻度は
[REPORT-FORMAT.md](REPORT-FORMAT.md) の「security の所見」が正本です。

出典: [cloudflare/security-audit-skill](https://github.com/cloudflare/security-audit-skill) (MIT、commit
`c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`) の `AI-AND-LLM.md` と `SUPPLY-CHAIN-AND-RELEASE.md` から、個人の規模の
repo に要る類型を選び、日本語で言い換えたものです。所見にする条件と深刻度 (REPORT-FORMAT.md) は、同じ commit の
`SKILL.md` の Core principles と `HUNTING.md` の Candidate gate から借りました。本文と validator は取り込んでいません
(#567 / #613)。copyright と permission notice は [NOTICE.md](NOTICE.md)、参照元の更新の検査は repo の
`.github/upstream-pins.json` (`security-audit-skill`) です。

## AI と agent

追う流れは「untrusted な内容 → model や memory → 権限・操作・出口」です。model の出力、memory、tool の説明、MCP の
応答、委譲先の結果は、どれも untrusted な入力として扱います。

- **間接の injection**: 第三者が書ける内容 (Issue や PR の本文とコメント、取得した page、file、tool の応答) が、別の
  主体の context に入り、その主体の権限の操作が開く。書ける人、取り込む範囲、それを読む session、開く権限を分けて
  見る。所見になるのは決定的な検査の欠落で、説得的な文面そのものではない。
- **出どころの取り違え**: untrusted な文字列が、system の指示・前の turn・tool の結果・方針・memory の記録を装える
  (文字列の連結、役割の欄を呼び出し側が決められる、往復で出どころの印が落ちる)。装ったことで信頼の判断が変わるかを
  確かめる。
- **持続する memory の汚染**: 第三者の内容や model の要約が、後の別の task や権限のある session を左右する記録に
  書かれる。書く側と、後で読んで判断する側の両方を示す。user が自分で残し、自分の依頼にだけ使う memory は境界を
  越えない。
- **tool の引数から危険な出口へ**: model が作った引数が、shell・file の path・URL の取得・権限のある API に、
  handler の側の検証なしで届く。schema は形を絞るだけで、権限や安全な path を保証しない。
- **代理の権限の過剰**: agent が広い credential で動き、tool の側で「依頼した主体がその resource にその操作をして
  よいか」を確かめ直さない。共有の credential でも、主体ごとに範囲を絞っていれば欠陥ではない。
- **承認と操作の対応づけ**: 人が承認した操作と、実際に実行する操作 (tool の名前、引数、対象、主体、後の turn、
  再試行と再開) が同じだと保証されない。第三者の内容が、依頼も承認もされていない操作を被害者の権限で起こすのも
  この類型。
- **止まらない委譲の loop**: 1 回の依頼から、上限・取り消し・冪等の仕組みなしに、費用・送信・変更が繰り返される。
- **委譲先への権限の引き継ぎ**: subagent や MCP に渡す task が、要るより広い session・credential・memory・
  capability を受け取る。戻ってきた結果を untrusted として扱っているかも見る。
- **MCP の server や tool の取り違え**: 認証した接続ではなく、名前・ID・URI で呼び出しや結果を振り分け、別の
  server が同じ名前を名乗れる。
- **MCP の metadata を方針として信じる**: tool の説明・schema・prompt は model を導くが、権限を与えない。食い
  違ったときにも効く allowlist と handler の権限の確認があるかを見る。
- **出力の描画**: model の出力が、HTML・Markdown・template・URL・command の出口に、その出口が要る escape なしで
  届く。
- **context からの持ち出し**: 組み立てた context に credential や他人の data が入り、user が左右できる出力から
  それが出る。一般的な指示や振る舞いが見えるだけなら所見ではない。

見る順の手がかり: 実行する主体、使える権限、書ける context と memory、出力の行き先を先に並べ、副作用のある tool から
逆に辿ります。直接・queue・再試行・再開・委譲の経路を比べ、最も強い検査が「引数が確定した後、副作用の前」に
どの経路でもかかるかを見ます。

## supply chain と release

- 変わりうる依存や、既知の脆弱性のある依存は、それだけでは所見ではない。解決に誰が関われ、どの build がそれを
  使い、どの実行や配布の境界が続くかを示す。
- CI の設定は認可の code として読む。どの event で動き、誰の code が走り、どの secret と token があり、何を公開・
  変更できるか。
- artifact と同じ untrusted な場所から取った checksum は、独立した完全性の根拠にならない。信頼の起点と、検査に
  失敗したときの振る舞いを確かめる。

類型:

- **依存の出どころの取り違え**: resolver の設定で、意図しない registry・mirror・source が選ばれうる (lockfile と
  checksum の使い方、初回の install と更新の違いを見る)。
- **固定していない build の入力**: branch、tag、submodule、download する tool、version を固定していない CI の
  action、container の tag など、review なしで中身が変わる入力が build の出力に入る。書き換えられる側と、出力に入る
  経路の両方を示す (再現できることは、真正さの証明ではない)。
- **生成物の出どころ**: 生成した code、vendor した archive、binary が、source と同じ review と完全性の検査を通らずに
  配布物に入る。
- **build の範囲に入るもの**: secret、local の設定、開発用の file が、ignore の規則より広い build の範囲から配布物に
  入る。
- **権限のある workflow で untrusted な code が走る**: PR、コメント、fork、依存の更新、外部の event で、投稿者が
  制御できる code が、保護された secret や write の token と一緒に走る。trigger の種類、checkout する ref、承認の
  関門、権限の絞り込みを比べる。
- **workflow の command と式の取り違え**: 第三者が決められる branch 名・commit message・Issue の欄・artifact の名前が、
  shell の command・式・path に検証なしで入る。
- **cache と artifact の信頼の混ざり**: 信頼の低い job が置いた cache や artifact を、信頼の高い job が復元して実行・
  配布する。
- **自動化の主体の権限の過剰**: CI の job が要るより広い権限を持ち、untrusted な入力が対象を選べる。最小権限で
  ないだけなら強化の案で、所見には届く権限のある操作が要る。
- **build から配布への差し替え**: test・review・署名・公開が、同じ不変の digest ではなく、変わりうる tag や file の
  名前を指す。
- **配布と署名の方針の抜け**: 間違った workflow・repo・branch から来た release や署名を受け入れる。
- **更新と巻き戻しの取り違え**: 更新の仕組みが payload の中身だけを認証し、version・対象・巻き戻しの状態を認証
  しない。
- **plugin と拡張の権限の広がり**: 拡張が宣言より広い host の権限を得る、または install や更新の hook が真正さと
  権限の確認の前に走る。同じ user が自分で入れる plugin は境界ではない。

見る順の手がかり: 配布した digest や入れた更新から、source・生成物・credential・worker・cache・test の結果・認可の
判断へ逆に辿ります。信頼の低い event と保護された event の workflow を並べ、その間を渡る経路ごとに、不変の識別と
作り手の信頼を求めます。失敗の経路 (鍵の失効、download の失敗、署名の欠落、registry の停止) の方針も、完全性の
一部として見ます。

repo の外にある設定 (GitHub の branch protection や Actions の権限、registry、署名の service) は、有るとも無いとも
推測しません。所見がそれに依るときは未確定です (REPORT-FORMAT.md の「security の所見」)。

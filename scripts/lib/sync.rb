#!/usr/bin/env ruby
# frozen_string_literal: true

# generated/ の personal assets を local tool directories に反映する。
# Spec: docs/sync-policy.md, docs/status-manifest-contract.md
#
# - default は dry-run。書き込みには --apply が必須。
# - 対象は `personal-` で始まる generated assets のみ。
# - 更新してよいのは agent-tools management marker を持つ target のみ。
# - 同名 unmanaged target は conflict として停止する。
# - 許可 target は artifact_kind 別: skill = <tool home>/skills/personal-*、
#   instruction = connect 確立済みの所有ファイル、script = <tool home>/agent-tools/scripts/
#   personal-* (sidecar marker つき)、plugin = <opencode home>/plugins/personal-*.js (先頭行
#   marker)。それ以外の path は構成しない (docs/sync-policy.md)。
# - plan と prune が走査する tool × kind の組は ArtifactTargets::TOOL_KINDS に従う (opencode
#   home の skills/ と agent-tools/scripts/ は走査しない, #295)。
# - --prune で catalog に載らなくなった deployed asset を撤去する (marker-gated delete,
#   #154)。削除も --apply が必須で、既定は dry-run。

require "fileutils"

require_relative "yaml_marker"
require_relative "artifact_targets"
require_relative "catalog"
require_relative "instruction_marker"
require_relative "path_glob"
require_relative "plugin_marker"
require_relative "assets"
require_relative "cli"
require_relative "plan_report"

module Sync
  TOOLS = ArtifactTargets::TOOLS

  # apply で配置先を安全に入れ替えられないときの error (#431 の 3): 前回の残り (一時 dir / file、退避した旧 dir)
  # や、新版を置いた後の退避した旧 dir を消しきれない。main が `fail:` の行と exit 1 で止める (build の
  # OutputPathError と同じ伝え方)。
  class ApplyError < StandardError; end

  # code は reason (人間向け表示文言) と対になる機械可読な skip 理由。status が contract
  # の target state 判定に読む (#152: 表示文言の変更で contract を壊さないための分離)。
  Plan = Struct.new(:action, :tool, :name, :target, :reason, :kind, :gen, :code) do
    def to_s
      line = "#{action}: [#{tool}] #{target || name}"
      reason ? "#{line} (#{reason})" : line
    end
  end

  class Runner
    def initialize(root, homes)
      @root = File.expand_path(root)
      @homes = homes
      load_catalog
    end

    attr_reader :catalog_present

    # catalog の各 target-artifact を列挙し、registered のものを配置する。
    def plan
      @entries.map { |entry| plan_for_entry(entry) }
    end

    # --prune: catalog に載らなくなった deployed asset の撤去 plan を作る (#154)。
    # build --prune (generated/ の orphan 削除) の sync 版。削除は 3 条件をすべて満たす
    # ものだけ (marker-gated delete): 許可 namespace 内 (skills/personal-* /
    # agent-tools/scripts/personal-*) + agent-tools 管理 marker が tool / name と一致 +
    # catalog に同 target + name + artifact_kind の entry が無い。kind 単位で照合するのは
    # build --prune と同じ判断 (kind 変更後の stale 配置物を保護して残さない)。
    # 条件を満たさない orphan は削除せず skip で可視化する (prune は conflict でブロック
    # しない。書き込みと違い「触らない」が常に安全なため)。instruction は connect が
    # 人間ファイルと絡めて所有するため prune 対象外 (docs/sync-policy.md)。
    # 走査は TOOL_KINDS の組だけ (TOOLS × 全 kind ではない): opencode home の skills/ は OpenCode
    # が skill として読む dir で、marker が一致しても消してはいけない (#295)。
    # catalog 不在 / version 不一致 / 壊れた JSON / entry ゼロでは何も判断しない
    # (fail-closed)。@entries が空だと全 deployed が orphan に見えて全削除を plan して
    # しまうため。valid な空 catalog ({"assets": []}) は manifest ゼロの repo (間違った
    # --root 等) でも生成できるので、catalog_present だけでは足りない。
    def prune_plans
      return [] if !@catalog_present || @entries.empty?

      TOOLS.flat_map do |tool|
        ArtifactTargets::TOOL_KINDS.fetch(tool).flat_map do |kind|
          case kind
          when "skill" then prune_skills(tool)
          when "script" then prune_scripts(tool)
          when "instruction" then [] # connect が所有するため prune 対象外
          when "plugin" then prune_plugins(tool)
          else raise ArgumentError, "no prune for artifact_kind #{kind.inspect}"
          end
        end
      end
    end

    # 既知の限界 (TOCTOU): symlink / unmanaged の検査は plan 時のみで、apply は配置先を
    # 再検証しない。plan→apply 間の差し替えを突ける主体は同一ユーザー権限で任意書込できる
    # 攻撃者に限られ、その主体は再検証も同様に無効化できるため、再検証は防御にならない
    # (実装しない判断, #149)。同時実行の事故は個人ツールで前提が薄く、書き込み先が
    # marker-gated に限定されることで被害も限定される。docs/sync-policy.md の既知の限界も参照。
    def apply(plans)
      plans.each do |p|
        if p.action == "delete"
          delete_target(p)
          next
        end
        next unless %w[create update].include?(p.action)

        case p.kind
        when "instruction"
          # instruction は単一ファイル。所有先は connect が確立済み (sync は update)。
          FileUtils.mkdir_p(File.dirname(p.target))
          FileUtils.cp(p.gen, p.target)
        when "script"
          # script は単一実行ファイル + sidecar marker。本体 (実行可能) → marker の順に、それぞれ一時 file に
          # 書いて rename で入れ替える。create の途中で止まると marker の無い本体が残り、次の sync は unmanaged の
          # conflict で止まる (fail-closed, #431 の 3)。
          FileUtils.mkdir_p(File.dirname(p.target))
          replace_file(p.gen, p.target, 0o755)
          replace_file(ArtifactTargets.sidecar_marker_path(p.gen), ArtifactTargets.sidecar_marker_path(p.target))
        when "plugin"
          # plugin は先頭行に marker を持つ単一ファイル。OpenCode が import して読むので
          # 実行ビットは立てない (build と同じ 0644)。
          FileUtils.mkdir_p(File.dirname(p.target))
          FileUtils.cp(p.gen, p.target)
          File.chmod(0o644, p.target)
        else
          replace_skill_dir(p.gen, p.target)
        end
      end
    end

    private

    # apply の作業用 path (一時 dir / file = staging、退避した旧 dir = old)。配置先と同じ親 dir に置く (rename が
    # 同じ filesystem の中で済む)。`personal-` で始めないので plan / prune / status / doctor の走査 (personal-*)
    # には拾われない。pid を含めず固定の名前にして、前回の中断 (kill 等で ensure が走らなかったとき) の残りを
    # 次の run が同じ名前で見つけて消せるようにする (同時実行は前提にしない。docs/sync-policy.md の TOCTOU の項と
    # 同じ立場)。
    def work_path(target, label)
      File.join(File.dirname(target), ".agent-tools-#{label}-#{File.basename(target)}")
    end

    # skill (directory) の create / update。generated を一時 dir に copy し、旧 dir を退避先に rename で退け、
    # 一時 dir を rename で配置先に置いてから、退避した旧 dir を消す (退避 → 配置 → 削除)。配置先が無い時間は
    # 2 つの rename の間だけで、marker は一時 dir の中にあるので rename で初めて有効になる。copy の途中で
    # 止まれば旧版はそのまま。配置の rename に失敗したら ensure で退避した旧版を戻す (例外でも割り込みでも。
    # SIGKILL は対象外)。旧 dir を消し残しても新版は配置済みなので、残った写しの path を伝えて止める (rm_rf は
    # 削除の失敗を握りつぶす。build.rb と同じ検査)。例外のときも一時 dir は片付ける (#431 の 3, #469 review)。
    def replace_skill_dir(gen, target)
      FileUtils.mkdir_p(File.dirname(target))
      staging = work_path(target, "staging")
      old = work_path(target, "old")
      unless removed?(staging)
        raise ApplyError, "could not remove the leftover staging dir #{staging}; the new version was not applied"
      end
      # 前回の中断からの復旧: 配置先が無く退避した旧 dir だけがあるのは、退避の後・配置の前で止まった状態
      # (SIGKILL 等で ensure が走らなかった)。唯一の旧版なので、前回の残りとして消さずに配置先へ戻してから進める。
      File.rename(old, target) if File.exist?(old) && !File.exist?(target)
      unless removed?(old)
        raise ApplyError,
              "could not remove the leftover copy of the old version #{old}; the new version was not applied"
      end
      begin
        FileUtils.cp_r(gen, staging)
        File.rename(target, old) if File.exist?(target)
        begin
          File.rename(staging, target)
        rescue SystemCallError => e
          # 退避済みなら ensure が旧版を戻す。退避していない (create) なら配置先には何も無い。
          outcome = File.exist?(old) ? "the old version was put back" : "nothing was placed"
          raise ApplyError, "could not put the new version at #{target} (#{e.class}); #{outcome}"
        end
      ensure
        # 退避の後・配置の前で止まったら (例外・割り込み)、退避した旧版を戻して配置先を欠落させない。判断は
        # flag ではなく退避先と配置先の実在で行う (flag だと退避の rename が済んでから flag が立つまでの隙間で
        # 割り込まれたときに戻らない, #469 review 3)。何も動かす前 (cp_r の失敗など) は old が無い (冒頭で消した)
        # ので戻さない / 退避の直後なら old があり target が無いので戻す / 配置の直後なら target があるので
        # 戻さない (old は残るが、target があるので次の apply の冒頭が復旧せずに消す)。
        File.rename(old, target) if File.exist?(old) && !File.exist?(target)
        FileUtils.rm_rf(staging)
      end
      return if removed?(old)

      raise ApplyError,
            "could not remove the copy of the old version #{old}; the new version is in place, remove the copy by hand"
    end

    # 単一 file の create / update。一時 file に copy し、mode があれば付けてから rename で入れ替える。cp は
    # 新規 file の mode を source に合わせる (umask で落とす) ので、mode を渡さない sidecar marker は従来の
    # cp と同じ mode になる。一時 file の path に directory や消せない file があれば止める (rm_f は失敗を
    # 握りつぶし、cp は directory の中へ入れ子に copy して、create なら rename が配置先に directory を置く)。
    # 例外のときも一時 file は片付ける (#431 の 3, #469 review)。
    def replace_file(gen, target, mode = nil)
      staging = work_path(target, "staging")
      FileUtils.rm_f(staging)
      if File.exist?(staging)
        raise ApplyError, "could not remove the leftover staging file #{staging}; the new version was not applied"
      end
      begin
        FileUtils.cp(gen, staging)
        File.chmod(mode, staging) if mode
        File.rename(staging, target)
      ensure
        FileUtils.rm_f(staging)
      end
    end

    # rm_rf は削除の失敗 (書き込み不可の dir の中の file など) を握りつぶすので、消えたことを返り値で確かめる
    # (build.rb の旧い出力 dir の検査と同じ)。
    def removed?(path)
      FileUtils.rm_rf(path)
      !File.exist?(path)
    end

    # catalog を source of truth として読む (target-artifact 単位)。不在 / version 不一致 /
    # 壊れた JSON は catalog なし扱い (Catalog.read が fail-closed に判定)。
    def load_catalog
      result = Catalog.read(@root)
      @catalog_present = result.present?
      @entries = result.entries
    end

    # prune の削除実体。marker-gated 判定 (prune_skills / prune_scripts / prune_plugins) を
    # 通った plan だけが来る。script は本体と sidecar marker を対で消す。単一ファイルの kind
    # (script / plugin) は rm_f で、directory (skill) だけ rm_rf。
    def delete_target(plan)
      case plan.kind
      when "script"
        FileUtils.rm_f(plan.target)
        FileUtils.rm_f(ArtifactTargets.sidecar_marker_path(plan.target))
      when "plugin"
        FileUtils.rm_f(plan.target)
      else
        FileUtils.rm_rf(plan.target)
      end
    end

    # tool の catalog に載っている name (artifact_kind 単位)。registration 状態は問わない
    # (human_review_required / unsupported でも entry がある = asset は shared/ に実在する
    # ので、その deployed 物を prune が消さない。配置可否の判断は plan 側の責務)。
    def catalog_names(tool, kind)
      @entries.select { |e| e["target"] == tool && e["artifact_kind"] == kind }
              .map { |e| e["name"] }
    end

    def prune_skills(tool)
      skills_dir = File.join(@homes.fetch(tool), "skills")
      return [] unless File.directory?(skills_dir)

      known = catalog_names(tool, "skill")
      PathGlob.under(skills_dir, "personal-*").sort.map do |target|
        name = File.basename(target)
        next if known.include?(name)

        # symlink は実体の所在によらず決して触らない (plan_skill と同じ防御)。
        if File.symlink?(target) || File.symlink?(skills_dir)
          next Plan.new("skip", tool, name, target, "orphan is a symlink; left in place", "skill", nil,
                        :orphan_symlink)
        end
        marker = File.directory?(target) ? read_marker(target) : nil
        unless YamlMarker.managed?(marker, tool, name)
          next Plan.new("skip", tool, name, target, "orphan is unmanaged; left in place", "skill", nil,
                        :orphan_unmanaged)
        end
        Plan.new("delete", tool, name, target, "not in catalog", "skill", nil, :orphan)
      end.compact
    end

    def prune_scripts(tool)
      scripts_dir = File.join(@homes.fetch(tool), "agent-tools", "scripts")
      return [] unless File.directory?(scripts_dir)

      known = catalog_names(tool, "script")
      PathGlob.under(scripts_dir, "personal-*").sort.map do |target|
        # sidecar marker は本体の delete と対で消すため、単体では列挙しない。
        next if target.end_with?(ArtifactTargets::MARKER_BASENAME)

        name = File.basename(target)
        next if known.include?(name)

        # 削除経路 (本体 / sidecar / 親 dir 2 階層) のいずれかが symlink なら触らない
        # (plan_script と同じ防御)。
        if script_target_symlink?(target)
          next Plan.new("skip", tool, name, target, "orphan is a symlink; left in place", "script", nil,
                        :orphan_symlink)
        end
        marker = YamlMarker.read_file(ArtifactTargets.sidecar_marker_path(target))
        unless YamlMarker.managed?(marker, tool, name)
          next Plan.new("skip", tool, name, target, "orphan is unmanaged; left in place", "script", nil,
                        :orphan_unmanaged)
        end
        Plan.new("delete", tool, name, target, "not in catalog", "script", nil, :orphan)
      end.compact
    end

    # plugin の prune は <home>/plugins/personal-*.js だけを見る (.ts と personal- 以外の file、
    # herdr-agent-state.js 等は列挙しない)。symlink と、先頭行 marker が自分の管理 (tool + name)
    # を示さない file は skip (plan_plugin と同じ防御)。
    def prune_plugins(tool)
      plugins_dir = File.join(@homes.fetch(tool), "plugins")
      return [] unless File.directory?(plugins_dir)

      known = catalog_names(tool, "plugin")
      PathGlob.under(plugins_dir, ArtifactTargets.plugin_filename("personal-*")).sort.map do |target|
        name = File.basename(target, ".js")
        next if known.include?(name)

        if File.symlink?(target) || File.symlink?(plugins_dir)
          next Plan.new("skip", tool, name, target, "orphan is a symlink; left in place", "plugin", nil,
                        :orphan_symlink)
        end
        unless owned_plugin_marker(target, tool, name)
          next Plan.new("skip", tool, name, target, "orphan is unmanaged; left in place", "plugin", nil,
                        :orphan_unmanaged)
        end
        Plan.new("delete", tool, name, target, "not in catalog", "plugin", nil, :orphan)
      end.compact
    end

    # catalog entry (target-artifact) を plan にマップする。registered 以外は配置しない。
    def plan_for_entry(entry)
      tool = entry["target"]
      name = entry["name"]
      kind = entry["artifact_kind"]

      if entry["registration"] != "registered"
        # TOOL_KINDS に無い tool × kind (register の unsupported) は、その tool の path を構成しない。
        # 構成すると ArtifactTargets.target_path の既定 (skills/<name>) が opencode home にも組まれ、
        # status が対象外の path の存在で deployed_but_inactive を出しうる (#338 review)。
        unless ArtifactTargets.tool_supports?(tool, kind)
          return Plan.new("skip", tool, name, nil, entry["registration"], kind, nil, :unsupported)
        end
        return Plan.new("skip", tool, name, target_path(tool, name, kind), entry["registration"], kind, nil,
                        :not_registered)
      end
      # 登録判断 (risk / review / targets) は manifest に依存する。register 後に manifest が
      # 変わった entry は判断ごと stale なので、配置せず register を促す (fail-closed, #148)。
      unless Assets.manifest_fresh?(@root, entry)
        return Plan.new("skip", tool, name, target_path(tool, name, kind),
                        "manifest changed; run scripts/register.sh first", kind, nil, :manifest_stale)
      end

      case kind
      when "skill" then plan_skill(tool, name, entry["build_id"])
      when "instruction" then plan_instruction(tool, name, entry["build_id"])
      when "script" then plan_script(tool, name, entry["build_id"])
      when "plugin" then plan_plugin(tool, name, entry["build_id"])
      else
        Plan.new("skip", tool, name, nil, "unsupported artifact_kind #{kind.inspect}", kind, nil, :unsupported)
      end
    end

    # registered でない entry の skip 表示に使う target path。
    # path 解決は ArtifactTargets.target_path が単一 source (skill / instruction 共通)。
    def target_path(tool, name, kind)
      ArtifactTargets.target_path(@homes.fetch(tool), tool, name, kind)
    end

    def plan_skill(tool, name, expected_build_id)
      target = target_path(tool, name, "skill")
      gen = ArtifactTargets.generated_path(@root, tool, name, "skill")

      unless name.start_with?("personal-")
        return Plan.new("conflict", tool, name, target, "generated asset without personal- prefix", "skill", gen)
      end
      unless File.directory?(gen)
        return Plan.new("skip", tool, name, target, "run build first", "skill", gen, :build_first)
      end

      source_marker = read_marker(gen)
      unless YamlMarker.managed?(source_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "generated artifact is missing a valid marker", "skill", gen)
      end
      # generated が catalog entry と一致するか (build_id)。不一致 = register 後に build して
      # いない (stale generated)。instruction (plan_instruction) と同じく "run build first" で
      # skip し、古い generated を配置しない。
      if source_marker["build_id"] != expected_build_id
        return Plan.new("skip", tool, name, target, "run build first", "skill", gen, :build_first)
      end
      # symlink は実体の所在によらず unmanaged target として扱い、決して触らない。
      # 親 dir (<home>/skills) が symlink の場合も、rm_rf / cp_r が外へ追従しないよう
      # conflict にする (plan_instruction と同じ防御)。
      if File.symlink?(target) || File.symlink?(File.dirname(target))
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "skill", gen)
      end
      unless File.exist?(target)
        return Plan.new("create", tool, name, target, nil, "skill", gen)
      end

      target_marker = File.directory?(target) ? read_marker(target) : nil
      unless YamlMarker.managed?(target_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "skill", gen)
      end

      if target_marker["build_id"] == source_marker["build_id"]
        Plan.new("skip", tool, name, target, "up-to-date", "skill", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "skill", gen)
      end
    end

    # instruction は connect が所有を確立する。sync は create に落ちず、未接続なら
    # connect を促す。catalog の name / build_id を真実として generated と所有先の
    # marker を照合し、update / skip を決める。
    def plan_instruction(tool, name, expected_build_id)
      gen = ArtifactTargets.generated_path(@root, tool, name, "instruction")
      unless gen
        return Plan.new("skip", tool, name, nil, "instruction unsupported for #{tool}", "instruction", nil,
                        :unsupported)
      end
      target = target_path(tool, name, "instruction")

      # instruction は plan_skill / plan_script のような personal- prefix 検査をしない:
      # あの検査は配置先 namespace (<home>/skills/personal-* 等、name から導出される path) を
      # 守るためのもので、instruction の配置先は name 非依存の固定ファイル (CLAUDE.md /
      # AGENTS.md)。name 自体の prefix は check-manifests が manifest 段階で enforce する。

      # generated が catalog entry と一致するか (target + name + build_id)。
      # 一致しなければ build が未実行 / 古い (判定は InstructionMarker.matches? に集約, #152)。
      unless File.file?(gen) &&
             InstructionMarker.matches?(File.read(gen), target: tool, name: name, build_id: expected_build_id)
        return Plan.new("skip", tool, name, target, "run build first", "instruction", gen, :build_first)
      end
      # 所有先とその親 dir が symlink なら決して触らない (connect と同じ保証)。
      if File.symlink?(target) || File.symlink?(File.dirname(target))
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "instruction", gen)
      end
      # 未接続なら connect を促す。sync は create しない。
      # 所有先が無い場合に加え、空ファイル (空白のみ) も未接続として扱う
      # (codex の AGENTS.md は空で存在しうる。空の claim は connect の責務)。
      # 人間所有ファイルの非 UTF-8 バイトは scrub してから判定する (crash させない, #149)。
      if !File.exist?(target) || (File.file?(target) && File.read(target).scrub("�").strip.empty?)
        return Plan.new("skip", tool, name, target, "run connect first", "instruction", gen, :connect_first)
      end

      target_marker = File.file?(target) ? InstructionMarker.parse(File.read(target)) : nil
      # 所有先が同じ asset の agent-tools 管理か (target + name)。別 asset の残存ファイルを
      # managed と誤認しない。
      unless target_marker && target_marker["target"] == tool && target_marker["name"] == name
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "instruction", gen)
      end

      if target_marker["build_id"] == expected_build_id
        Plan.new("skip", tool, name, target, "up-to-date", "instruction", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "instruction", gen)
      end
    end

    # script は単一実行ファイル + sidecar marker。skill (plan_skill) と同じ marker ベースの
    # 所有 / stale / symlink 防御を、単一ファイルと 2 階層の配置先
    # (<home>/agent-tools/scripts/<name>) にあわせて適用する。instruction と違い人間ファイルを
    # 介さないため connect は不要で、未配置なら直接 create する。
    def plan_script(tool, name, expected_build_id)
      target = target_path(tool, name, "script")
      gen = ArtifactTargets.generated_path(@root, tool, name, "script")

      unless name.start_with?("personal-")
        return Plan.new("conflict", tool, name, target, "generated asset without personal- prefix", "script", gen)
      end
      unless File.file?(gen)
        return Plan.new("skip", tool, name, target, "run build first", "script", gen, :build_first)
      end

      source_marker = YamlMarker.read_file(ArtifactTargets.sidecar_marker_path(gen))
      unless YamlMarker.managed?(source_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "generated artifact is missing a valid marker", "script", gen)
      end
      # generated が catalog entry と一致するか (build_id)。不一致 = register 後に build して
      # いない (stale generated)。plan_skill / plan_instruction と同じく run build first で skip。
      if source_marker["build_id"] != expected_build_id
        return Plan.new("skip", tool, name, target, "run build first", "script", gen, :build_first)
      end
      # 配置先本体・sidecar marker・その親 (agent-tools/scripts)・さらにその親
      # (agent-tools) のいずれかが symlink なら、cp / chmod が home の外へ追従しうるため
      # 触らない (plan_skill の親 dir 防御を、sync が書き込む 2 ファイル + 2 階層に広げる)。
      if script_target_symlink?(target)
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "script", gen)
      end
      unless File.exist?(target)
        # 本体が未配置でも sidecar marker が unmanaged な平ファイルとして残っていることがある。
        # create で apply が無条件に sidecar を上書きしないよう、本体だけでなく sidecar の
        # 管理状態も確認する (本体ありの update 経路と対称, #179 H-06)。symlink な sidecar は
        # script_target_symlink? が上で conflict 済み。
        sidecar = ArtifactTargets.sidecar_marker_path(target)
        if File.exist?(sidecar) && !YamlMarker.managed?(YamlMarker.read_file(sidecar), tool, name)
          return Plan.new("conflict", tool, name, target, "existing sidecar marker is unmanaged", "script", gen)
        end
        return Plan.new("create", tool, name, target, nil, "script", gen)
      end

      target_marker = File.file?(target) ? YamlMarker.read_file(ArtifactTargets.sidecar_marker_path(target)) : nil
      unless YamlMarker.managed?(target_marker, tool, name)
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "script", gen)
      end

      if target_marker["build_id"] == source_marker["build_id"]
        Plan.new("skip", tool, name, target, "up-to-date", "script", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "script", gen)
      end
    end

    # plugin は先頭行 marker を持つ単一ファイル (<opencode home>/plugins/<name>.js)。skill / script
    # と同じ所有 / stale / symlink 防御を、marker が本体の中にある形にあわせて適用する。
    # 判定の順は docs/sync-policy.md の OpenCode target の項と同じ。
    def plan_plugin(tool, name, expected_build_id)
      target = target_path(tool, name, "plugin")
      gen = ArtifactTargets.generated_path(@root, tool, name, "plugin")

      unless name.start_with?("personal-")
        return Plan.new("conflict", tool, name, target, "generated asset without personal- prefix", "plugin", gen)
      end
      # generated が catalog entry と一致するか (target + name + build_id)。marker が無い /
      # 壊れている / build_id が古い、はすべて「build が未実行 / 古い」(plan_instruction と同じ)。
      unless File.file?(gen) &&
             PluginMarker.matches?(File.binread(gen), target: tool, name: name, build_id: expected_build_id)
        return Plan.new("skip", tool, name, target, "run build first", "plugin", gen, :build_first)
      end
      # 本体か親 dir (<home>/plugins) が symlink なら、cp / chmod が home の外へ追従しうるため
      # 触らない (plan_skill / plan_instruction と同じ防御)。
      if File.symlink?(target) || File.symlink?(File.dirname(target))
        return Plan.new("conflict", tool, name, target, "existing target is a symlink", "plugin", gen)
      end
      unless File.exist?(target)
        return Plan.new("create", tool, name, target, nil, "plugin", gen)
      end
      # directory 等は marker を持ち得ず、cp が失敗するか中身を壊すので unmanaged より前に止める。
      unless File.file?(target)
        return Plan.new("conflict", tool, name, target, "existing target is not a regular file", "plugin", gen)
      end

      target_marker = owned_plugin_marker(target, tool, name)
      unless target_marker
        return Plan.new("conflict", tool, name, target, "existing target is unmanaged", "plugin", gen)
      end

      if target_marker["build_id"] == expected_build_id
        Plan.new("skip", tool, name, target, "up-to-date", "plugin", gen, :up_to_date)
      else
        Plan.new("update", tool, name, target, nil, "plugin", gen)
      end
    end

    # 配置済み plugin (regular file) の先頭行 marker が、この tool の同名 asset の agent-tools 管理を
    # 示すならその marker、示さなければ nil。plan_plugin の unmanaged 判定と prune の marker-gated
    # delete が同じ条件を共有する。
    def owned_plugin_marker(target, tool, name)
      return nil unless File.file?(target)

      PluginMarker.owned(File.binread(target), target: tool, name: name)
    end

    # sync が script で書き込む経路 (本体 / sidecar marker / 配置先 dir 2 階層) のいずれかが
    # symlink かを判定する。1 つでも symlink なら cp / chmod が home の外へ追従しうる。
    def script_target_symlink?(target)
      scripts_dir = File.dirname(target)          # <home>/agent-tools/scripts
      agent_tools_dir = File.dirname(scripts_dir) # <home>/agent-tools
      File.symlink?(target) ||
        File.symlink?(ArtifactTargets.sidecar_marker_path(target)) ||
        File.symlink?(scripts_dir) ||
        File.symlink?(agent_tools_dir)
    end

    # directory artifact (skill) の dir 直下 marker を読む。
    def read_marker(dir)
      YamlMarker.read_file(File.join(dir, ArtifactTargets::MARKER_BASENAME))
    end

  end

  def self.main(argv)
    opts = Cli.parse(argv, usage: USAGE,
                     bool_flags: %w[--apply --prune --quiet],
                     value_flags: %w[--root --codex-home --claude-home --opencode-home])
    return 0 if opts == :help

    root = opts["--root"] || Cli::DEFAULT_ROOT
    apply = opts.key?("--apply")
    prune = opts.key?("--prune")
    quiet = opts.key?("--quiet")
    homes = ArtifactTargets.default_homes
    homes["codex"] = File.expand_path(opts["--codex-home"]) if opts["--codex-home"]
    homes["claude-code"] = File.expand_path(opts["--claude-home"]) if opts["--claude-home"]
    homes["opencode"] = File.expand_path(opts["--opencode-home"]) if opts["--opencode-home"]

    runner = Runner.new(root, homes)
    plans = runner.plan
    plans += runner.prune_plans if prune

    if plans.empty?
      msg = runner.catalog_present ? "nothing to sync (run scripts/build.sh first)" : "no catalog; run scripts/register.sh first"
      puts "ok: #{msg}" unless quiet
      return 0
    end

    PlanReport.finish(plans, runner, apply: apply, quiet: quiet,
                      change_actions: %w[create update delete])
  rescue ApplyError => e
    # 配置先を安全に入れ替えられないときは、それ以上書かずに理由を出して止める (#431 の 3)。
    # 表示は他の行と同じく tilde 表記 (PlanReport と同じ正規化)。
    warn "fail: #{e.message.sub(Dir.home, '~')}"
    1
  end

  USAGE = "usage: sync.sh [--root DIR] [--apply] [--prune] [--codex-home DIR] [--claude-home DIR] " \
          "[--opencode-home DIR] [--quiet]"
end

exit Sync.main(ARGV) if $PROGRAM_NAME == __FILE__

# frozen_string_literal: true

# OpenCode plugin probe (#295 PR 0) の隔離。tmp に HOME / XDG / DB / git config / project を作り、
# 子 process には allowlist の env だけを渡す。Spec: docs/opencode-plugin-probe.md の「隔離」。
#
# HOME ごと tmp に向ける理由: HOME が実物のままだと、tmp の config dir に AGENTS.md が無いので
# OpenCode は実物の ~/.claude/CLAUDE.md と ~/.claude/skills を読んで system message に載せ、
# mock の記録や実 provider に届く。git も実物の ~/.gitconfig の hooksPath を踏む。
# (test は HOME を差し替えない方針だが、probe は実物を見せないことが目的なので逆になる。)

require "digest"
require "fileutils"
require "json"
require "open3"

module ProbeOpencode
  class Error < StandardError; end

  module Isolation
    PROVIDER_ID = "probe"
    MODELS = %w[claude-probe gpt-5-probe].freeze
    PRIMARY_PLUGIN = "probe-global-a"
    # global の plugins dir に 2 つ (a は 1 行目が plugin の marker 形の comment)、project に 1 つ。
    GLOBAL_PLUGINS = %w[probe-global-a probe-global-b].freeze
    PROJECT_PLUGIN = "probe-project"
    # M18: OpenCode 内部の git が踏むかを見る hook。
    GIT_HOOKS = %w[pre-commit commit-msg post-commit post-checkout reference-transaction post-index-change].freeze
    # harness が値を決める env。--pass-env で上書きさせない。
    MANAGED_ENV = %w[PATH HOME TMPDIR ZDOTDIR SHELL TERM LANG OPENCODE_DB GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
                     OPENCODE_DISABLE_AUTOUPDATE OPENCODE_DISABLE_MODELS_FETCH].freeze
    MANAGED_PREFIXES = %w[XDG_ GIT_ OPENCODE_CONFIG PROBE_].freeze
    MARKER_NAMES_RE = "OPENCODE|AGENT|OPENCODE_PID|OPENCODE_SESSION_ID|AGENT_TOOLS_PROBE_MARK|CLAUDECODE|CODEX_THREAD_ID|CODEX_SANDBOX"

    Layout = Struct.new(:base, :home, :config, :data, :cache, :state, :tmp, :db, :gitconfig, :hooks_dir,
                        :git_hooks_out, :project, keyword_init: true) do
      def opencode_config_dir
        File.join(config, "opencode")
      end

      def global_plugins_dir
        File.join(opencode_config_dir, "plugins")
      end

      def project_plugins_dir
        File.join(project, ".opencode", "plugins")
      end

      def log_dir
        File.join(data, "opencode", "log")
      end
    end

    def self.layout(base)
      Layout.new(
        base: base,
        home: File.join(base, "home"),
        config: File.join(base, "xdg", "config"),
        data: File.join(base, "xdg", "data"),
        cache: File.join(base, "xdg", "cache"),
        state: File.join(base, "xdg", "state"),
        tmp: File.join(base, "tmp"),
        db: File.join(base, "opencode.db"),
        gitconfig: File.join(base, "gitconfig"),
        hooks_dir: File.join(base, "git-hooks"),
        git_hooks_out: File.join(base, "git-hooks.jsonl"),
        project: File.join(base, "project"),
      )
    end

    def self.valid_pass_env!(name)
      raise Error, "--pass-env: invalid env name: #{name}" unless name.match?(/\A[A-Z_][A-Z0-9_]*\z/)
      managed = MANAGED_ENV.include?(name) || MANAGED_PREFIXES.any? { |p| name.start_with?(p) }
      raise Error, "--pass-env: #{name} is managed by the probe" if managed
    end

    # 子 process に渡す env の全体。unsetenv_others: true と組にして使う (これ以外は渡らない)。
    # CLAUDECODE / CODEX_* / OPENCODE_CONFIG* / GH_TOKEN などは、ここに無いので渡らない。
    def self.child_env(layout, shell:, parent_env:, pass_env: [], extra: {})
      env = {
        "PATH" => parent_env.fetch("PATH"),
        "HOME" => layout.home,
        "XDG_CONFIG_HOME" => layout.config,
        "XDG_DATA_HOME" => layout.data,
        "XDG_CACHE_HOME" => layout.cache,
        "XDG_STATE_HOME" => layout.state,
        "TMPDIR" => layout.tmp,
        "ZDOTDIR" => layout.home,
        "OPENCODE_DB" => layout.db,
        "GIT_CONFIG_GLOBAL" => layout.gitconfig,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "SHELL" => shell,
        "TERM" => "dumb",
        "LANG" => "en_US.UTF-8",
        "OPENCODE_DISABLE_AUTOUPDATE" => "1",
        "OPENCODE_DISABLE_MODELS_FETCH" => "1",
      }
      pass_env.each do |name|
        valid_pass_env!(name)
        env[name] = parent_env[name] if parent_env.key?(name)
      end
      env.merge(extra)
    end

    # mock / serve / TUI 用の opencode.json。real は provider を持たず enabled_providers だけを絞る。
    def self.opencode_config(shell:, mock_url: nil, real_provider: nil, snapshot: false)
      cfg = {
        "enabled_providers" => [real_provider || PROVIDER_ID],
        "share" => "disabled",
        "autoupdate" => false,
        "snapshot" => snapshot,
        "lsp" => false,
        "formatter" => false,
        "shell" => shell,
        # M9: run は ask を自動で拒否する。`touch probe-ask*` だけを ask にする。
        "permission" => { "bash" => { "*" => "allow", "touch probe-ask*" => "ask" }, "edit" => "allow" },
      }
      return cfg if real_provider

      models = MODELS.map { |m| [m, { "name" => m, "tool_call" => true, "limit" => { "context" => 200_000, "output" => 8192 } }] }.to_h
      cfg.merge(
        "provider" => {
          PROVIDER_ID => {
            "npm" => "@ai-sdk/openai-compatible",
            "name" => PROVIDER_ID,
            "options" => { "baseURL" => mock_url, "apiKey" => "probe-not-a-key" },
            "models" => models,
          },
        },
      )
    end

    # plugin の marker 行 (PR 1 で配る plugin の 1 行目と同じ形)。M2 で「この行が付いた file が
    # 1 回だけ読まれるか」を見る。build_id は probe の source の hash (配布の build_id ではない)。
    def self.marker_line(name, source)
      "/* agent-tools:managed v=1 repo=agent-tools name=#{name} target=opencode artifact_kind=plugin " \
        "source=shared/plugins/#{name}.js build_id=sha256:#{Digest::SHA256.hexdigest(source)} */\n"
    end

    def self.prepare(layout, parent_env:, shell:)
      [layout.home, layout.config, layout.data, layout.cache, layout.state, layout.tmp, layout.hooks_dir,
       layout.project, layout.global_plugins_dir, layout.project_plugins_dir].each { |d| FileUtils.mkdir_p(d) }
      File.write(layout.gitconfig, <<~GITCONFIG)
        [user]
        \tname = probe
        \temail = probe@example.invalid
        [core]
        \thooksPath = #{layout.hooks_dir}
        [init]
        \tdefaultBranch = main
      GITCONFIG
      GIT_HOOKS.each { |h| write_git_hook(layout, h) }
      env = child_env(layout, shell: shell, parent_env: parent_env)
      _, err, status = Open3.capture3(env, "git", "init", "-q", layout.project, unsetenv_others: true)
      raise Error, "git init failed: #{err.strip}" unless status.success?
    end

    # hook は値を書かず、目印の名前と run の label (PROBE_RUN。git が OpenCode の env を継いだときだけ
    # 入る) だけを書く。記録先は生成時に single quote の literal で埋める。
    def self.write_git_hook(layout, name)
      path = File.join(layout.hooks_dir, name)
      out = "'" + layout.git_hooks_out.gsub("'") { "'\\''" } + "'"
      File.write(path, <<~SH)
        #!/bin/sh
        m=$(env | cut -d= -f1 | grep -xE '#{MARKER_NAMES_RE}' | sort | tr '\\n' ' ')
        printf '{"hook":"%s","run":"%s","markers":"%s"}\\n' "$(basename "$0")" "${PROBE_RUN:-}" "$m" >> #{out}
        exit 0
      SH
      File.chmod(0o755, path)
    end

    def self.install_plugins(layout, plugin_source)
      src = File.read(plugin_source)
      GLOBAL_PLUGINS.each do |name|
        body = name == PRIMARY_PLUGIN ? marker_line(name, src) + src : src
        File.write(File.join(layout.global_plugins_dir, "#{name}.js"), body)
      end
      File.write(File.join(layout.project_plugins_dir, "#{PROJECT_PLUGIN}.js"), src)
    end

    def self.write_config(layout, cfg)
      File.write(File.join(layout.opencode_config_dir, "opencode.json"), JSON.pretty_generate(cfg) + "\n")
    end

    # M15 の canary (tmp の HOME の ~/.claude)。
    def self.place_claude_canaries(layout, canaries)
      dir = File.join(layout.home, ".claude")
      skill_dir = File.join(dir, "skills", "probe-canary")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(dir, "CLAUDE.md"), "# probe\n\n#{canaries.fetch('claude_rules')}\n")
      File.write(File.join(skill_dir, "SKILL.md"),
                 "---\nname: probe-canary\ndescription: #{canaries.fetch('claude_skill')}\n---\n\nprobe canary skill\n")
    end

    def self.remove_claude_canaries(layout)
      FileUtils.rm_rf(File.join(layout.home, ".claude"))
    end

    # 実物の OpenCode の global config dir と DB。stage の前後で mtime を比べる。
    def self.real_state_paths(parent_env)
      home = parent_env.fetch("HOME")
      cfg = parent_env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : parent_env["XDG_CONFIG_HOME"]
      data = parent_env["XDG_DATA_HOME"].to_s.empty? ? File.join(home, ".local", "share") : parent_env["XDG_DATA_HOME"]
      [File.join(cfg, "opencode"), File.join(cfg, "opencode", "opencode.json"),
       File.join(data, "opencode", "opencode.db"), File.join(data, "opencode", "opencode.db-wal")]
    end

    def self.mtimes(paths)
      paths.map { |p| [p, File.exist?(p) ? File.mtime(p).to_f : nil] }.to_h
    end
  end
end

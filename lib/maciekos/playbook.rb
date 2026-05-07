# lib/maciekos/playbook.rb
require "json"
require "time"
require "yaml"

module Maciekos
  # Concatenates hand-written playbook markdown into a single bundle for
  # one-shot LLM (or human) consumption. Pure file IO + flag-driven shaping —
  # no LLM call, no docs generation. See docs/playbook_command_spec.md.
  class Playbook
    DEFAULT_DIR  = File.expand_path("~/Documents/maciekOS/notes/playbooks")
    SEPARATOR    = "\n\n---\n\n"
    README_NAME  = "README"
    # Required-reading preamble: auto-bundled after README so every leaf
    # inherits the same cross-cutting QA-process context. Hidden from --list
    # so it doesn't appear as a pickable leaf. See notes/playbooks/README.md.
    CONTEXT_NAME = "process_context"

    class UnknownPlaybook < StandardError
      attr_reader :requested, :available
      def initialize(name, available)
        @requested = name
        @available = available
        super("unknown playbook: #{name}")
      end
    end

    class UnknownScenario < StandardError
      attr_reader :requested, :available
      def initialize(name, available)
        @requested = name
        @available = available
        super("unknown scenario: #{name}")
      end
    end

    class IncludeNotReadable < StandardError
      attr_reader :path
      def initialize(path)
        @path = path
        super("--include path not readable: #{path}")
      end
    end

    def initialize(dir: nil)
      @dir = dir || ENV["AIKIQ_PLAYBOOKS_DIR"] || DEFAULT_DIR
    end

    attr_reader :dir

    def list_names
      Dir.glob(File.join(@dir, "*.md"))
         .map { |f| File.basename(f, ".md") }
         .reject { |n| n == README_NAME || n == CONTEXT_NAME }
         .sort
    end

    def info(name)
      path    = leaf_path(name)
      content = File.read(path)
      h1_line = content.lines.find { |l| l.strip.start_with?("# ") }
      h1      = h1_line ? h1_line.strip.sub(/^#\s+/, "") : name

      first_paragraph = content
        .split(/\n\s*\n/)
        .map(&:strip)
        .reject(&:empty?)
        .find { |para| !para.start_with?("# ") }

      <<~INFO.strip
        # #{h1}

        Path: #{path}
        Last modified: #{File.mtime(path).utc.iso8601}
        Size: #{File.size(path)} bytes

        #{first_paragraph || '(no description paragraph)'}
      INFO
    end

    def list_scenarios
      load_scenarios.keys.sort
    end

    def scenario(name)
      scenarios = load_scenarios
      raise UnknownScenario.new(name, scenarios.keys) unless scenarios.key?(name)
      sc = scenarios[name]
      {
        names: Array(sc["names"]),
        flags: Array(sc["flags"]).map(&:to_s)
      }
    end

    # Build the assembled bundle. Returns a String (the rendered output).
    def bundle(names:, include_readme: true, include_rules: true,
               include_context: true, includes: [], with_toc: false,
               no_header: false, format: "markdown", max_bytes: nil,
               max_tokens: nil, command_string: nil)
      sections = collect_sections(names, include_readme, include_rules, include_context, includes)

      if format == "json"
        return render_json(sections, command_string, include_rules)
      end

      pieces = []
      pieces << header_comment(sections, command_string) unless no_header
      pieces << build_toc(sections)                       if with_toc
      pieces.concat(sections.map { |s| s[:content] })

      result = pieces.join(SEPARATOR)
      result = result.gsub(SEPARATOR, "\n\n") if format == "plain"

      apply_truncation(result, max_bytes, max_tokens)
    end

    private

    def readme_path
      File.join(@dir, "README.md")
    end

    def leaf_path(name)
      path = File.join(@dir, "#{name}.md")
      raise UnknownPlaybook.new(name, list_names) unless File.exist?(path)
      path
    end

    def collect_sections(names, include_readme, include_rules, include_context, includes)
      sections = []

      if include_readme && File.exist?(readme_path)
        readme = File.read(readme_path)
        readme = strip_rules_section(readme) unless include_rules
        sections << { name: README_NAME, path: readme_path, content: readme }
      end

      ctx_path = File.join(@dir, "#{CONTEXT_NAME}.md")
      if include_context && File.exist?(ctx_path)
        sections << { name: CONTEXT_NAME, path: ctx_path, content: File.read(ctx_path) }
      end

      names.each do |n|
        next if include_context && n == CONTEXT_NAME # already added as preamble
        path = leaf_path(n)
        sections << { name: n, path: path, content: File.read(path) }
      end

      includes.each do |inc|
        expanded = File.expand_path(inc)
        raise IncludeNotReadable.new(inc) unless File.readable?(expanded)
        sections << { name: File.basename(expanded), path: expanded, content: File.read(expanded) }
      end

      sections
    end

    # Drops the "Cross-cutting rules" section from the README, from the
    # heading to the next sibling H2 (or end of file).
    def strip_rules_section(readme)
      out      = []
      skipping = false
      readme.each_line do |line|
        if line.lstrip.start_with?("## ")
          skipping = !!(line =~ /\A##\s+[Cc]ross[-\s][Cc]utting\s+[Rr]ules/)
          next if skipping
        end
        out << line unless skipping
      end
      out.join
    end

    def header_comment(sections, command_string)
      file_names = sections.map { |s| s[:name] }
      <<~HEADER.chomp
        <!-- aikiq playbook bundle
             cmd: #{command_string || "aikiq playbook #{file_names.reject { |n| n == README_NAME }.join(' ')}".strip}
             generated: #{Time.now.utc.iso8601}
             files: #{file_names.join(', ')}
        -->
      HEADER
    end

    def build_toc(sections)
      lines = ["## Contents", ""]
      sections.each do |s|
        h1_line = s[:content].lines.find { |l| l.strip.start_with?("# ") }
        title = h1_line ? h1_line.strip.sub(/^#\s+/, "") : s[:name]
        lines << "- #{title}"
      end
      lines.join("\n")
    end

    def render_json(sections, command_string, include_rules)
      payload = {
        "command"                => command_string || "aikiq playbook",
        "generated_at"           => Time.now.utc.iso8601,
        "sections"               => sections.map { |s| { "name" => s[:name], "path" => s[:path], "content" => s[:content] } },
        "rules_section_included" => include_rules
      }
      JSON.pretty_generate(payload)
    end

    def apply_truncation(result, max_bytes, max_tokens)
      if max_bytes && result.bytesize > max_bytes
        return result.byteslice(0, max_bytes).to_s + "\n\n<!-- truncated at #{max_bytes} bytes -->\n"
      end

      if max_tokens
        # Rough deterministic estimate: 4 chars ≈ 1 token. No tokenizer dep.
        max_chars = max_tokens * 4
        if result.length > max_chars
          return result[0, max_chars] + "\n\n<!-- truncated at ~#{max_tokens} tokens (#{max_chars} chars) -->\n"
        end
      end

      result
    end

    def load_scenarios
      path = File.join(@dir, "scenarios.yaml")
      return {} unless File.exist?(path)
      YAML.safe_load(File.read(path)) || {}
    rescue Psych::SyntaxError
      {}
    end
  end
end

# lib/maciekos/cli.rb
require "thor"
require "yaml"
require "securerandom"
require "digest"
require "time"
require 'tty-markdown'
require 'tty-box'
require 'pastel'

require_relative "openrouter_adapter"
require_relative "workflow_engine"
require_relative "evaluator"
require_relative "file_processor"
require_relative "examples_loader"
require_relative "schemas_loader"
require_relative "renderers/generic_renderer"
require_relative "output_processor"
require_relative "scenario_scope_extractor"

module Maciekos
  class CLI < Thor
    package_name "maciekos"

    def self.exit_on_failure?
      true
    end

    default_task :run_workflow

    desc "run_workflow WORKFLOW [PROMPT]", "Run a workflow with optional prompt and files"
    long_desc <<-LONGDESC
    Execute an AI workflow with flexible input options:

      Examples:
      aikiq code-review "Analyze this"
    aikiq code-review --file diff.patch
    aikiq code-review --file diff1.patch --file diff2.patch
    aikiq code-review "Explain" --file diff.patch --file logs.txt
    aikiq code-review --dir ./src --pattern "*.rb"
    aikiq code-review --model anthropic/claude-3.5-sonnet

    Multi-file support via preprocessed --files argument.
      LONGDESC
    option :files, type: :string, desc: "Comma-separated file paths (auto-populated)"
    option :dirs, type: :string, desc: "Comma-separated directory paths (auto-populated)"
    option :pattern, type: :string, default: "*", desc: "File pattern for --dir (e.g., '*.rb,*.js')"
    option :model, type: :string, desc: "Override model (e.g., anthropic/claude-3.5-sonnet)"
    option :max_file_size, type: :numeric, default: 1_048_576, desc: "Max file size in bytes (default: 1MB)"
    option :dry_run, type: :boolean, default: false
    option :compress, type: :boolean, default: false, desc: "Compress large file contents"
    option :session, type: :string, desc: "Session identifier"
    option :label,   type: :string, desc: "Optional artifact label"
    option :output, type: :array, desc: "Use latest output from specified workflow(s) in session (e.g., --output=gherkin_write --output=testmo_import)"
    option :scope, type: :boolean, default: false, desc: "Extract scenario scope context (auto-enabled for gherkin_write)"
    def run_workflow(workflow_id = nil, prompt = nil, session_id = nil, label = nil)
      raise Thor::Error, "workflow_id required. Usage: aikiq <workflow-id> [PROMPT] [OPTIONS]" if workflow_id.nil?

      # Initialize file processor
      processor = FileProcessor.new(
        max_size: options[:max_file_size],
        compress: options[:compress]
      )

      file_paths = []

      # Parse comma-separated files (populated by bin/maciekos preprocessor)
      if options[:files] && !options[:files].empty?
        file_paths.concat(options[:files].split(',').map(&:strip))
      end

      # Parse comma-separated dirs
      if options[:dirs] && !options[:dirs].empty?
        patterns = options[:pattern].split(",").map(&:strip)
        options[:dirs].split(',').map(&:strip).each do |dir_path|
          raise Thor::Error, "Directory not found: #{dir_path}" unless Dir.exist?(dir_path)
            processor.collect_from_directory(dir_path, patterns).each do |path|
              file_paths << path
            end
        end
      end

      if options[:output] && !options[:output].empty?
        unless options[:session]
          raise Thor::Error, "--output requires --session to be specified"
        end

        options[:output].each do |output_workflow|
          latest_file = resolve_latest_output(options[:session], output_workflow)
          if latest_file
            file_paths << latest_file
            puts "Resolved output file: #{latest_file}"
          else
            raise Thor::Error, "No output file found for workflow '#{output_workflow}' in session '#{options[:session]}'"
          end
        end
      end

      # Automatic scenario scope extraction for gherkin_write
      scope_context = nil  # Initialize here to ensure scope visibility
      # Auto-enable for gherkin_write, or when --scope is explicitly passed
      if workflow_id == "gherkin_write" || options[:scope] && workflow_id != "gherkin_write"
        begin
          scope_data = ScenarioScopeExtractor.extract(
            session_id: options[:session],
            project_root: Maciekos::PROJECT_ROOT
          )

          if scope_data && !scope_data.empty?
            extractor_json = scope_data.to_json

            # Store for later addition to parts
            scope_context = "\n## Scenario Scope Context\n\n```json\n#{extractor_json}\n```\n"

            STDERR.puts "[Scope Extractor] Loaded scope for ticket: #{scope_data['ticket_key']}"
              STDERR.puts "[Scope Extractor] Priority: #{scope_data['scenario_priority']} | Alignment: #{scope_data['alignment_status']}"

              active_gaps = scope_data['gaps_detected']&.select { |_, v| v }&.keys
            STDERR.puts "[Scope Extractor] Active gaps: #{active_gaps.join(', ')}" if active_gaps&.any?

              STDERR.puts "[Scope Extractor] Code risk: #{scope_data['code_risk_detected']} | External API: #{scope_data['external_api_involved']}"
          else
            STDERR.puts "[Scope Extractor] Warning: No scope data extracted"
          end
        rescue => e
          STDERR.puts "[Scope Extractor] Warning: #{e.message}"
        end
      end

      # Remove duplicates and validate all files exist (ONLY ONCE)
      file_paths.uniq!
      file_paths.each do |path|
        raise Thor::Error, "File not found: #{path}" unless File.exist?(path)
      end

      parts = []

      parts << scope_context if scope_context

      # Read stdin if piped (Unix-style)
      unless STDIN.tty?
        stdin_content = STDIN.read
        parts << stdin_content unless stdin_content.strip.empty?
      end

      # Inline prompt
      parts << prompt.strip if prompt && !prompt.strip.empty?

      # Process files
      unless file_paths.empty?
        file_contents = processor.process_files(file_paths)
        parts << file_contents
      end

      raise Thor::Error, "No input provided. Supply PROMPT, --file, or --dir." if parts.empty?

      prompt_text = parts.join("\n\n")

      # Load and prepare workflow
      engine = WorkflowEngine.new
      wf = engine.load_workflow(workflow_id)

      # Allow workflow to specify model override
      model_override = options[:model] || wf.dig("vars", "default_model")

      session_id = options[:session]
      prepared_prompt, system_message = engine.prepare_prompt(wf, session_id, prompt_text)

      if options[:dry_run]
        puts "=" * 80
        puts "DRY RUN: #{workflow_id}"
          puts "=" * 80
        puts "Model: #{model_override || 'workflow default'}"
          puts "Files: #{file_paths.length}"
          file_paths.each_with_index do |f, i|
            puts "  #{i+1}. #{f}"
          end
          puts "Prompt length: #{prepared_prompt.length} chars"
            puts "\nFirst 1500 chars:"
          puts prepared_prompt[0..1500]
          puts "\n" + "=" * 80
          return
      end

      # Generate run ID
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      hash = Digest::SHA256.hexdigest(prepared_prompt)[0, 8]
      run_id = "#{ts}-#{hash}"

        adapter_opts = { system_message: system_message }

      if model_override
        adapter_opts[:models_override] = [model_override]
      end

      # Execute workflow
      adapter = OpenRouterAdapter.new
      model_prefs = wf.dig("vars", "model_preferences") || []
      responses = adapter.call_with_fanout(model_prefs, prepared_prompt, adapter_opts)

      # Evaluate and select
      evaluator = Evaluator.new(wf)
      result = evaluator.validate_and_select(responses, run_id)

      # Save artifact
      artifact_path = engine.write_artifact(
        workflow_id, 
        run_id, 
        result, 
        session: options[:session],
        label: options[:label]
      )

      display_results(result, artifact_path, file_paths, workflow_id)
      end

    desc "list", "List available workflows"
    def list
      engine = WorkflowEngine.new
      workflows = engine.list_workflows

      puts "\nAvailable workflows:\n\n"
      workflows.each do |wf_id|
        begin
          wf = engine.load_workflow(wf_id)
          desc = wf["description"] || "(no description)"
          model = wf.dig("vars", "default_model") || "default"
          puts "  #{wf_id.ljust(20)} - #{desc} [#{model}]"
        rescue => e
          puts "  #{wf_id.ljust(20)} - (error loading: #{e.message})"
        end
      end
      puts "\n"
    end

    desc "models WORKFLOW", "Show available models for a workflow"
    def models(workflow_id)
      engine = WorkflowEngine.new
      wf = engine.load_workflow(workflow_id)

      puts "\nModels for workflow: #{workflow_id}\n\n"

        default = wf.dig("vars", "default_model")
      puts "Default: #{default}\n\n" if default

        prefs = wf.dig("vars", "model_preferences")
      if prefs
        puts "Model preferences:"
        prefs.each_with_index do |pref, idx|
          puts "  #{idx + 1}. Tier: #{pref['tier']}, Fanout: #{pref.fetch('fanout', true)}"
        end
      end
      puts "\n"
    end

    desc "print WORKFLOW", "Display the latest output file for a workflow"
    option :session, type: :string, desc: "Session identifier", required: true
    def print(workflow_id)
      session_path = File.join(Maciekos::PROJECT_ROOT, "sessions", options[:session], "outputs")

      unless Dir.exist?(session_path)
        raise Thor::Error, "Session directory not found: #{session_path}"
      end

      # Find files matching: <seq>_<workflow_id>.ext or <seq>_<workflow_id>_suffix.ext
      # Use strict regex to avoid matching 'jira_code_review' when looking for 'code_review'
      all_files = Dir.glob(File.join(session_path, "*"))
      files = all_files.select do |filepath|
        basename = File.basename(filepath)
        basename =~ /^\d+_#{Regexp.escape(workflow_id)}(\.|_)/
      end

      if files.empty?
        raise Thor::Error, "No output files found for workflow '#{workflow_id}' in session '#{options[:session]}'"
      end

      # Sort by the numeric prefix to get the latest
      latest_file = files.sort_by do |filename|
        File.basename(filename).split('_').first.to_i
      end.last

      content = File.read(latest_file)

      # Handle display based on file extension
      case workflow_id
      when /testmo/
        puts content
      else
        puts TTY::Markdown.parse(content, indent: 2, color: :never)
      end

      puts "\nDisplaying: #{File.basename(latest_file)}"
      end

    desc "activity", "Show recent file activity from sessions"
    option :since, type: :string, desc: "Starting date (last_week, YYYY-MM-DD)", default: "last_week"
    option :by_day, type: :boolean, desc: "Group by day", default: true
    option :by_session, type: :boolean, desc: "Group by session", default: false  # Changed default to false
    def activity
      start_date = parse_since_option(options[:since])
      files = collect_recent_files(start_date)

      if files.empty?
        puts "No activity found since #{format_date(start_date)}"
        return
      end

      display_activity(files, options[:by_day], options[:by_session])
    end

    desc "sessions", "List all available sessions"
    option :limit, type: :numeric, desc: "Limit to N most recent sessions"
    def sessions
      sessions_path = File.join(Maciekos::PROJECT_ROOT, "sessions")
      return puts "No sessions found" unless Dir.exist?(sessions_path)

      # Collect session info with their last modification time
      sessions = Dir.glob(File.join(sessions_path, "*")).map do |path|
        {
          name: File.basename(path),
          mtime: File.mtime(path),
          files_count: Dir.glob(File.join(path, "outputs", "*.*")).count
        }
      end

      # Sort by most recent
      sessions = sessions.sort_by { |s| s[:mtime] }.reverse

      # Apply limit if specified
      sessions = sessions.take(options[:limit]) if options[:limit]

      sessions.each do |session|
        date = session[:mtime].strftime("%d %b %H:%M")
        puts "#{session[:name].ljust(30)} #{date} (#{session[:files_count]} files)"
      end
    end

    desc "install_completions", "Install shell completions for aikiq"
    def install_completions
      completion_file = File.join(Maciekos::PROJECT_ROOT, "completions", "aikiq.bash")

      # Create completions directory if it doesn't exist
      FileUtils.mkdir_p(File.dirname(completion_file))

      # Write completion script
      File.write(completion_file, completion_script)
      FileUtils.chmod(0755, completion_file)

      shell = ENV['SHELL']
      rc_file = case File.basename(shell)
                when 'zsh'
                  '~/.zshrc'
                else
                  '~/.bashrc'
                end

      puts "Completion script installed to: #{completion_file}"
        puts "\nAdd to your #{rc_file}:"
      puts "  source #{completion_file}"
    end

    private

    # this needs to be fixed so completion for session AND for Directory work at the same time
    def completion_script
      <<~SCRIPT
      #!/usr/bin/env bash

      _aikiq_complete() {
        local cur prev
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"

        case $prev in
          --session)
          # Complete session names
          local sessions_dir="#{Maciekos::PROJECT_ROOT}/sessions"
          if [ -d "$sessions_dir" ]; then
            local sessions=$(ls -1 "$sessions_dir")
            COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
            fi
            return 0
            ;;
            --since)
            # Complete date keywords
            local dates="last_week last_tuesday last_thursday"
            COMPREPLY=($(compgen -W "$dates" -- "$cur"))
            return 0
            ;;
            aikiq)
            # Complete command names
            local commands="activity print sessions models list"
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            return 0
            ;;
            *)
            # Handle options
            if [[ "$cur" == -* ]]; then
              local opts="--session --since --by_day --by_session --help"
              COMPREPLY=($(compgen -W "$opts" -- "$cur"))
              return 0
              fi
              ;;
              esac
      }

      if [ -n "$ZSH_VERSION" ]; then
        autoload -U +X compinit && compinit
        autoload -U +X bashcompinit && bashcompinit
        fi

        complete -F _aikiq_complete aikiq
        SCRIPT
      end

      def parse_since_option(since)
        case since.downcase
        when 'last_week'
          Date.today - 7
        when 'last_tuesday'
          date = Date.today
          date -= 1 until date.tuesday?
          date
        when 'last_thursday'
          date = Date.today
          date -= 1 until date.thursday?
          date
        else
          begin
            Date.parse(since)
          rescue ArgumentError
            raise Thor::Error, "Invalid date format. Use YYYY-MM-DD or keywords: last_week, last_tuesday, last_thursday"
          end
        end
      end

      def collect_recent_files(start_date)
        sessions_path = File.join(Maciekos::PROJECT_ROOT, "sessions")
        return [] unless Dir.exist?(sessions_path)

        files = []
        Dir.glob(File.join(sessions_path, "*", "outputs", "*.*")) do |file|
          stat = File.stat(file)
          next if stat.mtime < start_date.to_time

          session = file.split('/')[-3] # Get session name from path
          files << {
            path: file,
            name: File.basename(file),
            session: session,
            mtime: stat.mtime
          }
        end

        files.sort_by { |f| f[:mtime] }.reverse
      end

      def display_activity(files, by_day = true, by_session = false)
        if by_day && !by_session
          files_by_day = files.group_by { |f| f[:mtime].to_date }

          files_by_day.each do |date, day_files|
            puts "#{date.strftime('%A %d %b')}"

            day_files.group_by { |f| f[:session] }.each do |session, session_files|
              puts "  #{session}:"
              session_files.sort_by { |f| f[:mtime] }.reverse.each do |file|
                time = file[:mtime].strftime("%H:%M")
                puts "    #{time}  #{file[:name]}"
              end
              puts
            end
          end
        elsif by_session
          files_by_session = files.group_by { |f| f[:session] }

          files_by_session.each do |session, session_files|
            puts "#{session}:"

            session_files.group_by { |f| f[:mtime].to_date }.each do |date, day_files|
              puts "  #{date.strftime('%A %d %b')}"
              day_files.sort_by { |f| f[:mtime] }.reverse.each do |file|
                time = file[:mtime].strftime("%H:%M")
                puts "    #{time}  #{file[:name]}"
              end
            end
            puts
          end
        else
          files.each do |file|
            date = file[:mtime].strftime("%d %b %H:%M")
            puts "#{date}  #{file[:session]}/#{file[:name]}"
          end
        end
      end

      def format_date(date)
        date.strftime("%Y-%m-%d")
      end

      def display_results(result, artifact_path, file_paths, workflow_id)
        output_path = process_output(result, workflow_id)
        pastel = Pastel.new

        puts "\n"
        puts pastel.dim("Artifact: ") + artifact_path
        puts pastel.dim("Files processed: ") + file_paths.length.to_s
        if file_paths.any?
          puts "\n" + pastel.dim("Files:")
          file_paths.each_with_index { |f, i| puts "  #{i+1}. #{File.basename(f)}" }
        end
        puts "\n" + "─" * 120 + "\n\n"

        selected = result[:selected] || result["selected"]

        if selected
          model = selected[:model] || selected["model"] || "unknown"

          content = selected.dig(:raw, "message", "content") ||
            selected.dig("raw", "message", "content")

          if content
            if content.strip.start_with?('{') && content.strip.end_with?('}')
              begin
                content = JSON.parse(content)
              rescue JSON::ParserError
              end
            end

            rendered = Renderers::OutputFormatter.format(
              workflow: File.basename(artifact_path, ".*"),
              content: content
            )

            puts TTY::Markdown.parse(
              rendered, 
              indent: 2,
              color: :never
            )
            puts "\n" + "Model: #{model}"
          else
            puts pastel.red("\nNo content found in response")
          end
        else
          evaluated = result[:evaluated] || result["evaluated"]
          if evaluated && evaluated.any?
            top = evaluated.max_by { |r| (r[:score] || r["score"]).to_f }
            content = top.dig(:raw, "message", "content") ||
              top.dig("raw", "message", "content")

            if content
              if content.strip.start_with?('{') && content.strip.end_with?('}')
                begin
                  content = JSON.parse(content)
                rescue JSON::ParserError
                end
              end

              rendered = Renderers::OutputFormatter.format(
                workflow: File.basename(artifact_path, ".*"),
                content: content
              )

              puts TTY::Markdown.parse(
                rendered, 
                indent: 2,
                color: :never
              )
              puts "\n" + pastel.yellow("Model: #{top[:model] || top["model"]} (score: #{top[:score] || top["score"]})")
            end
          else
            puts pastel.red("\nNo usable response. Check artifact for details.")
          end
        end

        # Print output path in the last line, ensuring it's not nil
        if output_path
          puts "\nOutput written to: #{output_path}"
        end
      end

      # Extract clean text from various response formats
      def extract_clean_text(response)
        # Try to get the raw response first
        raw = response[:raw] || response["raw"]

        if raw.is_a?(Hash)
          content = raw.dig("message", "content")
          return content if content && !content.empty?
        end

        text = response[:text] || response["text"]

        # If text is a stringified hash (Ruby inspect format), extract content from it
        if text.is_a?(String) && text.start_with?("{") && text.include?("=>")
          # This is Ruby's inspect output: {"key"=>"value", ...}
          if match = text.match(/"content"=>"((?:[^"\\]|\\.)*)"/m)
            content = match[1]
            content = content.gsub('\"', '"').gsub('\\n', "\n").gsub('\\t', "\t").gsub('\\\\', '\\')
            return content
          end
        end

        if text.is_a?(String)
          return text
        end

        if output_path
          puts "\nOutput written to: #{output_path}"
        end
        "(No text content found)"
      end

      def process_output(result, workflow_id)
        return nil unless result && (result[:selected] || result["selected"])

        processor = OutputProcessor.new(
          workflow_id: workflow_id,  # Just use the passed workflow_id directly
          session_id: options[:session]
        )

        processor.process(result)
      end

      def resolve_latest_output(session_id, workflow_id)
        session_path = File.join(Maciekos::PROJECT_ROOT, "sessions", session_id, "outputs")
        return nil unless Dir.exist?(session_path)

        patterns = [
          File.join(session_path, "*_#{workflow_id}.md"),
          File.join(session_path, "*_#{workflow_id}.csv")
        ]

        files = patterns.flat_map { |p| Dir.glob(p) }.sort_by do |filename|
          prefix = File.basename(filename).split('_').first
          prefix.to_i
        end

        files.last
      end
  end
end

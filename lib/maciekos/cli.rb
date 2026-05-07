# lib/maciekos/cli.rb
require "thor"
require "yaml"
require "json"
require "securerandom"
require "digest"
require "time"
require "set"
require "open3"
require "tty-markdown"
require "tty-box"
require "pastel"

require_relative "openrouter_adapter"
require_relative "workflow_engine"
require_relative "evaluator"
require_relative "file_processor"
require_relative "examples_loader"
require_relative "schemas_loader"
require_relative "renderers/generic_renderer"
require_relative "output_processor"
require_relative "scenario_scope_extractor"
require_relative "session_metadata"
require_relative "session_backfill"
require_relative "jira_snapshot"
require_relative "sentry_client"
require_relative "playbook"
require_relative "jira_client"
require_relative "checks/base"
require_relative "checks/schema"

module Maciekos
  class CLI < Thor
    package_name "aikiq"

    # Thor renders "Usage:" lines using File.basename($PROGRAM_NAME).
    # The binary is bin/maciekos but the user installs it as `aikiq`
    # via a wrapper, so help would otherwise read "Usage: maciekos
    # snapshot" instead of "Usage: aikiq snapshot". Override to match
    # the public name.
    def self.basename
      "aikiq"
    end

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
    option :label, type: :string, desc: "Optional artifact label"
    option :output, type: :array, desc: "Use latest output from specified workflow(s) in session (e.g., --output=gherkin_write --output=testmo_import)"
    option :scope, type: :boolean, default: false, desc: "Extract scenario scope context (auto-enabled for gherkin_write)"
    option :force_snapshot, type: :boolean, default: false, desc: "Bypass requires_jira_change gate; run even if jira view is unchanged"
    option :force_gate, type: :array, desc: "Bypass listed gate(s) — e.g. --force-gate schema. Repeatable / comma-separated."
    option :force_reason, type: :string, desc: "Reason recorded with --force-gate bypass (audit log)"
    def run_workflow(workflow_id = nil, prompt = nil, session_id = nil, label = nil)
      raise Thor::Error, "workflow_id required. Usage: aikiq <workflow-id> [PROMPT] [OPTIONS]" if workflow_id.nil?

      engine = WorkflowEngine.new
      wf = engine.load_workflow(workflow_id)

      # Session metadata is set up early so the jira-snapshot gate below can
      # short-circuit BEFORE any input collection / file IO. A workflow that
      # would skip on "ticket unchanged" should not also force the user to
      # gather input first.
      session_metadata = nil
      if options[:session]
        session_metadata = SessionMetadata.new(options[:session])
        session_metadata.create_if_missing
      end

      # Jira-snapshot gate + capture: one `jira view` fetch covers both.
      # The full output is hashed (description + status + assignee + comments
      # + everything), so any field change re-arms the gate. Errors degrade
      # gracefully: print warning, run proceeds.
      #
      # snapshot_raw_text + snapshot_ticket_key are also threaded out so the
      # input collection below can auto-feed the fetched jira view text
      # when the user runs `aikiq jira_summary --session X` without piping
      # `jira view <key>` in. Same bytes used for both the snapshot fingerprint
      # and the workflow input — no fetch-time race.
      run_jira_sha       = nil
      snapshot_raw_text  = nil
      snapshot_ticket_key = nil
      gate_active  = wf.dig("vars", "requires_jira_change") ||
                     wf.dig("vars", "requires_jira_unchanged") ||
                     wf.dig("vars", "skip_if_self_authored") ||
                     wf.dig("vars", "snapshot_jira_view")
      if gate_active && session_metadata
        begin
          jira    = JiraSnapshot.new(options[:session])
          current = jira.fetch
          snapshot_raw_text   = current["raw_text"]
          snapshot_ticket_key = current["ticket_key"]
          stored  = session_metadata.load["jira_snapshot"]

          # Skip-if-unchanged: jira_summary / jira_review / jira_clarify —
          # output depends only on the ticket; nothing to re-extract.
          # `skip_if_self_authored` implies the unchanged-skip too.
          if (wf.dig("vars", "requires_jira_change") || wf.dig("vars", "skip_if_self_authored")) && !options[:force_snapshot]
            if stored && stored["content_sha256"] == current["content_sha256"]
              puts "Skipping #{workflow_id}: #{stored['ticket_key']} unchanged since #{stored['captured_at']} (captured_by: #{stored['captured_by']})"
              puts "  pass --force-snapshot to run anyway"
              return
            end
          end

          # Skip-if-self-authored: ticket changed but the latest comment is
          # mine. Common case — I just posted a jira_comment via the CLI;
          # the ticket sha flipped because of MY edit, not because there's
          # something new for jira_summary / jira_review / jira_clarify to
          # extract. Saves an LLM call per self-mutation.
          # Only fires when there IS a prior snapshot AND the sha actually
          # differs — first runs always proceed (we need that baseline
          # summary regardless of whose comment is most recent).
          if wf.dig("vars", "skip_if_self_authored") && stored &&
             stored["content_sha256"] != current["content_sha256"] &&
             !options[:force_snapshot]
            self_assignee = ENV["AIKIQ_JIRA_ASSIGNEE_SELF"] || "Your Name"
            last_author   = JiraSnapshot.latest_comment_author(current["raw_text"])
            if last_author && last_author == self_assignee
              puts "Skipping #{workflow_id}: #{current['ticket_key']} latest comment is yours (#{last_author}); nothing new to extract"
              puts "  pass --force-snapshot to run anyway"
              return
            end
          end

          # Skip-if-changed: jira_comment — drafts must be grounded in the
          # snapshot they started against. If the ticket has moved on, the
          # in-flight draft is obsolete and the user must refresh first.
          # Exits non-zero so a `aikiq jira_comment ... && post_to_jira` chain
          # does not silently fall through to a stale post.
          if wf.dig("vars", "requires_jira_unchanged") && !options[:force_snapshot]
            if stored && stored["content_sha256"] != current["content_sha256"]
              puts "Halting #{workflow_id}: #{stored['ticket_key']} CHANGED since last snapshot (captured_by: #{stored['captured_by']} at #{stored['captured_at']})"
              puts "  prior:   sha256=#{stored['content_sha256'][0, 12]}... (#{stored['byte_size']} bytes)"
              puts "  current: sha256=#{current['content_sha256'][0, 12]}... (#{current['byte_size']} bytes)"
              puts "  any draft against the prior state is obsolete."
              puts "  run `aikiq jira_summary --session #{options[:session]}` to refresh the baseline,"
              puts "  or pass --force-snapshot to draft against the new ticket state anyway."
              exit 1
            end
          end

          if wf.dig("vars", "snapshot_jira_view")
            current["captured_by"] = workflow_id
            session_metadata.set_jira_snapshot(current)
            puts "Snapshot: #{current['ticket_key']} sha256=#{current['content_sha256'][0, 12]}... (#{current['byte_size']} bytes)"
          end

          # Stamped onto the run row below so each run is traceable to the
          # exact ticket state it was drafted against.
          run_jira_sha = current["content_sha256"]
        rescue JiraSnapshot::TicketKeyNotResolvable, JiraSnapshot::JiraFetchFailed => e
          STDERR.puts "Snapshot gate/capture skipped (run proceeds): #{e.message}"
        end
      end

      processor = FileProcessor.new(
        max_size: options[:max_file_size],
        compress: options[:compress]
      )

      file_paths = []

      if options[:files] && !options[:files].empty?
        file_paths.concat(options[:files].split(",").map(&:strip))
      end

      if options[:dirs] && !options[:dirs].empty?
        patterns = options[:pattern].split(",").map(&:strip)
        options[:dirs].split(",").map(&:strip).each do |dir_path|
          raise Thor::Error, "Directory not found: #{dir_path}" unless Dir.exist?(dir_path)
          processor.collect_from_directory(dir_path, patterns).each do |path|
            file_paths << path
          end
        end
      end

      if options[:output] && !options[:output].empty?
        raise Thor::Error, "--output requires --session to be specified" unless options[:session]

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

      # Read stdin once up-front so both the `auto_inputs_only` gate and the
      # downstream parts builder can use the same value. STDIN.tty? alone
      # over-rejects in non-tty environments where stdin is closed but no
      # data was actually piped — only refuse when content is non-empty.
      stdin_content =
        if STDIN.tty?
          ""
        else
          STDIN.read
        end

      # `vars.input_source: "auto_inputs_only"` locks the workflow to its
      # declared auto_inputs — no PROMPT, --file, --dir, or stdin allowed.
      # Used when a workflow is a pure transform of one upstream workflow's
      # output (e.g. testmo_import is fed solely by gherkin_write); any
      # external supplement would couple the transform to ad-hoc context.
      auto_inputs_only = wf.dig("vars", "input_source") == "auto_inputs_only"

      if auto_inputs_only
        raise Thor::Error, "#{workflow_id} accepts input only from auto_inputs; --session is required" unless options[:session]
        raise Thor::Error, "#{workflow_id} accepts input only from auto_inputs; do not pass an inline PROMPT" if prompt && !prompt.to_s.strip.empty?
        raise Thor::Error, "#{workflow_id} accepts input only from auto_inputs; do not pass --file" if options[:files] && !options[:files].to_s.strip.empty?
        raise Thor::Error, "#{workflow_id} accepts input only from auto_inputs; do not pass --dir"  if options[:dirs]  && !options[:dirs].to_s.strip.empty?
        raise Thor::Error, "#{workflow_id} accepts input only from auto_inputs; do not pipe stdin"  if stdin_content && !stdin_content.strip.empty?
      end

      # Workflows may declare `vars.auto_inputs: [<workflow_id>, ...]` to
      # auto-include the latest session output of each listed workflow.
      # Default mode silently skips when no --session or when the file doesn't
      # exist yet. `auto_inputs_only` mode treats a missing auto_input as fatal.
      auto_inputs = Array(wf.dig("vars", "auto_inputs"))
      if auto_inputs.any? && options[:session]
        auto_inputs.each do |auto_wf|
          latest_file = resolve_latest_output(options[:session], auto_wf)
          if latest_file.nil?
            raise Thor::Error, "#{workflow_id} requires #{auto_wf} output but none was found in session #{options[:session]}; run #{auto_wf} first" if auto_inputs_only
            next
          end
          next if file_paths.include?(latest_file)
          file_paths << latest_file
          puts "Auto-resolved output file: #{latest_file}"
        end
      elsif auto_inputs_only
        raise Thor::Error, "#{workflow_id} declares input_source: auto_inputs_only but no auto_inputs are configured"
      end

      scope_context = nil
      if workflow_id == "gherkin_write" || options[:scope]
        begin
          scope_data = ScenarioScopeExtractor.extract(
            session_id: options[:session],
            project_root: Maciekos::PROJECT_ROOT
          )

          if scope_data && !scope_data.empty?
            extractor_json = scope_data.to_json
            scope_context = "\n## Scenario Scope Context\n\n```json\n#{extractor_json}\n```\n"

            STDERR.puts "[Scope Extractor] Loaded scope for ticket: #{scope_data['ticket_key']}"
            STDERR.puts "[Scope Extractor] Priority: #{scope_data['scenario_priority']} | Alignment: #{scope_data['alignment_status']}"

            active_gaps = scope_data["gaps_detected"]&.select { |_, v| v }&.keys
            STDERR.puts "[Scope Extractor] Active gaps: #{active_gaps.join(', ')}" if active_gaps&.any?

            STDERR.puts "[Scope Extractor] Code risk: #{scope_data['code_risk_detected']} | External API: #{scope_data['external_api_involved']}"
          else
            STDERR.puts "[Scope Extractor] Warning: No scope data extracted"
          end
        rescue => e
          STDERR.puts "[Scope Extractor] Warning: #{e.message}"
        end
      end

      file_paths.uniq!
      file_paths.each do |path|
        raise Thor::Error, "File not found: #{path}" unless File.exist?(path)
      end

      parts = []
      parts << scope_context if scope_context
      parts << stdin_content unless stdin_content.nil? || stdin_content.strip.empty?
      parts << prompt.strip if prompt && !prompt.strip.empty?

      unless file_paths.empty?
        parts << processor.process_files(file_paths)
      end

      # Auto-feed the snapshotted jira view text as input when no user
      # input was supplied. Drops the `jira view DEV-XXXX |` boilerplate
      # for snapshot-enabled jira_* workflows. scope_context is not user
      # input — fine to auto-feed alongside it. Only fires when the
      # snapshot block actually captured text (gate_active && session +
      # successful fetch).
      #
      # Workflows that need the user to supply draft content alongside
      # the ticket (jira_comment) opt out via `vars.auto_feed_jira_view:
      # false` — the ticket view alone is context, not input, for them.
      no_user_input  = (stdin_content.nil? || stdin_content.strip.empty?) &&
                       (prompt.nil? || prompt.strip.empty?) &&
                       file_paths.empty?
      auto_feed_off  = wf.dig("vars", "auto_feed_jira_view") == false
      if no_user_input && !auto_feed_off && snapshot_raw_text && !snapshot_raw_text.strip.empty?
        parts << snapshot_raw_text
        puts "Auto-fed: jira view #{snapshot_ticket_key} (#{snapshot_raw_text.bytesize} bytes; pipe `jira view ... |` to override)"
      end

      raise Thor::Error, "No input provided. Supply PROMPT, --file, or --dir." if parts.empty?

      prompt_text = parts.join("\n\n")

      model_override = options[:model] || wf.dig("vars", "default_model")

      session_id = options[:session]
      prepared_prompt, system_message = engine.prepare_prompt(wf, session_id, prompt_text)

      if options[:dry_run]
        puts "=" * 80
        puts "DRY RUN: #{workflow_id}"
        puts "=" * 80
        puts "Model: #{model_override || 'workflow default'}"
        puts "Files: #{file_paths.length}"
        file_paths.each_with_index { |f, i| puts "  #{i + 1}. #{f}" }
        puts "Prompt length: #{prepared_prompt.length} chars"
        puts "\nFirst 1500 chars:"
        puts prepared_prompt[0..1500]
        puts "\n" + "=" * 80
        return
      end

      session_run_id = nil
      if session_metadata
        session_run_id = session_metadata.append_run(workflow_id)["run_id"]
        session_metadata.set_run_jira_snapshot_sha(session_run_id, run_jira_sha) if run_jira_sha
      end

      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      hash = Digest::SHA256.hexdigest(prepared_prompt)[0, 8]
      run_id = "#{ts}-#{hash}"

      adapter_opts = { system_message: system_message }
      adapter_opts[:models_override] = [model_override] if model_override

      reasoning_override = wf.dig("vars", "reasoning_effort_override")
      adapter_opts[:reasoning_effort_override] = reasoning_override if reasoning_override

      adapter = OpenRouterAdapter.new
      model_prefs = wf.dig("vars", "model_preferences") || []
      responses = adapter.call_with_fanout(model_prefs, prepared_prompt, adapter_opts)

      evaluator = Evaluator.new(wf)
      result = evaluator.validate_and_select(responses, run_id)

      artifact_path = engine.write_artifact(
        workflow_id,
        run_id,
        result,
        session: options[:session],
        label: options[:label]
      )

      output_path = display_results(result, artifact_path, file_paths, workflow_id)

      # Gate runner — Phase 2 of AST plan. Workflows opt in via vars.gates;
      # each listed id resolves to a Maciekos::Checks::Base subclass that
      # produces a Result. Failures are recorded into session_log
      # check_results[] before halting, so even forced bypasses leave an
      # audit trail. Mirrors requires_jira_unchanged pattern (exit 1) when
      # a gate fails without --force-gate bypass.
      declared_gates = Array(wf.dig("vars", "gates"))
      if declared_gates.any? && session_metadata && session_run_id
        forced_gates  = Array(options[:force_gate]).flat_map { |g| g.to_s.split(",") }.map(&:strip).reject(&:empty?)
        forced_reason = options[:force_reason]

        gate_context = {
          workflow:      wf,
          workflow_id:   workflow_id,
          selected:      result[:selected],
          artifact_path: artifact_path,
          output_path:   output_path,
          session_id:    options[:session]
        }

        declared_gates.each do |gate_id|
          check_class = Checks::Base.find(gate_id)
          unless check_class
            STDERR.puts "Gate '#{gate_id}' declared in vars.gates but no Check class registered for it; skipping."
            next
          end
          check = check_class.new
          next unless check.applies_to?(workflow_id)

          gate_result = check.run(gate_context)
          forced      = forced_gates.include?(gate_id)

          session_metadata.append_check_result(
            gate_result.to_h(
              run_id:       session_run_id,
              forced:       forced && !gate_result.passed,
              force_reason: (forced && !gate_result.passed) ? forced_reason : nil
            )
          )

          next if gate_result.passed
          if forced
            puts "⚠ Gate '#{gate_id}' FAILED but bypassed via --force-gate (reason: #{forced_reason || '<none>'})"
            gate_result.messages.each { |m| puts "  #{m}" }
            next
          end

          puts "Halting #{workflow_id}: gate '#{gate_id}' failed"
          gate_result.messages.each { |m| puts "  #{m}" }
          puts ""
          puts "  bypass: --force-gate #{gate_id} --force-reason \"<reason>\""
          puts "  forensic artifact: #{artifact_path}"
          session_metadata.finalize_run(
            session_run_id,
            output_path ? File.basename(output_path) : nil,
            false
          )
          exit 1
        end
      end

      if session_metadata && session_run_id
        session_metadata.finalize_run(
          session_run_id,
          output_path ? File.basename(output_path) : nil,
          derive_validation_passed(wf, result)
        )
      end
    end

    desc "playbook [NAME]...", "Bundle hand-written playbooks for one-shot LLM consumption"
    long_desc <<-DESC
      Concatenate the playbooks router (notes/playbooks/README.md) and any
      named leaves into a single bundle, ready to paste into an LLM session.
      Pure file IO — no LLM call. Composable: pass multiple names to bundle
      several leaves.

      Examples:
        aikiq playbook qa_handoff
        aikiq playbook qa_close qa_handoff --with-toc
        aikiq playbook --list
        aikiq playbook --info qa_handoff
        aikiq playbook --scenario verification_fail --session 1234_x_y --why "bouncing back"
    DESC
    option :list,       type: :boolean, default: false, desc: "List available playbook names, one per line"
    option :info,       type: :string,                  desc: "Print metadata (H1 + first paragraph + mtime + size) for the named playbook"
    option :no_readme,  type: :boolean, default: false, desc: "Skip the README router"
    option :no_rules,   type: :boolean, default: false, desc: "Drop the Cross-cutting rules section from README"
    option :no_context, type: :boolean, default: false, desc: "Skip the auto-included process_context.md preamble"
    option :include,    type: :array,                   desc: "Append contents of arbitrary file(s) at the tail"
    option :scenario,   type: :string,                  desc: "Resolve a preset bundle from scenarios.yaml"
    option :format,     type: :string,  default: "markdown", enum: %w[markdown plain json], desc: "Output format"
    option :with_toc,   type: :boolean, default: false, desc: "Generate a markdown TOC at the top"
    option :no_header,  type: :boolean, default: false, desc: "Suppress the provenance header comment"
    option :max_bytes,  type: :numeric,                 desc: "Hard truncate at N bytes (post-assembly)"
    option :max_tokens, type: :numeric,                 desc: "Hard truncate at ~N tokens (4 chars/token estimate)"
    option :output,     type: :string,  aliases: "-o",  desc: "Write to file rather than stdout"
    option :dir,        type: :string,                  desc: "Override playbooks directory (also AIKIQ_PLAYBOOKS_DIR)"
    option :session,    type: :string,                  desc: "Log this invocation in session_log.json"
    option :why,        type: :string,                  desc: "Free-text annotation for the session log entry"
    def playbook(*names)
      pb = Playbook.new(dir: options[:dir])

      if options[:list]
        raise Thor::Error, "--list cannot be combined with positional names" unless names.empty?
        puts pb.list_names
        return
      end

      if options[:info]
        begin
          puts pb.info(options[:info])
        rescue Playbook::UnknownPlaybook => e
          STDERR.puts e.message
          STDERR.puts "Available: #{e.available.join(', ')}" unless e.available.empty?
          exit 2
        end
        return
      end

      include_readme  = !options[:no_readme]
      include_rules   = !options[:no_rules]
      include_context = !options[:no_context]
      with_toc        = options[:with_toc]
      no_header       = options[:no_header]
      includes        = Array(options[:include])

      effective_names = names.dup

      if options[:scenario]
        begin
          sc = pb.scenario(options[:scenario])
        rescue Playbook::UnknownScenario => e
          STDERR.puts e.message
          STDERR.puts "Available scenarios: #{e.available.join(', ')}" unless e.available.empty?
          exit 4
        end

        effective_names = sc[:names] + effective_names
        flag_set        = sc[:flags].to_set

        # Boolean flags from the scenario OR-merge with explicit options;
        # explicit `--no-X` and the scenario `--X` would conflict, but Thor
        # doesn't surface "user explicitly set this", so the convention is
        # not to combine a scenario with a flag that contradicts it.
        with_toc         ||= flag_set.include?("--with-toc")
        no_header        ||= flag_set.include?("--no-header")
        include_readme   &&= !flag_set.include?("--no-readme")
        include_rules    &&= !flag_set.include?("--no-rules")
        include_context  &&= !flag_set.include?("--no-context")
      end

      effective_names = effective_names.flat_map { |n| n == "*" ? pb.list_names : [n] }.uniq

      command_string = "aikiq playbook #{effective_names.join(' ')}".rstrip

      begin
        bundle = pb.bundle(
          names:           effective_names,
          include_readme:  include_readme,
          include_rules:   include_rules,
          include_context: include_context,
          includes:        includes,
          with_toc:        with_toc,
          no_header:       no_header,
          format:          options[:format],
          max_bytes:       options[:max_bytes],
          max_tokens:      options[:max_tokens],
          command_string:  command_string
        )
      rescue Playbook::UnknownPlaybook => e
        STDERR.puts e.message
        STDERR.puts "Available: #{e.available.join(', ')}" unless e.available.empty?
        exit 2
      rescue Playbook::IncludeNotReadable => e
        STDERR.puts e.message
        exit 3
      end

      if options[:output]
        File.write(options[:output], bundle)
      else
        $stdout.write(bundle)
        $stdout.write("\n") unless bundle.end_with?("\n")
      end

      if options[:session]
        begin
          sm = SessionMetadata.new(options[:session])
          raise Thor::Error, "session_log not found for '#{options[:session]}'" unless sm.exists?
          sm.log_playbook_load(effective_names, why: options[:why])
        rescue ArgumentError, RuntimeError => e
          raise Thor::Error, e.message
        end
      end
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
    option :session, type: :string, desc: "Session identifier (required)"
    def print(workflow_id)
      require_session!
      session_path = File.join(Maciekos::PROJECT_ROOT, "sessions", options[:session], "outputs")

      raise Thor::Error, "Session directory not found: #{session_path}" unless Dir.exist?(session_path)

      # Match: <seq>_<workflow_id>.ext or <seq>_<workflow_id>_<suffix>.ext
      # Strict boundary so 'code_review' does not match '019_jira_code_review.md'.
      files = Dir.glob(File.join(session_path, "*")).select do |filepath|
        File.basename(filepath) =~ /^\d+_#{Regexp.escape(workflow_id)}(\.|_)/
      end

      if files.empty?
        raise Thor::Error, "No output files found for workflow '#{workflow_id}' in session '#{options[:session]}'"
      end

      latest_file = files.sort_by { |filename| File.basename(filename).split("_").first.to_i }.last
      basename    = File.basename(latest_file)

      if workflow_id =~ /testmo/
        puts File.read(latest_file)
      else
        puts TTY::Markdown.parse(File.read(latest_file), indent: 2, color: :never)
      end

      puts "\nDisplaying: #{basename}"
    end

    desc "status", "Render the session's metadata (runs, tasks, checklist, note) as Markdown"
    option :session, type: :string, desc: "Session identifier (required)"
    option :all,     type: :boolean, default: false, desc: "Also include done tasks (hidden by default)"
    def status
      require_session!
      with_session_metadata(options[:session]) do |sm|
        puts TTY::Markdown.parse(
          format_session_status(sm.load, show_done_tasks: options[:all]),
          indent: 2,
          color:  :never
        )
      end
    end

    desc "backfill", "Reconstruct runs[] in session_log.json from numbered files on disk"
    long_desc <<-DESC
      Walk the session's category directories (jira/, code/, gherkin/, testmo/, ...),
      treat each NNN_<workflow_id>.json file as a recorded run, sort chronologically
      by mtime, match each to its outputs/ rendered file in order, and replace runs[]
      in session_log.json. Tasks, note, and checklist are preserved. created_at is
      shifted backward to the earliest run's mtime unless --keep-created-at is set.

      Use this for legacy sessions that pre-date session metadata, or to repair drift
      after manual file moves.
    DESC
    option :session,          type: :string,  desc: "Session identifier (required)"
    option :keep_created_at,  type: :boolean, default: false, desc: "Don't shift created_at to earliest run"
    def backfill
      require_session!

      bf   = SessionBackfill.new(options[:session])
      runs = bf.call(adjust_created_at: !options[:keep_created_at])

      if runs.empty?
        puts "No numbered files found under sessions/#{options[:session]}/<category>/. Nothing to backfill."
        return
      end

      puts "Reconstructed #{runs.length} run(s) for session #{options[:session]}:"
      runs.each do |r|
        out = r["output_file_name"] || "(no rendered output)"
        puts "  ##{r['run_id']} #{r['workflow_id']} iter=#{r['workflow_iteration']} → #{out}  @ #{r['created_at']}"
      end

      unless bf.unmatched_files.empty?
        STDERR.puts "\nSkipped #{bf.unmatched_files.length} file(s) that did not match a known workflow_id:"
        bf.unmatched_files.each { |f| STDERR.puts "  #{f}" }
      end
    end

    desc "snapshot", "Capture or verify the SHA256 fingerprint of `jira view DEV-XXX` (no model call)"
    long_desc <<-DESC
      Pure SHA-fingerprint operation — runs `jira view <ticket>` and either
      writes or compares. No LLM call, no token spend.

      Without --check: writes a snapshot (sha256 + byte_size + captured_at)
      into session_log.json under jira_snapshot. Newer captures overwrite
      older. Use this to refresh the baseline after the
      requires_jira_unchanged gate halts a workflow on legitimate drift —
      cleaner than running the workflow with --force-snapshot, which spends
      tokens just to re-stamp the SHA.

      With --check: compares current vs stored. Exits 0 if unchanged, 1 if
      changed, 2 if no snapshot exists yet — composes in scripts.

      The fingerprint is computed over a normalized form of the `jira view`
      output (relative timestamps like "27 days ago" collapsed to a constant)
      so day-rollover doesn't trigger spurious drift.

      Ticket key is derived from the session id (e.g. "1234_x_y"
      → XX-1234, "XX-5678" → XX-5678). The project key prefix defaults
      to "XX"; override via AIKIQ_JIRA_PROJECT_KEY.
    DESC
    option :session, type: :string,  desc: "Session identifier (required)"
    option :check,   type: :boolean, default: false, desc: "Compare current vs stored; exit non-zero if changed"
    def snapshot
      require_session!

      jira = JiraSnapshot.new(options[:session])

      if options[:check]
        diff = jira.diff
        if diff["stored"].nil?
          STDERR.puts "no snapshot stored for #{options[:session]} — run `aikiq snapshot --session #{options[:session]}` first"
          exit 2
        end

        cur = diff["current"]
        sto = diff["stored"]
        if diff["changed"]
          puts "✗ #{cur['ticket_key']} CHANGED since #{sto['captured_at']} (captured_by: #{sto['captured_by']})"
          puts "  stored:  sha256=#{sto['content_sha256'][0, 12]}... (#{sto['byte_size']} bytes)"
          puts "  current: sha256=#{cur['content_sha256'][0, 12]}... (#{cur['byte_size']} bytes)"
          exit 1
        else
          puts "✓ #{cur['ticket_key']} unchanged since #{sto['captured_at']} (captured_by: #{sto['captured_by']})"
          puts "  sha256=#{sto['content_sha256'][0, 12]}... (#{sto['byte_size']} bytes)"
        end
      else
        snap = jira.capture(captured_by: "manual")
        puts "captured #{snap['ticket_key']}: sha256=#{snap['content_sha256'][0, 12]}... (#{snap['byte_size']} bytes) at #{snap['captured_at']}"
      end
    rescue JiraSnapshot::TicketKeyNotResolvable, JiraSnapshot::JiraFetchFailed => e
      raise Thor::Error, e.message
    end

    desc "sentry-projects", "List Sentry projects visible to the token (org-scoped)"
    long_desc <<-DESC
      Prints every project slug the token can see in the configured org.
      Useful as a quick lookup when switching investigation focus between
      projects without leaving the shell.

        aikiq sentry-projects                       # all projects in $SENTRY_ORG
        aikiq sentry-projects --filter backend      # substring match on slug/name
    DESC
    map "sentry-projects" => :sentry_projects
    option :org,    type: :string, desc: "Sentry org slug (default: $SENTRY_ORG)"
    option :filter, type: :string, desc: "Case-insensitive substring; matches slug or name"
    def sentry_projects
      client   = SentryClient.new(org: options[:org])
      projects = client.list_projects

      if !projects.is_a?(Array) || projects.empty?
        puts "No projects."
        return
      end

      filter = options[:filter]&.downcase
      projects.each do |p|
        slug     = p["slug"].to_s
        name     = p["name"].to_s
        platform = p["platform"].to_s
        next if filter && !"#{slug} #{name}".downcase.include?(filter)
        marker   = (slug == ENV["SENTRY_PROJECT"].to_s ? " ← current $SENTRY_PROJECT" : "")
        puts "  %-20s %-30s %s%s" % [slug, name, platform, marker]
      end
    rescue SentryClient::AuthMissing, SentryClient::ConfigMissing, SentryClient::FetchFailed => e
      raise Thor::Error, e.message
    end

    desc "sentry-list", "List recent Sentry issues — org-wide by default, project-scoped with --project"
    long_desc <<-DESC
      Reads SENTRY_AUTH_TOKEN (or ~/.config/maciekos/sentry_auth_token) +
      SENTRY_ORG. Without --project (and with no $SENTRY_PROJECT set) lists
      issues across the whole org so you can triage without committing to a
      project up front. Pass --project to narrow.

        aikiq sentry-list                                       # org-wide, unresolved
        aikiq sentry-list --project backend-test --since 14d
        aikiq sentry-list --query '' --limit 50                 # all statuses
        aikiq sentry-list --json | jq '.[].id'                  # script-friendly

      Default --query is `is:unresolved` — most common triage case. Pass
      --query '' to disable filtering. The `id` column is the numeric Sentry
      id needed by sentry-pull (short id works too — see sentry-pull --help).

      Note: SENTRY_PROJECT is intentionally NOT set in .envrc so org-wide is
      the default. Set it in your shell only when you want a sticky default.
    DESC
    map "sentry-list" => :sentry_list
    option :org,     type: :string,  desc: "Sentry org slug (default: $SENTRY_ORG)"
    option :project, type: :string,  desc: "Sentry project slug (default: $SENTRY_PROJECT — if absent, org-wide)"
    option :limit,   type: :numeric, default: 25, desc: "Max issues to fetch"
    option :since,   type: :string,  default: "24h", desc: "Sentry statsPeriod: 24h, 14d (self-hosted) / 1h, 7d, ... (SaaS)"
    option :query,   type: :string,  default: "is:unresolved", desc: "Sentry search query — pass '' to disable"
    option :json,    type: :boolean, default: false, desc: "Emit raw JSON array instead of the table (for piping)"
    def sentry_list
      client = SentryClient.new(org: options[:org], project: options[:project])
      issues = client.list_issues(limit: options[:limit], since: options[:since], query: options[:query])

      if options[:json]
        puts JSON.pretty_generate(issues || [])
        return
      end

      scope = client.project_set? ? "#{client.org}/#{client.project}" : "#{client.org} (org-wide)"
      STDERR.puts "Scope: #{scope} · since=#{options[:since]} · limit=#{options[:limit]} · query=#{options[:query].inspect}"

      if !issues.is_a?(Array) || issues.empty?
        puts "No issues."
        return
      end

      include_project_col = !client.project_set?
      cols = include_project_col ? %w[project id shortId level title last_seen count] : %w[id shortId level title last_seen count]
      fmt  = include_project_col ? "%-18s %-8s %-18s %-6s %-50s %-22s %s" : "%-8s %-18s %-6s %-50s %-22s %s"
      puts fmt % cols

      issues.each do |issue|
        id    = (issue["id"] || "?").to_s
        short = (issue["shortId"] || issue["id"] || "?").to_s
        title = (issue["title"] || "").to_s
        title = title[0, 49] + "…" if title.length > 50
        level = (issue["level"] || "?").to_s
        last  = (issue["lastSeen"] || "").to_s
        count = (issue["count"] || "?").to_s

        if include_project_col
          proj = issue.dig("project", "slug") || infer_project_from_short_id(short) || "?"
          puts fmt % [proj, id, short, level, title, last, count]
        else
          puts fmt % [id, short, level, title, last, count]
        end
      end
    rescue SentryClient::AuthMissing, SentryClient::ConfigMissing, SentryClient::FetchFailed => e
      raise Thor::Error, e.message
    end

    no_commands do
      # Sentry shortIds are <PROJECT-SLUG-UPPERCASED>-<HEX>, e.g. BACKEND-AB.
      # Drop the last hyphen segment, lowercase the rest. Best-effort fallback
      # when the issue payload doesn't carry the project sub-object.
      def infer_project_from_short_id(short)
        return nil unless short.is_a?(String) && short.include?("-")
        head = short.split("-")[0..-2].join("-")
        head.empty? ? nil : head.downcase
      end

      # Most-recent standup-day cutoff strictly before `now`, in local time.
      # Anchors the daily-jog "since when?" to your team's standup ritual so
      # `aikiq daily` always reports work since the last standup.
      #
      # Configure via env vars:
      #   AIKIQ_STANDUP_DAYS  comma-separated wday integers (default: "2,4"
      #                       for Tue/Thu)
      #   AIKIQ_STANDUP_HOUR  hour-of-day in 0-23 (default: "10")
      #   AIKIQ_STANDUP_MIN   minutes-past-the-hour (default: "0")
      #
      # Walks back day-by-day; terminates within at most 7 iterations.
      def last_daily_cutoff(now)
        days  = (ENV["AIKIQ_STANDUP_DAYS"] || "2,4").split(",").map { |s| s.to_i }
        hour  = (ENV["AIKIQ_STANDUP_HOUR"] || "10").to_i
        minute = (ENV["AIKIQ_STANDUP_MIN"]  || "0").to_i
        d = now
        loop do
          if days.include?(d.wday)
            stamp = Time.new(d.year, d.month, d.day, hour, minute, 0, d.utc_offset)
            return stamp if stamp < now
          end
          d -= 86_400
        end
      end

      # Parse "24h", "3d", "90m" → Time relative to now.
      def parse_duration_ago(spec)
        m = spec.to_s.strip.match(/\A(\d+)\s*([smhd])\z/)
        raise Thor::Error, "--since expects forms like 24h, 3d, 90m (got #{spec.inspect})" unless m
        n = m[1].to_i
        secs = case m[2]
               when "s" then n
               when "m" then n * 60
               when "h" then n * 3600
               when "d" then n * 86_400
               end
        Time.now - secs
      end

      # Walk sessions/*/session_log.json, return rows with a derived jog line
      # plus a closed-since-cutoff marker. Sorted: closed first (most recent
      # first), then open (most recent activity first).
      def collect_daily_sessions(cutoff:, closed_window_days:)
        rows = []
        # Cap the closed-grace window at the activity window itself so a tight
        # cutoff (e.g. --since 10m) doesn't pull in yesterday's closes via the
        # default 1-day grace. The grace was designed for standup-mode runs
        # where the activity window is already 2+ days; for short windows the
        # cap effectively disables it.
        window_size  = (Time.now - cutoff).to_i
        grace_size   = [closed_window_days * 86_400, window_size].min
        Dir.glob(File.join(Maciekos::PROJECT_ROOT, "sessions", "*", "session_log.json")).sort.each do |path|
          data = begin
            JSON.parse(File.read(path))
          rescue StandardError
            next
          end
          sid           = data["session_id"]
          status        = data["status"]
          last_activity = safe_time(data["last_activity_at"])
          closed_at     = safe_time(data["closed_at"])
          reassigned_at = safe_time(data["reassigned_at"])
          # Latest "terminal-ish" event timestamp — covers both close and
          # reassign. Used for grace eligibility + sort.
          terminal_at   = [closed_at, reassigned_at].compact.max

          # Eligibility:
          # - any session with last_activity_at >= cutoff
          # - PLUS recently-closed-or-reassigned sessions (terminal_at
          #   within grace window capped at activity window) so standup
          #   runs still surface yesterday's closes/handoffs without
          #   short-cutoff runs surfacing them.
          touched_in_window  = last_activity && last_activity >= cutoff
          terminal_in_window = terminal_at && terminal_at >= cutoff - grace_size
          next unless touched_in_window || terminal_in_window

          rows << {
            id:                    sid,
            status:                status,
            last_activity:         last_activity,
            closed_at:             closed_at,
            reassigned_at:         reassigned_at,
            terminal_since_cutoff: terminal_at && terminal_at >= cutoff,
            jog:                   session_jog(data, sid)
          }
        end

        rows.sort_by do |r|
          # closed/reassigned-since-cutoff first ("yesterday I closed/handed
          # off X"), then by last_activity descending.
          [r[:terminal_since_cutoff] ? 0 : 1, -(r[:last_activity]&.to_i || 0)]
        end
      end

      # The one-line jog. Priority chain — first non-empty wins:
      #   1. session.note (manual, what the user wrote)
      #   2. first body line of latest jira_comment .md (the comment drafted)
      #   3. Title section value of latest jira_summary .md
      #   4. session id (fallback)
      #
      # Returns the full flattened single-line text. The daily renderer
      # decides how aggressively to truncate based on terminal width.
      def session_jog(data, sid)
        note = data["note"]
        # Skip notes that are explicitly low-signal:
        # - [auto ...] prefix is from the historical jira_summary backfill
        #   sweep — bulk-populated ticket state, not a user jog.
        # - note_force_reason set means the linter rejected the content and
        #   the user bypassed via `aikiq note --force`. Such notes were
        #   explicitly marked low-quality and shouldn't headline the daily.
        # In both cases fall through so the daily picks up something better.
        if note && !note.strip.empty? &&
           !note.strip.start_with?("[auto") &&
           data["note_force_reason"].nil?
          return flatten_jog(note)
        end

        outputs_dir = File.join(Maciekos::PROJECT_ROOT, "sessions", sid, "outputs")

        Dir.glob(File.join(outputs_dir, "*_jira_comment*.md")).sort.reverse.each do |p|
          line = first_meaningful_line(File.read(p))
          return flatten_jog(line) if line
        end

        Dir.glob(File.join(outputs_dir, "*_jira_summary*.md")).sort.reverse.each do |p|
          title = extract_md_title(File.read(p))
          return flatten_jog(title) if title
        end

        sid
      end

      def flatten_jog(text)
        return nil if text.nil?
        text.gsub(/\s+/, " ").strip
      end

      def first_meaningful_line(text)
        text.lines.each do |line|
          stripped = line.strip
          next if stripped.empty?
          next if stripped.start_with?("<!--", "#", "---", "```")
          return stripped
        end
        nil
      end

      # Rendered jira_summary is "### Title\n\n<value>\n\n### …".
      def extract_md_title(md)
        m = md.match(/^### Title\s*\n\s*\n(.+?)\s*\n\s*\n/m)
        m ? m[1].strip : nil
      end

      def truncate_jog(text, max = 90)
        return nil if text.nil?
        flat = flatten_jog(text)
        return flat if flat.length <= max
        # Hard cut — all truncated rows end at exactly `max` chars so the
        # "…" column aligns. Previously trimmed at the last word boundary,
        # which made the right edge drift across rows.
        flat[0, max - 1] + "…"
      end

      def truncate_sid(sid, max)
        return sid.to_s if sid.to_s.length <= max
        sid.to_s[0, max - 1] + "…"
      end

      def safe_time(s)
        return nil if s.nil? || s.to_s.empty?
        Time.parse(s)
      rescue ArgumentError
        nil
      end

      def pipe_to_clipboard(text)
        if system("which xclip > /dev/null 2>&1")
          IO.popen(%w[xclip -selection clipboard], "w") { |io| io.write(text) }
          "xclip"
        elsif system("which pbcopy > /dev/null 2>&1")
          IO.popen(%w[pbcopy], "w") { |io| io.write(text) }
          "pbcopy"
        else
          nil
        end
      end

      # Breadcrumb message extraction with category-aware fallbacks.
      # Sentry's `message` field is empty for sql.active_record / http and a
      # few other categories — the actual content lives under `data` (sql,
      # name, statement_name, url, method, etc.). Without these fallbacks
      # half the breadcrumbs render as bare "[sql.active_record]" lines.
      def breadcrumb_message(bc)
        msg = bc["message"]
        return msg.to_s if msg && !msg.to_s.strip.empty?
        data = bc["data"]
        return "" unless data.is_a?(Hash) && !data.empty?

        return data["sql"].to_s.strip if data["sql"].is_a?(String) && !data["sql"].to_s.strip.empty?

        # http-style: prefer "METHOD url" over key=val dump
        if data["url"].is_a?(String) && !data["url"].to_s.strip.empty?
          method = data["method"].to_s.upcase
          return "#{method} #{data["url"]}".strip
        end

        # generic fallback: top 3 keys as key=val pairs, values truncated
        data.first(3).map { |k, v|
          v_s = v.is_a?(String) ? v : v.inspect
          "#{k}=#{v_s[0, 60]}"
        }.join(" ")
      end
    end

    desc "scrum [JQL_FRAGMENT...]", "Search Jira via /rest/api/3/search/jql (replaces the dead /search endpoint go-jira's `list` used)"
    long_desc <<-DESC
      Lists issues matching a JQL query. Default scope is "my open work":
      `status NOT IN (Done, Canceled) AND assignee = currentUser()`. Pass
      JQL fragments as positional args to AND them onto the default — e.g.

        aikiq scrum                                      # my open issues
        aikiq scrum 'sprint in openSprints()'            # current sprint, mine, open
        aikiq scrum --exclude-status "Ready For Staging" Testing
        aikiq scrum --status "In Progress" Testing       # only these statuses
        aikiq scrum --unassigned --status "In Refinement"  # refinement queue: pick one, take it
        aikiq scrum 'project = DEV' 'priority = High'    # AND-ed
        aikiq scrum -q 'reporter = currentUser() AND created > -14d'  # full override

      `-q` (full override) skips the default scope entirely. Output is a
      flat aligned table; `--json` emits the raw API payload.

      Auth: reads ~/.jira.d/config.yml (the same file go-jira uses); env
      vars AIKIQ_JIRA_ENDPOINT / AIKIQ_JIRA_EMAIL / AIKIQ_JIRA_API_TOKEN
      override.
    DESC
    option :query,          type: :string,                     aliases: "-q", desc: "Full JQL override (ignores default scope)"
    option :limit,          type: :numeric, default: 25,                      desc: "Max results (Atlassian caps at 100)"
    option :status,         type: :array,                                     desc: "AND status IN (...); space-separated, e.g. --status 'In Progress' Testing"
    option :exclude_status, type: :array,                                     desc: "AND status NOT IN (...); space-separated, same shape as --status"
    option :priority,       type: :array,                                     desc: "AND priority IN (...); space-separated, e.g. --priority High Highest"
    option :type,           type: :array,                                     desc: "AND issuetype IN (...); space-separated, e.g. --type Bug Story"
    option :watched,        type: :boolean, default: false,                   desc: "Swap assignee = currentUser() for watcher = currentUser()"
    option :unassigned,     type: :boolean, default: false,                   desc: "Swap to `assignee is EMPTY` (refinement-queue grooming)"
    option :recent,         type: :string,                                    desc: "AND updated > -<duration>, e.g. 3d, 1w, 24h"
    option :json,           type: :boolean, default: false,                   desc: "Emit raw API JSON instead of the table"
    def scrum(*jql_fragments)
      client = JiraClient.new

      jql =
        if options[:query] && !options[:query].empty?
          options[:query]
        else
          actor =
            if options[:unassigned]
              "assignee is EMPTY"
            elsif options[:watched]
              "watcher = currentUser()"
            else
              "assignee = currentUser()"
            end
          parts = ["status NOT IN (Done, Canceled)", actor]
          parts.concat(jql_fragments) if jql_fragments.any?
          if options[:status]&.any?
            parts << "status IN (#{options[:status].map { |s| quote_jql(s) }.join(', ')})"
          end
          if options[:exclude_status]&.any?
            parts << "status NOT IN (#{options[:exclude_status].map { |s| quote_jql(s) }.join(', ')})"
          end
          if options[:priority]&.any?
            parts << "priority IN (#{options[:priority].map { |s| quote_jql(s) }.join(', ')})"
          end
          if options[:type]&.any?
            parts << "issuetype IN (#{options[:type].map { |s| quote_jql(s) }.join(', ')})"
          end
          if options[:recent]
            d = options[:recent].to_s.strip
            raise Thor::Error, "--recent expects forms like 24h, 3d, 1w (got #{d.inspect})" unless d =~ /\A\d+[smhdw]\z/
            parts << "updated > -#{d}"
          end
          parts.join(" AND ") + " ORDER BY updated DESC"
        end

      payload = client.search_jql(jql: jql, max_results: options[:limit])

      if options[:json]
        puts JSON.pretty_generate(payload || {})
        return
      end

      issues = Array(payload && payload["issues"])
      STDERR.puts "JQL: #{jql}"
      STDERR.puts "Endpoint: #{client.endpoint}  ·  results: #{issues.length}#{payload && payload['nextPageToken'] ? ' (truncated; --limit to expand)' : ''}"

      if issues.empty?
        puts "No issues."
        return
      end

      fmt = "%-12s %-22s %-8s %-22s %s"
      puts fmt % %w[KEY STATUS PRI ASSIGNEE SUMMARY]
      issues.each do |iss|
        f        = iss["fields"] || {}
        key      = iss["key"].to_s
        status   = f.dig("status",   "name").to_s
        priority = f.dig("priority", "name").to_s
        assignee = f.dig("assignee", "displayName").to_s
        assignee = "—" if assignee.empty?
        summary  = f["summary"].to_s
        summary  = summary[0, 79] + "…" if summary.length > 80
        puts fmt % [key, truncate(status, 22), truncate(priority, 8), truncate(assignee, 22), summary]
      end
    rescue JiraClient::AuthMissing, JiraClient::ConfigMissing, JiraClient::FetchFailed => e
      raise Thor::Error, e.message
    end

    no_commands do
      def quote_jql(value)
        v = value.to_s.gsub('"', '\"')
        %("#{v}")
      end

      def truncate(s, n)
        s = s.to_s
        s.length > n ? s[0, n - 1] + "…" : s
      end
    end

    desc "userid QUERY", "Search Atlassian users; print displayName + [~accountid:...] mention syntax"
    long_desc <<-DESC
      Substring-matches against display name + email. Output is one user per
      line, tab-aligned: `<displayName>\\t[~accountid:...]`. The
      `[~accountid:...]` form is what Jira renders as a mention in comments
      — paste it directly into a `jira comment` body.

      Inactive users are filtered out. --all to include them.
    DESC
    option :limit, type: :numeric, default: 10
    option :all,   type: :boolean, default: false, desc: "Include inactive users"
    def userid(query = nil)
      raise Thor::Error, "QUERY required" if query.nil? || query.empty?
      client = JiraClient.new
      users  = Array(client.search_users(query, max_results: options[:limit]))
      users  = users.select { |u| u["active"] } unless options[:all]

      if users.empty?
        puts "No users matched #{query.inspect}."
        return
      end

      width = users.map { |u| u["displayName"].to_s.length }.max
      users.each do |u|
        puts "%-#{width}s  [~accountid:%s]" % [u["displayName"].to_s, u["accountId"].to_s]
      end
    rescue JiraClient::AuthMissing, JiraClient::ConfigMissing, JiraClient::FetchFailed => e
      raise Thor::Error, e.message
    end

    desc "fixversion-list [PROJECT]", "List Jira project versions (default: current-year unreleased only)"
    long_desc <<-DESC
      Default: current-year unreleased versions in the named project (or DEV
      if omitted), sorted version-style. --all skips both filters; --year YYYY
      overrides the year; --include-released keeps released versions in the list.

      Mirrors the user's zshrc `jira_list_versions` helper but goes through
      the v3 API (the bash version still calls /rest/api/2/project/...) and
      surfaces structured errors when the project key is wrong or the token
      lacks permission.
    DESC
    option :all,              type: :boolean, default: false, desc: "Skip year + released filters"
    option :year,             type: :string,                  desc: "Override current-year filter (YYYY)"
    option :include_released, type: :boolean, default: false, desc: "Keep released versions in the list"
    def fixversion_list(project = "DEV")
      client = JiraClient.new
      versions = Array(client.list_versions(project))
      year     = options[:year] || Time.now.year.to_s

      filtered =
        if options[:all]
          versions
        else
          versions.select do |v|
            (v["name"].to_s.include?(year)) &&
              (options[:include_released] || v["released"] != true)
          end
        end

      filtered = filtered.sort_by { |v| version_sort_key(v["name"].to_s) }

      if filtered.empty?
        puts "No versions matching project=#{project} year=#{year} (use --all to inspect raw list)."
        return
      end

      filtered.each do |v|
        flags = []
        flags << "released"  if v["released"]
        flags << "archived"  if v["archived"]
        flag_str = flags.empty? ? "" : "  (#{flags.join(', ')})"
        puts "#{v['name']}#{flag_str}"
      end
    rescue JiraClient::AuthMissing, JiraClient::ConfigMissing, JiraClient::FetchFailed => e
      raise Thor::Error, e.message
    end

    desc "fixversion-add KEY VERSION [VERSION ...]", "Append fix versions to an issue (preserves existing, dedupes)"
    long_desc <<-DESC
      Reads the issue's current fixVersions, appends the named versions, dedupes
      by name, and PUTs the merged list back. Mirrors the user's zshrc
      `jira_set_versions` helper but on the v3 endpoint (the bash version
      still hits /rest/api/2/issue/...).

      Use `aikiq fixversion-list <PROJECT>` first to confirm the target version
      names exist — Jira will accept any string and silently no-op for
      non-existent names on some configurations.
    DESC
    def fixversion_add(key = nil, *versions)
      raise Thor::Error, "KEY required (e.g. XX-1234)" if key.nil? || key.empty?
      raise Thor::Error, "at least one VERSION required" if versions.empty?

      client  = JiraClient.new
      current = Array(client.get_issue(key, fields: %w[fixVersions]).dig("fields", "fixVersions"))
      existing_names = current.map { |v| v["name"].to_s }
      added          = versions - existing_names
      merged_names   = (existing_names + added).uniq

      if added.empty?
        puts "#{key}: already has #{versions.join(', ')} — no change."
        return
      end

      client.update_issue(key, fields: { "fixVersions" => merged_names.map { |n| { "name" => n } } })
      puts "#{key}: added #{added.join(', ')}"
      puts "         now: #{merged_names.join(', ')}"
    rescue JiraClient::AuthMissing, JiraClient::ConfigMissing, JiraClient::FetchFailed => e
      raise Thor::Error, e.message
    end

    no_commands do
      # Jira version names are usually `YYYY/MM/DD <Env>` or `1.2.3` style;
      # numeric segments first, then a tail string for stable secondary sort.
      def version_sort_key(name)
        nums = name.scan(/\d+/).map(&:to_i)
        [nums, name]
      end
    end

    desc "sentry-pull ISSUE_ID [ISSUE_ID ...]", "Capture one or more Sentry issues + their latest events into a session"
    long_desc <<-DESC
      Fetches each issue + its latest event and writes both a raw JSON bundle
      and a rendered Markdown summary into the session. The Markdown is what
      `sentry_debug` and other downstream workflows auto-include via
      `auto_inputs: [sentry_pull]`.

      ISSUE_ID can be the numeric Sentry id or a short id like 'MY-PROJ-AB'.
      Short ids resolve via /organizations/<org>/shortids/<id>/. Multiple ids
      can be passed in one call — each is captured into its own pair of files.

        aikiq sentry-pull BACKEND-AB --session 1234_x_y
        aikiq sentry-pull 134 135 136 --session XX-XXXX
        aikiq sentry-pull BACKEND-AB --session ... --label pre_close_evidence
        aikiq sentry-pull NOTIFIER-X --session ... --no-event
    DESC
    map "sentry-pull" => :sentry_pull
    option :session,  type: :string,  desc: "Session identifier (required)"
    option :org,      type: :string,  desc: "Sentry org slug (default: $SENTRY_ORG)"
    option :project,  type: :string,  desc: "Sentry project slug (default: $SENTRY_PROJECT)"
    option :label,    type: :string,  desc: "Optional label appended to filenames (e.g. pre_close_evidence)"
    option :no_event, type: :boolean, default: false, desc: "Skip the latest-event fetch (issue metadata only)"
    def sentry_pull(*issue_ids)
      raise Thor::Error, "at least one ISSUE_ID required (numeric or short id like 'MY-PROJ-AB')" if issue_ids.empty?
      require_session!

      client      = SentryClient.new(org: options[:org], project: options[:project])
      session_dir = File.join(Maciekos::PROJECT_ROOT, "sessions", options[:session])
      sentry_dir  = File.join(session_dir, "sentry")
      outputs_dir = File.join(session_dir, "outputs")
      FileUtils.mkdir_p(sentry_dir)
      FileUtils.mkdir_p(outputs_dir)

      label_suffix = options[:label] && !options[:label].empty? ? "_#{options[:label]}" : ""

      successes = []
      failures  = []

      issue_ids.each do |issue_id|
        begin
          issue = client.fetch_issue(issue_id)
          event = options[:no_event] ? nil : client.fetch_latest_event(issue_id)

          bundle = {
            "fetched_at"   => Time.now.utc.iso8601,
            "issue_id"     => issue_id,
            "short_id"     => issue["shortId"],
            "label"        => options[:label],
            "issue"        => issue,
            "latest_event" => event
          }

          short = issue["shortId"] || issue_id

          json_index = format("%03d", Dir[File.join(sentry_dir, "*.json")].count + 1)
          json_path  = File.join(sentry_dir, "#{json_index}_sentry_pull_#{short}#{label_suffix}.json")
          File.write(json_path, JSON.pretty_generate(bundle))

          md_index = format("%03d", Dir[File.join(outputs_dir, "*")].count + 1)
          md_path  = File.join(outputs_dir, "#{md_index}_sentry_pull_#{short}#{label_suffix}.md")
          File.write(md_path, render_sentry_pull(bundle))

          puts "Pulled #{short}: #{issue["title"]}"
          puts "  json:     #{json_path}"
          puts "  rendered: #{md_path}"
          successes << short
        rescue SentryClient::AuthMissing, SentryClient::ConfigMissing => e
          # Auth/config errors are global — abort the whole run, not just this id
          raise Thor::Error, e.message
        rescue SentryClient::FetchFailed => e
          STDERR.puts "Failed #{issue_id}: #{e.message}"
          failures << issue_id
        end
      end

      if issue_ids.length > 1
        puts ""
        puts "Pulled #{successes.length} of #{issue_ids.length} issue(s)."
        puts "Failed: #{failures.join(', ')}" unless failures.empty?
      end

      exit 1 unless failures.empty?
    end

    desc "task ACTION [ARGS...]", "Session-scoped tasks: add|done|reopen|note"
    long_desc <<-DESC
      Manage task entries attached to a session.

        aikiq task add    --session X "description"
        aikiq task done   --session X 3
        aikiq task reopen --session X 3
        aikiq task note   --session X 3 "blocked: waiting on Marek"
        aikiq task note   --session X 3                (empty → clear note)

      To delete a task, run `aikiq edit-log --session X` and remove the entry
      in your editor.
    DESC
    option :session, type: :string, desc: "Session identifier (required)"
    def task(action = nil, *args)
      require_session!
      raise Thor::Error, "task action required (add|done|reopen|note)" if action.nil?

      with_session_metadata(options[:session]) do |sm|
        case action
        when "add"
          description = args.join(" ").strip
          raise Thor::Error, "description required" if description.empty?
          entry = sm.add_task(description)
          puts "added task ##{entry['task_id']}"

        when "done"
          raise Thor::Error, "task_id required" if args.empty?
          tid = parse_task_id!(args.first)
          sm.complete_task(tid)
          puts "marked done: ##{tid}"

        when "reopen"
          raise Thor::Error, "task_id required" if args.empty?
          tid = parse_task_id!(args.first)
          sm.reopen_task(tid)
          puts "reopened: ##{tid}"

        when "note"
          raise Thor::Error, "task_id required" if args.empty?
          tid = parse_task_id!(args.first)
          text = args[1..].join(" ")
          sm.update_task_note(tid, text.empty? ? nil : text)
          puts (text.empty? ? "cleared note for ##{tid}" : "updated note for ##{tid}")

        else
          raise Thor::Error, "unknown task action '#{action}' (use add|done|reopen|note)"
        end
      end
    end

    desc "edit-log", "Open the session's session_log.json in $EDITOR; re-validate after save"
    map "edit-log" => :edit_log
    option :session, type: :string, desc: "Session identifier (required)"
    def edit_log
      require_session!
      sm = SessionMetadata.new(options[:session])
      raise Thor::Error, "session_log.json not found in session '#{options[:session]}'" unless sm.exists?

      editor = ENV["EDITOR"] || ENV["VISUAL"] || "vi"
      unless system(editor, sm.path)
        STDERR.puts "Warning: editor '#{editor}' exited non-zero."
      end

      begin
        sm.load
        puts "session_log.json is valid."
      rescue StandardError => e
        STDERR.puts "session_log.json is INVALID after edit:"
        STDERR.puts "  #{e.message}"
        STDERR.puts "File left as you saved it. Re-run `aikiq edit-log --session #{options[:session]}` to fix."
      end
    end

    desc "edit WORKFLOW", "Open the latest output file in $EDITOR; track the edit in session_log.json"
    option :session, type: :string, desc: "Session identifier (required)"
    def edit(workflow_id)
      require_session!
      session_path = File.join(Maciekos::PROJECT_ROOT, "sessions", options[:session], "outputs")
      raise Thor::Error, "Session directory not found: #{session_path}" unless Dir.exist?(session_path)

      files = Dir.glob(File.join(session_path, "*")).select do |filepath|
        File.basename(filepath) =~ /^\d+_#{Regexp.escape(workflow_id)}(\.|_)/
      end

      if files.empty?
        raise Thor::Error, "No output files for workflow '#{workflow_id}' in session '#{options[:session]}'"
      end

      latest_file = files.sort_by { |f| File.basename(f).split("_").first.to_i }.last
      basename    = File.basename(latest_file)

      editor = ENV["EDITOR"] || ENV["VISUAL"] || "vi"
      mtime_before = File.mtime(latest_file)
      unless system(editor, latest_file)
        STDERR.puts "Warning: editor '#{editor}' exited non-zero."
      end
      mtime_after = File.mtime(latest_file)

      if mtime_after <= mtime_before
        puts "No changes to #{basename}."
        return
      end

      sm = SessionMetadata.new(options[:session])
      unless sm.exists?
        STDERR.puts "Warning: session_log.json not found in session '#{options[:session]}'; edit not tracked."
        return
      end

      run = sm.load["runs"].find { |r| r["output_file_name"] == basename }
      unless run
        STDERR.puts "Warning: no run matches output_file_name #{basename.inspect}; edit not tracked."
        return
      end

      sm.mark_run_edited(run["run_id"])
      puts "Marked run_id=#{run['run_id']} edited (#{basename})."
    end

    desc "close", "Close an open session (status: open → closed)"
    option :session, type: :string, desc: "Session identifier (required)"
    def close
      require_session!
      with_session_metadata(options[:session]) do |sm|
        sm.close_session
        puts "Closed session '#{options[:session]}'."
      end
    end

    desc "archive", "Archive a closed session (status: closed → archived)"
    option :session, type: :string, desc: "Session identifier (required)"
    def archive
      require_session!
      with_session_metadata(options[:session]) do |sm|
        sm.archive_session
        puts "Archived session '#{options[:session]}'."
      end
    end

    desc "reassign", "Hand off an open session (status: open → reassigned)"
    long_desc <<-DESC
      Distinct from `aikiq close`. Use `reassign` when the work isn't done
      and you've handed the ticket to someone else (PM, dev) — the session
      is expected to come back when they bounce it. Daily shows the session
      with a "→" marker (vs "✓" for closed) so the handoff stays visible.

      `aikiq reopen --session X` reactivates a reassigned session WITHOUT
      requiring --force (the rewind isn't deliberate — it's just "they sent
      it back"). For closed/archived sessions, --force is still required.

      Stamps reassigned_at and reassigned_to in session_log.json. closed_at
      stays null — closed_at is reserved for actual completion.
    DESC
    option :session, type: :string, desc: "Session identifier (required)"
    option :to,      type: :string, desc: "Person the ticket was reassigned to (e.g. 'PM Lead')"
    def reassign
      require_session!
      with_session_metadata(options[:session]) do |sm|
        sm.reassign_session(reassigned_to: options[:to])
        target = options[:to] ? " to #{options[:to]}" : ""
        puts "Reassigned session '#{options[:session]}'#{target}."
      end
    end

    desc "reopen", "Reopen a session (closed/archived require --force; reassigned does not)"
    option :session, type: :string, desc: "Session identifier (required)"
    option :force, type: :boolean, default: false, desc: "Required for closed/archived; not required for reassigned"
    def reopen
      require_session!
      with_session_metadata(options[:session]) do |sm|
        begin
          sm.reopen_session(force: options[:force])
        rescue ArgumentError => e
          raise Thor::Error, e.message
        end
        puts "Reopened session '#{options[:session]}'."
      end
    end

    desc "daily", "One-line jog per session touched since the last standup"
    long_desc <<-DESC
      Walks session_logs and emits a copy-pasteable list to seed the standup
      monologue. One line per session: session id + (✓ if closed, → if
      reassigned, blank if open) + a one-line jog drawn from your own
      session note when set, otherwise from the latest jira_comment /
      jira_summary output.

      Default cutoff is the most recent standup-day strictly before now,
      configurable via env vars:
        AIKIQ_STANDUP_DAYS   comma-separated wday integers (default: "2,4")
        AIKIQ_STANDUP_HOUR   hour-of-day 0-23 (default: "10")
        AIKIQ_STANDUP_MIN    minutes-past-the-hour (default: "0")

      Override per-invocation with --since 24h / --since 7d, or
      --from "2026-04-30 10:00" for an exact datetime.
      --include-closed-days N keeps closed sessions visible for N days after
      their close (default 1) so you can mention them at the next standup.

        aikiq daily                                # since the last standup
        aikiq daily --since 24h                    # explicit 24h window
        aikiq daily --from "2026-04-30 10:00"      # exact cutoff
        aikiq daily --include-closed-days 0        # hide closed sessions
        aikiq daily --copy                         # pipe to xclip / pbcopy
    DESC
    option :since,                type: :string, desc: "Override cutoff (e.g. 24h, 3d). Bypasses Tue/Thu auto-detection"
    option :from,                 type: :string, desc: "Exact ISO datetime cutoff (e.g. '2026-04-30 10:00')"
    option :include_closed_days,  type: :numeric, default: 1, desc: "Keep closed sessions visible for N days after close (0 to hide)"
    option :copy,                 type: :boolean, default: false, desc: "Pipe output through xclip/pbcopy"
    def daily
      cutoff =
        if options[:from]
          Time.parse(options[:from])
        elsif options[:since]
          parse_duration_ago(options[:since])
        else
          last_daily_cutoff(Time.now)
        end

      sessions = collect_daily_sessions(cutoff: cutoff, closed_window_days: options[:include_closed_days])

      lines = []
      lines << "#{Time.now.strftime('%a %Y-%m-%d %H:%M')} — since #{cutoff.strftime('%a %Y-%m-%d %H:%M')}"
      lines << ""
      if sessions.empty?
        lines << "(no sessions touched since cutoff)"
      else
        # Fixed-width layout — no winsize sniffing. winsize was over-reporting
        # the user's actual visible width and lines wrapped at the terminal
        # edge despite the math saying they shouldn't. Constants tuned for the
        # user's full-screen terminal (~195-200 visible cols, 180 leaves
        # headroom).
        sid_width    = 25
        total_width  = 180
        prefix_width = sid_width + 4   # 1 marker + 1 space + sid pad + 2 spaces
        jog_max      = total_width - prefix_width
        sessions.each do |s|
          # Marker reflects current status:
          #   ✓ — closed or archived (work done)
          #   → — reassigned (handed off; expected to bounce back)
          #   ' ' — open
          # Sort already floats recently-terminal sessions to the top via
          # terminal_since_cutoff; the glyph just signals current state.
          marker =
            if %w[closed archived].include?(s[:status])
              "✓"
            elsif s[:status] == "reassigned"
              "→"
            else
              " "
            end
          sid = truncate_sid(s[:id], sid_width).ljust(sid_width)
          lines << "#{marker} #{sid}  #{truncate_jog(s[:jog], jog_max)}"
        end
      end

      out = lines.join("\n") + "\n"
      puts out

      if options[:copy]
        copied = pipe_to_clipboard(out)
        STDERR.puts copied ? "(copied to clipboard via #{copied})" : "(no clipboard utility found — install xclip or pbcopy)"
      end
    end

    desc "sync-status", "Reconcile every session's open/closed state against Jira (status + assignee)"
    long_desc <<-DESC
      Bidirectional sweep: for every open / closed / reassigned session
      (and archived with --include-archived), fetches `jira view DEV-XXX`
      and computes the desired aikiq status from three rules. First match
      wins:

        1. status in {Done, Ready For
           Staging, Ready For Production}  → desired = closed (shipped)
        2. assignee is NOT --self          → desired = reassigned
        3. otherwise                        → desired = open

      Transitions per (current → desired):
        open       → closed       : aikiq close
        open       → reassigned   : aikiq reassign --to <jira-assignee>
        closed     → open         : aikiq reopen --force
        reassigned → open         : aikiq reopen (no force; bounce-back)
        reassigned → closed       : aikiq close (shipped without return)

      Cancelled tickets are deliberately NOT auto-closed by status alone —
      they fall through rule 2 (assignee != self) into reassigned, or rule
      3 if assignee is still me.

      --self defaults to $AIKIQ_JIRA_ASSIGNEE_SELF or "Your Name".
      --include-archived also reopens archived sessions whose ticket
      bounced back to mine + active.

      Sessions without a recognised <PROJECT>-NNNN in the id are
      skipped. Jira fetch failures are reported and skipped — the
      rest of the sweep continues.

      Sequential `jira view` per session — same pattern as the close-sweep.
    DESC
    map "sync-status" => :sync_status
    option :include_archived, type: :boolean, default: false, desc: "Also check archived sessions for reopen"
    option :self, type: :string, desc: "Jira display name treated as 'me' (default: $AIKIQ_JIRA_ASSIGNEE_SELF or 'Your Name')"
    option :dry_run, type: :boolean, default: false, desc: "Show what would change without writing"
    def sync_status
      self_assignee = options[:self] || ENV["AIKIQ_JIRA_ASSIGNEE_SELF"] || "Your Name"
      done_set = ["done", "ready for staging", "ready for production"]

      # Sweep includes reassigned now (state machine handles all transitions):
      #   open       + shipped         → closed
      #   open       + assignee != me  → reassigned (auto-handoff mirror)
      #   closed     + back to me      → reopen --force
      #   reassigned + back to me      → reopen (no force; natural bounce)
      #   reassigned + shipped         → closed (didn't come back to me)
      #   reassigned + still elsewhere → keep as-is
      eligible_statuses = ["open", "closed", "reassigned"]
      eligible_statuses << "archived" if options[:include_archived]

      candidates = []
      Dir.glob(File.join(Maciekos::PROJECT_ROOT, "sessions", "*", "session_log.json")).sort.each do |path|
        data = JSON.parse(File.read(path))
        candidates << data if eligible_statuses.include?(data["status"])
      end

      if candidates.empty?
        puts "No sessions to sync."
        return
      end

      puts "Sweeping #{candidates.length} session(s) against self='#{self_assignee}'"
      closes     = []
      reopens    = []
      reassigns  = []
      kept       = []
      skipped    = []

      candidates.each_with_index do |session_data, i|
        sid     = session_data["session_id"]
        current = session_data["status"]

        m = sid.match(/\A(?:DEV-)?(\d{3,5})/)
        unless m
          skipped << { sid: sid, reason: "no DEV-XXXX in id" }
          next
        end
        ticket = "DEV-#{m[1]}"
        STDERR.puts "[#{i + 1}/#{candidates.length}] #{sid} (#{ticket}, currently #{current})"

        out, _err, st = Open3.capture3("jira", "view", ticket)
        unless st.success?
          skipped << { sid: sid, ticket: ticket, reason: "jira fetch failed (exit #{st.exitstatus})" }
          next
        end

        status   = (out =~ /^status:\s*(.+)$/)   ? $1.strip : "unknown"
        assignee = (out =~ /^assignee:\s*(.+)$/) ? $1.strip : "unknown"

        # Rule order (first match wins):
        #   1. shipped (Done/RFS/RFP)        → closed
        #   2. assignee != self              → reassigned
        #   3. otherwise (mine + active)     → open
        # Note: shipping wins over assignee — a ticket that landed Done +
        # got reassigned to someone for staging is still "done from my side".
        if done_set.include?(status.downcase)
          desired = "closed"
          reason  = "shipped (status=#{status})"
        elsif assignee != self_assignee
          desired = "reassigned"
          reason  = "assignee=#{assignee}"
        else
          desired = "open"
          reason  = "mine + active (status=#{status})"
        end

        record = { sid: sid, ticket: ticket, status: status, assignee: assignee, current: current, desired: desired, reason: reason }

        # Archived stays archived unless --include-archived flips it back;
        # we only ever transition archived → open, never to closed/reassigned.
        if current == "archived" && desired != "open"
          kept << record.merge(why: "archived; skipping non-reopen transition")
          next
        end

        if current == desired
          kept << record
          next
        end

        # Action dispatch per (current, desired). Returns nil for combos
        # that shouldn't trigger (e.g. closed → reassigned downgrade).
        action =
          case [current, desired]
          when ["open",       "closed"]      then :close
          when ["open",       "reassigned"]  then :reassign
          when ["closed",     "open"]        then :reopen_force
          when ["archived",   "open"]        then :reopen_force
          when ["reassigned", "open"]        then :reopen
          when ["reassigned", "closed"]      then :close
          end

        if action.nil?
          kept << record.merge(why: "no transition for #{current} → #{desired}")
          next
        end

        bucket =
          case action
          when :close, :close_from_reassigned then closes
          when :reassign                       then reassigns
          when :reopen, :reopen_force          then reopens
          end

        if options[:dry_run]
          bucket << record.merge(dry_run: true)
          next
        end

        begin
          sm = SessionMetadata.new(sid)
          case action
          when :close        then sm.close_session
          when :reassign     then sm.reassign_session(reassigned_to: assignee)
          when :reopen       then sm.reopen_session
          when :reopen_force then sm.reopen_session(force: true)
          end
          bucket << record
        rescue StandardError => e
          skipped << { sid: sid, ticket: ticket, reason: "#{action} failed: #{e.message}" }
        end
      end

      verb_close    = options[:dry_run] ? "would close"    : "closed"
      verb_reopen   = options[:dry_run] ? "would reopen"   : "reopened"
      verb_reassign = options[:dry_run] ? "would reassign" : "reassigned"

      puts ""
      puts "=== #{verb_close.capitalize} (#{closes.length}) ==="
      closes.each { |r| puts "  #{r[:sid].ljust(55)} #{r[:ticket]} #{r[:status].ljust(22)} (#{r[:reason]})" }

      puts ""
      puts "=== #{verb_reassign.capitalize} (#{reassigns.length}) ==="
      reassigns.each { |r| puts "  #{r[:sid].ljust(55)} #{r[:ticket]} #{r[:status].ljust(22)} (#{r[:reason]})" }

      puts ""
      puts "=== #{verb_reopen.capitalize} (#{reopens.length}) ==="
      reopens.each { |r| puts "  #{r[:sid].ljust(55)} #{r[:ticket]} #{r[:status].ljust(22)} (#{r[:reason]})" }

      puts ""
      puts "=== Kept as-is (#{kept.length}) ==="
      kept.each { |r| puts "  [#{r[:current].ljust(8)}] #{r[:sid].ljust(55)} #{r[:ticket]} #{r[:status].ljust(22)} (#{r[:reason]})" }

      unless skipped.empty?
        puts ""
        puts "=== Skipped (#{skipped.length}) ==="
        skipped.each { |r| puts "  #{r[:sid].ljust(55)} #{r[:ticket] || '?'} #{r[:reason]}" }
      end
    end

    desc "check ITEM [ITEM ...]", "Check off checklist item(s) for a session"
    long_desc <<-DESC
      Mark checklist item(s) for a session. Each ITEM is either KEY (boolean;
      sets to true) or KEY=VALUE (array item, or ISO8601 timestamp depending
      on the key's declared type). Arrays dedupe. Booleans can never be set
      to false via this command. For timestamp keys, KEY=now (or bare KEY)
      resolves to the current UTC time. Run `aikiq status --session <id>`
      to see the full checklist.
    DESC
    option :session, type: :string, desc: "Session identifier (required)"
    def check(*items)
      require_session!
      raise Thor::Error, "at least one ITEM required (see --help)" if items.empty?

      with_session_metadata(options[:session]) do |sm|
        items.each do |item|
          key, eq, value = item.partition("=")
          sm.update_checklist(key, eq.empty? ? nil : value)
          puts "checked: #{item}"
        end
      end
    end

    desc "verify [GATE_ID ...]", "Run gate(s) against the latest artifact in a session (no model call)"
    long_desc <<-DESC
      Re-runs Check classes against an existing artifact on disk. The model
      call has already happened — this only reads the JSON artifact and
      replays the gates. Useful when:

        - A gate failed under run_workflow and you've manually edited the
          artifact's selected response — verify it now passes.
        - A new gate has been added to the workflow YAML and you want to
          retroactively check older runs.
        - Audit trail: explicitly record a check_results row without
          re-spending tokens.

      Default: runs every gate listed in the workflow's vars.gates against
      the latest run for that workflow. Pass GATE_ID positionals to narrow
      to specific checks; pass --workflow to pick a specific workflow when
      the session has runs from several. Forced bypass uses the same
      --force-gate/--force-reason flags as run_workflow and writes an
      audited check_results row marked forced=true.

      Exits 0 if every check passed (or was forced); exits 1 if any check
      failed without a force.
    DESC
    option :session,      type: :string,                     desc: "Session identifier (required)"
    option :workflow,     type: :string,                     desc: "Workflow id (defaults to latest run's workflow)"
    option :force_gate,   type: :array,                      desc: "Bypass listed gate(s); same shape as run_workflow."
    option :force_reason, type: :string,                     desc: "Reason recorded with --force-gate bypass (audit log)"
    def verify(*gate_ids)
      require_session!
      session_id = options[:session]

      sm   = SessionMetadata.new(session_id)
      raise Thor::Error, "session '#{session_id}' has no session_log.json (run a workflow first)" unless sm.exists?
      data = sm.load
      runs = Array(data["runs"])
      raise Thor::Error, "session '#{session_id}' has no runs to verify" if runs.empty?

      target_run =
        if options[:workflow]
          last = runs.select { |r| r["workflow_id"] == options[:workflow] }.last
          raise Thor::Error, "no runs for workflow '#{options[:workflow]}' in session '#{session_id}'" unless last
          last
        else
          runs.last
        end

      workflow_id = target_run["workflow_id"]
      run_id      = target_run["run_id"]
      iteration   = target_run["workflow_iteration"]

      engine = WorkflowEngine.new
      wf     = engine.load_workflow(workflow_id)

      declared_gates = Array(wf.dig("vars", "gates"))
      requested      = gate_ids.empty? ? declared_gates : gate_ids
      if requested.empty?
        puts "No gates to run: workflow '#{workflow_id}' has no vars.gates and none specified on the command line."
        return
      end

      category    = workflow_id.split("_").first
      session_dir = File.join(Maciekos::PROJECT_ROOT, "sessions", session_id, category)
      raise Thor::Error, "artifact dir not found: #{session_dir}" unless Dir.exist?(session_dir)

      # Pair artifacts to runs by counting in-category position. The Nth
      # artifact in <category>/ corresponds to the Nth run with the same
      # category — workflow_iteration alone won't cut it because two
      # different workflows can share a category (e.g. jira_summary +
      # jira_comment both live under sessions/<id>/jira/).
      same_category_runs = runs.select { |r| r["workflow_id"].split("_").first == category }
      run_index_in_cat   = same_category_runs.index { |r| r["run_id"] == run_id }
      raise Thor::Error, "could not locate run #{run_id} within category '#{category}'" if run_index_in_cat.nil?

      artifact_files = Dir.glob(File.join(session_dir, "*_#{workflow_id}*.json")).sort_by do |p|
        File.basename(p).split("_").first.to_i
      end
      candidates = artifact_files.select do |p|
        File.basename(p) =~ /^\d+_#{Regexp.escape(workflow_id)}(\.|_)/
      end
      artifact_path = candidates.last
      raise Thor::Error, "no artifact for workflow '#{workflow_id}' in #{session_dir}" if artifact_path.nil?

      raw      = JSON.parse(File.read(artifact_path))
      selected = raw["selected"] # string-keyed; Schema#run handles both shapes

      forced_gates  = Array(options[:force_gate]).flat_map { |g| g.to_s.split(",") }.map(&:strip).reject(&:empty?)
      forced_reason = options[:force_reason]

      gate_context = {
        workflow:      wf,
        workflow_id:   workflow_id,
        selected:      selected,
        artifact_path: artifact_path,
        output_path:   nil,
        session_id:    session_id
      }

      puts "verify: session=#{session_id} run_id=#{run_id} workflow=#{workflow_id}##{iteration}"
      puts "        artifact=#{File.basename(artifact_path)}"
      puts "        gates=#{requested.join(', ')}"
      puts ""

      any_failed = false
      requested.each do |gate_id|
        check_class = Checks::Base.find(gate_id)
        unless check_class
          STDERR.puts "  [#{gate_id}] no Check class registered; skipping."
          next
        end
        check = check_class.new
        unless check.applies_to?(workflow_id)
          puts "  [#{gate_id}] N/A for workflow '#{workflow_id}'; skipping."
          next
        end

        gate_result = check.run(gate_context)
        forced      = forced_gates.include?(gate_id)

        sm.append_check_result(
          gate_result.to_h(
            run_id:       run_id,
            forced:       forced && !gate_result.passed,
            force_reason: (forced && !gate_result.passed) ? forced_reason : nil
          )
        )

        status =
          if gate_result.passed
            "PASS"
          elsif forced
            "FAIL (forced)"
          else
            any_failed = true
            "FAIL"
          end
        puts "  [#{gate_id}] #{status}"
        gate_result.messages.each { |m| puts "      #{m}" }
        puts "      reason: #{forced_reason || '<none>'}" if forced && !gate_result.passed
      end

      exit 1 if any_failed
    end

    desc "note [TEXT]", "Set (or clear) the session's free-text note"
    long_desc <<-DESC
      Sets the session's one-paragraph status note (cleared if TEXT is empty).
      The note must answer three things:
        1. what the ticket is about (mini Jira-title)
        2. what was concretely done — "asked PM about scope blocker" /
           "approved" — NOT meta-tooling like "posted a comment via workflow"
        3. reassigned to whom (skip if no reassignment)

      Content rules enforced at write time: 30-1000 chars, no tooling-meta
      phrases (via aikiq, _workflow, " shape ", first run, ...), at least one
      outcome verb (closed / verified / approved / asked / awaiting / ...).

      Bypass with --force --force-reason "<why>" — bypassed notes are recorded
      in note_force_reason and skipped by `aikiq daily` (consistent with the
      historical [auto skip).
    DESC
    option :session,      type: :string,                  desc: "Session identifier (required)"
    option :force,        type: :boolean, default: false, desc: "Bypass the note content linter"
    option :force_reason, type: :string,                  desc: "Required with --force; recorded in note_force_reason"
    def note(text = nil)
      require_session!
      with_session_metadata(options[:session]) do |sm|
        begin
          sm.update_note(text, force: options[:force], force_reason: options[:force_reason])
        rescue ArgumentError => e
          raise Thor::Error, e.message
        end
        if text.nil? || text.empty?
          puts "Cleared note for session '#{options[:session]}'."
        elsif options[:force]
          puts "Updated note for session '#{options[:session]}' (force-bypassed; reason: #{options[:force_reason]})."
        else
          puts "Updated note for session '#{options[:session]}'."
        end
      end
    end

    desc "activity", "Show recent file activity from sessions"
    option :since, type: :string, desc: "Starting date (last_week, YYYY-MM-DD)", default: "last_week"
    option :by_day, type: :boolean, desc: "Group by day", default: true
    option :by_session, type: :boolean, desc: "Group by session", default: false
    def activity
      start_date = parse_since_option(options[:since])
      files = collect_recent_files(start_date)

      if files.empty?
        puts "No activity found since #{format_date(start_date)}"
        return
      end

      display_activity(files, options[:by_day], options[:by_session])
    end

    desc "sessions", "List active sessions (closed/archived/reassigned hidden by default)"
    option :limit, type: :numeric, desc: "Limit to N most recent sessions"
    option :all,   type: :boolean, default: false, desc: "Also include closed, archived, and reassigned sessions"
    def sessions
      sessions_path = File.join(Maciekos::PROJECT_ROOT, "sessions")
      return puts "No sessions found" unless Dir.exist?(sessions_path)

      hide_inactive = !options[:all]

      sessions = Dir.glob(File.join(sessions_path, "*")).filter_map do |path|
        name   = File.basename(path)
        status = read_session_status(name)
        next if hide_inactive && %w[closed archived reassigned].include?(status)

        {
          name:        name,
          mtime:       File.mtime(path),
          files_count: Dir.glob(File.join(path, "outputs", "*.*")).count,
          status:      status
        }
      end

      sessions = sessions.sort_by { |s| s[:mtime] }.reverse
      sessions = sessions.take(options[:limit]) if options[:limit]

      sessions.each do |session|
        date  = session[:mtime].strftime("%d %b %H:%M")
        label = (session[:status] && session[:status] != "open") ? " [#{session[:status]}]" : ""
        puts "#{session[:name].ljust(30)} #{date} (#{session[:files_count]} files)#{label}"
      end
    end

    desc "install_completions", "Install zsh completion for aikiq"
    def install_completions
      target_dir  = File.expand_path("~/.zsh/completions")
      target_file = File.join(target_dir, "_aikiq")

      FileUtils.mkdir_p(target_dir)
      File.write(target_file, zsh_completion_script)

      puts "Completion script installed to: #{target_file}"
      puts "\nAdd to your ~/.zshrc (if not already):"
      puts "  fpath=(#{target_dir} $fpath)"
      puts "  autoload -Uz compinit && compinit"
      puts "\nThen reload:  exec zsh"
    end

    private

    def zsh_completion_script
      sessions_dir = File.join(Maciekos::PROJECT_ROOT, "sessions")
      <<~SCRIPT
        #compdef aikiq

        # Completions for aikiq. Scoped to --session (any session with a
        # session_log.json — open, closed, or archived; closed/archived
        # are still legitimate targets for `aikiq print`, `aikiq status`,
        # `aikiq verify`, etc.). Other arguments fall through to zsh's
        # native file completion.

        _aikiq_sessions() {
          local sessions_dir="#{sessions_dir}"
          local -a sessions
          local d log
          [[ -d $sessions_dir ]] || return

          for d in $sessions_dir/*(/N); do
            log="$d/session_log.json"
            [[ -f $log ]] && sessions+=(${d:t})
          done

          _describe -t sessions 'session' sessions
        }

        _aikiq() {
          _arguments -C \\
            '--session[session identifier]:session id:_aikiq_sessions' \\
            '--session=[session identifier]:session id:_aikiq_sessions' \\
            '*:file:_files'
        }

        _aikiq "$@"
      SCRIPT
    end

    def parse_since_option(since)
      case since.downcase
      when "last_week"
        Date.today - 7
      when "last_tuesday"
        last_weekday(:tuesday?)
      when "last_thursday"
        last_weekday(:thursday?)
      else
        begin
          Date.parse(since)
        rescue ArgumentError
          raise Thor::Error, "Invalid date format. Use YYYY-MM-DD or keywords: last_week, last_tuesday, last_thursday"
        end
      end
    end

    # "last Tuesday" when today IS Tuesday means the previous week's Tuesday,
    # not today. Always step back at least one day before the search.
    def last_weekday(predicate)
      date = Date.today - 1
      date -= 1 until date.send(predicate)
      date
    end

    def collect_recent_files(start_date)
      sessions_path = File.join(Maciekos::PROJECT_ROOT, "sessions")
      return [] unless Dir.exist?(sessions_path)

      cutoff  = start_date.to_time
      entries = []

      # File-level output events
      Dir.glob(File.join(sessions_path, "*", "outputs", "*.*")) do |file|
        stat = File.stat(file)
        next if stat.mtime < cutoff

        entries << {
          path:    file,
          name:    File.basename(file),
          session: file.split("/")[-3],
          mtime:   stat.mtime
        }
      end

      # Session lifecycle events derived from session_log.json. Archived is
      # only best-effort since we don't stamp an archive time separately — we
      # use last_activity_at which was bumped at archive time.
      Dir.glob(File.join(sessions_path, "*")).each do |session_path|
        next unless File.directory?(session_path)
        log_path = File.join(session_path, "session_log.json")
        next unless File.exist?(log_path)

        data = begin
          JSON.parse(File.read(log_path))
        rescue StandardError
          nil
        end
        next unless data.is_a?(Hash)

        session_id = File.basename(session_path)

        if data["status"] == "closed" && data["closed_at"].is_a?(String)
          t = iso8601_or_nil(data["closed_at"])
          entries << { path: nil, name: "[closed]", session: session_id, mtime: t } if t && t >= cutoff
        end

        if data["status"] == "archived" && data["last_activity_at"].is_a?(String)
          t = iso8601_or_nil(data["last_activity_at"])
          entries << { path: nil, name: "[archived]", session: session_id, mtime: t } if t && t >= cutoff
        end

        if data["note"].is_a?(String) && !data["note"].empty? && data["note_updated_at"].is_a?(String)
          t = iso8601_or_nil(data["note_updated_at"])
          if t && t >= cutoff
            entries << { path: nil, name: "[note] #{note_preview(data['note'])}", session: session_id, mtime: t }
          end
        end
      end

      entries.sort_by { |f| f[:mtime] }.reverse
    end

    def iso8601_or_nil(s)
      Time.iso8601(s)
    rescue ArgumentError, TypeError
      nil
    end

    def note_preview(text, limit = 80)
      one_line = text.to_s.gsub(/\s+/, " ").strip
      one_line.length > limit ? "#{one_line[0, limit - 1]}…" : one_line
    end

    def display_activity(files, by_day = true, by_session = false)
      if by_day && !by_session
        files.group_by { |f| f[:mtime].to_date }.each do |date, day_files|
          puts date.strftime("%A %d %b")
          day_files.group_by { |f| f[:session] }.each do |session, session_files|
            puts "  #{session}:"
            session_files.sort_by { |f| f[:mtime] }.reverse.each do |file|
              puts "    #{file[:mtime].strftime('%H:%M')}  #{file[:name]}"
            end
            puts
          end
        end
      elsif by_session
        files.group_by { |f| f[:session] }.each do |session, session_files|
          puts "#{session}:"
          session_files.group_by { |f| f[:mtime].to_date }.each do |date, day_files|
            puts "  #{date.strftime('%A %d %b')}"
            day_files.sort_by { |f| f[:mtime] }.reverse.each do |file|
              puts "    #{file[:mtime].strftime('%H:%M')}  #{file[:name]}"
            end
          end
          puts
        end
      else
        files.each do |file|
          puts "#{file[:mtime].strftime('%d %b %H:%M')}  #{file[:session]}/#{file[:name]}"
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
        file_paths.each_with_index { |f, i| puts "  #{i + 1}. #{File.basename(f)}" }
      end
      puts "\n" + "─" * 120 + "\n\n"

      selected = result[:selected] || result["selected"]

      if selected
        model = selected[:model] || selected["model"] || "unknown"
        content = selected.dig(:raw, "message", "content") || selected.dig("raw", "message", "content")

        if content
          content = try_parse_json(content)
          rendered = Renderers::OutputFormatter.format(
            workflow: File.basename(artifact_path, ".*"),
            content:  content
          )
          puts TTY::Markdown.parse(rendered, indent: 2, color: :never)
          puts "\n" + "Model: #{model}"
        else
          puts pastel.red("\nNo content found in response")
        end
      else
        evaluated = result[:evaluated] || result["evaluated"]
        if evaluated && evaluated.any?
          top = evaluated.max_by { |r| (r[:score] || r["score"]).to_f }
          content = top.dig(:raw, "message", "content") || top.dig("raw", "message", "content")

          if content
            content = try_parse_json(content)
            rendered = Renderers::OutputFormatter.format(
              workflow: File.basename(artifact_path, ".*"),
              content:  content
            )
            puts TTY::Markdown.parse(rendered, indent: 2, color: :never)
            puts "\n" + pastel.yellow("Model: #{top[:model] || top['model']} (score: #{top[:score] || top['score']})")
          end
        else
          puts pastel.red("\nNo usable response. Check artifact for details.")
        end
      end

      puts "\nOutput written to: #{output_path}" if output_path
      output_path
    end

    # Only returns true/false when the workflow declares a schema that actually
    # exists on disk (so "no schema" stays distinguishable from "failed").
    # Schema location matches Evaluator#validate_structure: vars.validators[0].schema.
    def derive_validation_passed(wf, result)
      schema_path = wf.dig("vars", "validators", 0, "schema")
      return nil unless schema_path && File.exist?(schema_path)

      selected = result[:selected] || result["selected"]
      return nil unless selected

      score = selected[:structure_score] || selected["structure_score"]
      return nil if score.nil?

      score == 1.0
    end


    def try_parse_json(content)
      return content unless content.is_a?(String)
      stripped = content.strip
      return content unless stripped.start_with?("{") && stripped.end_with?("}")
      JSON.parse(content)
    rescue JSON::ParserError
      content
    end

    def process_output(result, workflow_id)
      return nil unless result && (result[:selected] || result["selected"])

      OutputProcessor.new(
        workflow_id: workflow_id,
        session_id:  options[:session]
      ).process(result)
    end

    # Render the sentry-pull JSON bundle as a tight Markdown summary suitable
    # for downstream LLM workflows (sentry_debug, jira_summary, etc.). Pulls
    # only the high-signal pieces — issue metadata, top stack frames, last
    # breadcrumbs, tags, request URL — into a flat structure.
    def render_sentry_pull(bundle)
      issue = bundle["issue"] || {}
      event = bundle["latest_event"]
      lines = []

      present = lambda { |val| !val.to_s.strip.empty? }

      lines << "<!-- aikiq sentry-pull · fetched #{bundle["fetched_at"]} -->"
      lines << ""
      lines << "## Issue"
      lines << ""
      lines << "- **shortId**: #{issue["shortId"]}"   if present.call(issue["shortId"])
      lines << "- **id**: #{issue["id"]}"             if present.call(issue["id"])
      lines << "- **title**: #{issue["title"]}"       if present.call(issue["title"])
      lines << "- **culprit**: #{issue["culprit"]}"   if present.call(issue["culprit"])
      lines << "- **level**: #{issue["level"]}"       if present.call(issue["level"])
      lines << "- **status**: #{issue["status"]}"     if present.call(issue["status"])
      lines << "- **firstSeen**: #{issue["firstSeen"]}" if present.call(issue["firstSeen"])
      lines << "- **lastSeen**: #{issue["lastSeen"]}"   if present.call(issue["lastSeen"])
      lines << "- **count**: #{issue["count"]}"        if present.call(issue["count"])
      lines << "- **userCount**: #{issue["userCount"]}" if issue["userCount"].to_i > 0
      lines << "- **permalink**: #{issue["permalink"]}" if present.call(issue["permalink"])

      meta = issue["metadata"] || {}
      if meta["type"] || meta["value"]
        lines << "- **exception**: `#{meta["type"]}: #{meta["value"]}`"
      end

      if (assignee = issue["assignedTo"])
        name = assignee.is_a?(Hash) ? (assignee["name"] || assignee["email"]) : assignee
        lines << "- **assignedTo**: #{name}"
      end

      if event
        lines << ""
        lines << "## Latest event"
        lines << ""
        present  = lambda { |val| !val.to_s.strip.empty? }
        lines << "- **eventID**: #{event["eventID"]}"             if present.call(event["eventID"])
        lines << "- **dateCreated**: #{event["dateCreated"]}"     if present.call(event["dateCreated"])
        lines << "- **environment**: #{event["environment"]}"     if present.call(event["environment"])
        lines << "- **release**: #{event["release"]}"             if present.call(event["release"])
        lines << "- **platform**: #{event["platform"]}"           if present.call(event["platform"])

        entries = Array(event["entries"])
        exc_entry = entries.find { |e| e.is_a?(Hash) && e["type"] == "exception" }
        if exc_entry
          values = Array(exc_entry.dig("data", "values"))
          values.each do |v|
            lines << ""
            lines << "### Exception · #{v["type"]}"
            lines << ""
            lines << "> #{v["value"]}" if v["value"]
            frames = Array(v.dig("stacktrace", "frames")).last(8).reverse
            unless frames.empty?
              lines << ""
              lines << "Top stack frames (most-recent first):"
              frames.each do |f|
                fname = f["filename"] || f["module"] || "?"
                fn    = f["function"] || "?"
                ln    = f["lineNo"]
                lines << "- `#{fname}:#{ln}` in `#{fn}`#{f["inApp"] ? "" : " (lib)"}"
              end
            end
          end
        end

        bc_entry = entries.find { |e| e.is_a?(Hash) && e["type"] == "breadcrumbs" }
        if bc_entry
          values = Array(bc_entry.dig("data", "values")).last(10)
          unless values.empty?
            lines << ""
            lines << "### Breadcrumbs (last 10)"
            lines << ""
            values.each do |bc|
              ts  = bc["timestamp"]
              cat = bc["category"]
              msg = breadcrumb_message(bc)
              lines << "- `#{ts}` [#{cat}] #{msg}"
            end
          end
        end

        req_entry = entries.find { |e| e.is_a?(Hash) && e["type"] == "request" }
        if req_entry
          method = req_entry.dig("data", "method")
          url    = req_entry.dig("data", "url")
          if method || url
            lines << ""
            lines << "### Request"
            lines << ""
            lines << "- **#{method}** #{url}"
          end
        end

        tags = Array(event["tags"])
        unless tags.empty?
          lines << ""
          lines << "### Tags"
          lines << ""
          tags.first(20).each { |t| lines << "- `#{t["key"]}`: #{t["value"]}" }
        end
      end

      lines.join("\n") + "\n"
    end

    # Render a session_log payload as Markdown for `aikiq status`.
    def format_session_status(data, show_done_tasks: false)
      lines = []
      lines << "# Session `#{data['session_id']}`"
      lines << ""
      lines << "- **Status:** #{data['status']}"
      lines << "- **Created:** #{data['created_at']}"
      lines << "- **Closed:** #{data['closed_at']}" if data["closed_at"]
      lines << "- **Last activity:** #{data['last_activity_at']}"
      lines << ""

      lines << "## Tasks"
      lines << ""
      all_tasks     = data["tasks"] || []
      visible_tasks = show_done_tasks ? all_tasks : all_tasks.reject { |t| t["status"] == "done" }
      if visible_tasks.empty?
        lines << (all_tasks.empty? ? "_No tasks._" : "_No pending tasks. Use --all to see done._")
      else
        visible_tasks.each { |t| lines << format_task_line(t) }
      end
      lines << ""

      if data["note"] && !data["note"].empty?
        lines << "## Note"
        lines << ""
        lines << data["note"]
        lines << ""
      end

      lines << "## Runs"
      lines << ""
      if data["runs"].empty?
        lines << "_No runs yet._"
      else
        lines << "| # | workflow | iter | output | validated | created | edited |"
        lines << "|---|----------|------|--------|-----------|---------|--------|"
        data["runs"].each do |r|
          lines << "| #{r['run_id']} | #{r['workflow_id']} | #{r['workflow_iteration']} | " \
                   "#{r['output_file_name'] || '—'} | #{format_validated(r['validation_passed'])} | " \
                   "#{r['created_at']} | #{r['edited_at'] || '—'} |"
        end
      end
      lines << ""

      lines << "## Checklist"
      lines << ""
      data["checklist"].each { |key, entry| lines << format_checklist_line(key, entry) }

      lines.join("\n")
    end

    def format_task_line(task)
      marker    = task["status"] == "done" ? "✓" : "☐"
      completed = task["completed_at"] ? "  _(done #{task['completed_at']})_" : ""
      line      = "- #{marker} **##{task['task_id']}** #{task['description']}#{completed}"
      if task["note"] && !task["note"].empty?
        line << "  \n    > #{task['note']}"
      end
      line
    end

    def parse_task_id!(raw)
      Integer(raw.to_s)
    rescue ArgumentError, TypeError
      raise Thor::Error, "task_id must be an integer (got #{raw.inspect})"
    end

    def format_validated(v)
      case v
      when true  then "✓"
      when false then "✗"
      else            "—"
      end
    end

    def format_checklist_line(key, entry)
      val      = entry["value"]
      when_str = entry["checked_at"] ? "  _(#{entry['checked_at']})_" : ""

      case val
      when true
        "- ✓ **#{key}**#{when_str}"
      when false
        "- ☐ **#{key}**"
      when Array
        val.empty? ? "- ☐ **#{key}**" : "- ✓ **#{key}**: #{val.join(', ')}#{when_str}"
      when String
        "- ✓ **#{key}**: `#{val}`#{when_str}"
      when nil
        "- ☐ **#{key}**"
      else
        "- ? **#{key}**: `#{val.inspect}`"
      end
    end

    # Thor's `required: true` on --session also fires for --help, which is why
    # we check manually at runtime instead. Keeps `aikiq <cmd> --help` usable.
    def require_session!
      return if options[:session] && !options[:session].empty?
      raise Thor::Error, "--session is required (see --help)"
    end

    # Returns the session's status ("open" / "closed" / "archived"), or nil
    # when there's no session_log.json yet or the file cannot be loaded.
    # Swallowing corruption here is deliberate: the sessions list must not
    # crash because a single session has a broken log.
    def read_session_status(session_id)
      sm = SessionMetadata.new(session_id)
      return nil unless sm.exists?
      sm.load["status"]
    rescue StandardError
      nil
    end

    # Loads SessionMetadata for the given session, yields it to the block, and
    # converts SessionMetadata domain errors (ArgumentError, RuntimeError) into
    # Thor::Error so users see clean one-line messages instead of backtraces.
    def with_session_metadata(session_id)
      sm = SessionMetadata.new(session_id)
      raise Thor::Error, "session_log.json not found in session '#{session_id}'" unless sm.exists?
      yield sm
    rescue ArgumentError, RuntimeError => e
      raise Thor::Error, e.message
    end

    def resolve_latest_output(session_id, workflow_id)
      session_path = File.join(Maciekos::PROJECT_ROOT, "sessions", session_id, "outputs")
      return nil unless Dir.exist?(session_path)

      patterns = [
        File.join(session_path, "*_#{workflow_id}.md"),
        File.join(session_path, "*_#{workflow_id}.csv")
      ]

      files = patterns.flat_map { |p| Dir.glob(p) }.sort_by do |filename|
        File.basename(filename).split("_").first.to_i
      end

      files.last
    end
  end
end

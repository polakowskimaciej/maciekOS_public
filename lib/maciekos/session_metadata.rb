# lib/maciekos/session_metadata.rb
require "json"
require "fileutils"
require "time"
require "securerandom"

module Maciekos
  # Manages sessions/<session_id>/session_log.json.
  #
  # Phase 1 scope: skeleton only.
  #   - create_if_missing / load / validate_structure / atomic_write
  #   - no run, checklist-update, or status-transition logic yet
  #
  # Invariants:
  #   - Lazy: nothing touches disk until a method that needs to is called.
  #   - Writes go through a tmp-file + rename (atomic on POSIX same-fs).
  #   - Validation runs before every write; corrupt payloads abort, never auto-repair.
  class SessionMetadata
    FILE_NAME = "session_log.json"

    VALID_STATUSES = %w[open closed archived reassigned].freeze

    # Locked schema: typed checklist keys with their empty-state defaults.
    # :boolean   — toggled to true via `update_checklist(key)`; never auto-set false.
    # :array     — `update_checklist(key, value)` appends (deduped).
    # :timestamp — `update_checklist(key, iso8601_string)` sets.
    CHECKLIST_SCHEMA = {
      "backend_branch_merged"           => { type: :boolean,   default: false },
      "deployed_to"                     => { type: :array,     default: [] },
      "backend_tests_run"                => { type: :boolean,   default: false },
      "jira_closing_comment_added"      => { type: :boolean,   default: false },
      "fix_versions_added"              => { type: :boolean,   default: false },
      "ticket_transitioned_to_stage_it" => { type: :boolean,   default: false },
      "last_default_merge_at"           => { type: :timestamp, default: nil }
    }.freeze

    CHECKLIST_DEFAULTS = CHECKLIST_SCHEMA.transform_values { |v| v[:default] }.freeze

    TOP_LEVEL_KEYS = %w[
      session_id status created_at closed_at last_activity_at note checklist runs
    ].freeze

    # "tasks" was added after the initial locked schema. It's tolerated as
    # missing on load (old sessions keep working) but included in every
    # default_payload and persisted on first write. "note_updated_at" is the
    # same story — stamped by update_note so activity can surface notes.
    OPTIONAL_TOP_LEVEL_KEYS = %w[tasks note_updated_at note_force_reason playbook_loads jira_snapshot check_results reassigned_at reassigned_to].freeze

    # Note content linter — rejects tooling-meta notes at write time.
    # See plan: /home/maciej/.claude/plans/audit-the-workflows-based-lexical-papert.md
    NOTE_LENGTH_FLOOR   = 30
    NOTE_LENGTH_CEILING = 1000

    # Hard error if any phrase appears (case-insensitive substring).
    NOTE_DISALLOWED_PHRASES = [
      "via aikiq",
      "via the workflow",
      "via jira_comment",
      "via jira_summary",
      "_workflow ",
      "first run",
      " shape ",
      "since adding",
      "after adding",
      "posted a comment"
    ].freeze

    # Hard error if no outcome verb is present. Tuned against the live corpus
    # to give 100% pass on existing legitimate notes.
    NOTE_VERB_RE = /\b(closed|verified|approved|refined|reassigned|handed back|transitioned|merged|asked|drafted|deferred|blocked|rolled back|attached|logged|estimated|signed off|done|added|removed|updated|investigated|fixed|posted|set|extracted|wrote|reviewed|landed|shipped|deployed|delivered|implemented|noted|committed|opened|reopened|gated|recorded|paused|resumed|applied|resolved|awaiting|waiting|pending|routed|published|created|abandoned|halted|on hold|signed|spiked|fetched|caught up|completed|cancelled|canceled|skipped)\b/i

    # Soft warning (stderr, no fail) — statistically meta but not always wrong.
    NOTE_SOFT_WARN_PHRASES = ["workflow", "aikiq", "comment posted", "re-run"].freeze

    RUN_REQUIRED_KEYS = %w[
      run_id workflow_id workflow_iteration output_file_name validation_passed created_at edited_at
    ].freeze

    TASK_REQUIRED_KEYS = %w[
      task_id description status created_at completed_at note
    ].freeze

    PLAYBOOK_LOAD_REQUIRED_KEYS = %w[names loaded_at why].freeze

    JIRA_SNAPSHOT_REQUIRED_KEYS = %w[
      ticket_key content_sha256 byte_size captured_at captured_by
    ].freeze

    CHECK_RESULT_REQUIRED_KEYS = %w[
      run_id check_id passed tier messages_truncated checked_at forced force_reason
    ].freeze

    CHECK_RESULT_VALID_TIERS = %w[fast network].freeze

    VALID_TASK_STATUSES = %w[pending done].freeze

    attr_reader :session_id

    def initialize(session_id, project_root: nil)
      raise ArgumentError, "session_id required" if session_id.nil? || session_id.to_s.empty?
      @session_id   = session_id.to_s
      @project_root = project_root
    end

    def path
      @path ||= File.join(resolved_project_root, "sessions", @session_id, FILE_NAME)
    end

    def exists?
      File.exist?(path)
    end

    # Create the session_log.json if it does not exist yet.
    # Returns the payload either way (newly created or already on disk).
    def create_if_missing
      return load if exists?
      data = default_payload
      atomic_write(data)
      data
    end

    # Read + validate. Raises if the file is missing or the structure is invalid.
    def load
      raise "session_log not found: #{path}" unless exists?
      data = JSON.parse(File.read(path))
      validate_structure(data)
      data
    end

    # Validate the full locked schema. Raises on the first violation.
    # Never repairs. Returns true on success.
    def validate_structure(data)
      raise "session_log corrupt: not a Hash (got #{data.class})" unless data.is_a?(Hash)

      missing = TOP_LEVEL_KEYS - data.keys
      raise "session_log corrupt: missing top-level keys: #{missing.join(', ')}" if missing.any?

      unless data["session_id"] == @session_id
        raise "session_log corrupt: session_id mismatch " \
              "(expected #{@session_id.inspect}, got #{data['session_id'].inspect})"
      end

      unless VALID_STATUSES.include?(data["status"])
        raise "session_log corrupt: invalid status #{data['status'].inspect}"
      end

      %w[created_at last_activity_at].each do |k|
        unless data[k].is_a?(String) && !data[k].empty?
          raise "session_log corrupt: #{k} must be a non-empty String"
        end
      end

      unless data["closed_at"].nil? || data["closed_at"].is_a?(String)
        raise "session_log corrupt: closed_at must be String or null"
      end

      if data.key?("reassigned_at") && !(data["reassigned_at"].nil? || data["reassigned_at"].is_a?(String))
        raise "session_log corrupt: reassigned_at must be String or null"
      end

      if data.key?("reassigned_to") && !(data["reassigned_to"].nil? || data["reassigned_to"].is_a?(String))
        raise "session_log corrupt: reassigned_to must be String or null"
      end

      unless data["note"].nil? || data["note"].is_a?(String)
        raise "session_log corrupt: note must be String or null"
      end

      if data.key?("note_updated_at") && !(data["note_updated_at"].nil? || data["note_updated_at"].is_a?(String))
        raise "session_log corrupt: note_updated_at must be String or null"
      end

      if data.key?("note_force_reason") && !(data["note_force_reason"].nil? || data["note_force_reason"].is_a?(String))
        raise "session_log corrupt: note_force_reason must be String or null"
      end

      validate_checklist(data["checklist"])
      validate_runs(data["runs"])
      validate_tasks(data["tasks"]) if data.key?("tasks")
      validate_playbook_loads(data["playbook_loads"]) if data.key?("playbook_loads")
      validate_jira_snapshot(data["jira_snapshot"]) if data.key?("jira_snapshot")
      validate_check_results(data["check_results"]) if data.key?("check_results")

      true
    end

    # Replace the jira_snapshot record. There is at most one snapshot per
    # session — newer captures overwrite older. Use `aikiq snapshot --check`
    # against a prior commit to inspect history.
    def set_jira_snapshot(snap)
      raise ArgumentError, "snap must be a Hash" unless snap.is_a?(Hash)

      data = load
      data["jira_snapshot"] = {
        "ticket_key"     => snap["ticket_key"].to_s,
        "content_sha256" => snap["content_sha256"].to_s,
        "byte_size"      => snap["byte_size"].to_i,
        "captured_at"    => snap["captured_at"].to_s,
        "captured_by"    => snap["captured_by"].to_s
      }
      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      data["jira_snapshot"]
    end

    # Record a playbook load. Stores names + timestamp + optional reason.
    # The bundle body is intentionally NOT stored — just metadata.
    def log_playbook_load(names, why: nil)
      raise ArgumentError, "names must be a non-empty Array of Strings" unless names.is_a?(Array) && names.all? { |n| n.is_a?(String) && !n.empty? }
      raise ArgumentError, "why must be String or nil" unless why.nil? || why.is_a?(String)

      data = load
      data["playbook_loads"] ||= []
      now = iso8601_now

      entry = {
        "names"     => names.dup,
        "loaded_at" => now,
        "why"       => (why.nil? || why.empty?) ? nil : why
      }
      data["playbook_loads"] << entry
      data["last_activity_at"] = now

      atomic_write(data)
      entry
    end

    # Highest existing run_id + 1, or 1 if no runs yet.
    def next_run_id
      next_run_id_from(load["runs"])
    end

    # Count of existing runs for this workflow_id + 1.
    def next_workflow_iteration(workflow_id)
      next_workflow_iteration_from(load["runs"], workflow_id)
    end

    # Append a new run entry with null output fields, bump last_activity_at,
    # atomic write. Returns the appended run hash (with its assigned run_id).
    def append_run(workflow_id)
      raise ArgumentError, "workflow_id required" if workflow_id.nil? || workflow_id.to_s.empty?

      data = load
      now  = iso8601_now

      run = {
        "run_id"             => next_run_id_from(data["runs"]),
        "workflow_id"        => workflow_id.to_s,
        "workflow_iteration" => next_workflow_iteration_from(data["runs"], workflow_id),
        "output_file_name"   => nil,
        "validation_passed"  => nil,
        "created_at"         => now,
        "edited_at"          => nil
      }

      data["runs"] << run
      data["last_activity_at"] = now

      atomic_write(data)
      run
    end

    # Update an existing run's output_file_name and validation_passed fields,
    # bump last_activity_at, atomic write. Never creates a new run.
    # Raises if run_id is not present in the session log.
    def finalize_run(run_id, output_file_name, validation_passed)
      raise ArgumentError, "run_id must be Integer" unless run_id.is_a?(Integer)

      unless output_file_name.nil? || output_file_name.is_a?(String)
        raise ArgumentError, "output_file_name must be String or nil"
      end

      unless [true, false, nil].include?(validation_passed)
        raise ArgumentError, "validation_passed must be true, false, or nil"
      end

      data = load
      run  = data["runs"].find { |r| r["run_id"] == run_id }
      raise "run_id #{run_id} not found in session #{@session_id}" if run.nil?

      run["output_file_name"]  = output_file_name
      run["validation_passed"] = validation_passed

      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      run
    end

    # Append a check result row. The runner inside `aikiq run_workflow`
    # (and the standalone `aikiq check` subcommand) calls this once per
    # gate that fired against the run. Rows are persistent so audit trails
    # — especially forced bypasses — survive across sessions.
    #
    # `result_hash` shape comes from Maciekos::Checks::Result#to_h:
    #   { run_id, check_id, passed, tier, messages_truncated, checked_at, forced, force_reason }
    def append_check_result(result_hash)
      raise ArgumentError, "result_hash must be a Hash" unless result_hash.is_a?(Hash)

      data = load
      data["check_results"] ||= []
      entry = {
        "run_id"             => result_hash["run_id"].to_i,
        "check_id"           => result_hash["check_id"].to_s,
        "passed"             => !!result_hash["passed"],
        "tier"               => result_hash["tier"].to_s,
        "messages_truncated" => result_hash["messages_truncated"].to_s[0, 500],
        "checked_at"         => result_hash["checked_at"].to_s,
        "forced"             => !!result_hash["forced"],
        "force_reason"       => result_hash["force_reason"].nil? || result_hash["force_reason"].to_s.empty? ? nil : result_hash["force_reason"].to_s
      }
      data["check_results"] << entry
      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      entry
    end

    # Stamp a run with the SHA256 of the `jira view` output it was drafted
    # against. Lets `aikiq status` / drift audits trace each run back to a
    # concrete ticket state, even after the top-level jira_snapshot has been
    # overwritten by later runs.
    def set_run_jira_snapshot_sha(run_id, sha)
      raise ArgumentError, "run_id must be Integer" unless run_id.is_a?(Integer)
      raise ArgumentError, "sha must be 64-char hex String" unless sha.is_a?(String) && sha.length == 64

      data = load
      run  = data["runs"].find { |r| r["run_id"] == run_id }
      raise "run_id #{run_id} not found in session #{@session_id}" if run.nil?

      run["jira_snapshot_sha"] = sha
      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      run
    end

    # Record that an existing run's output file was edited by the user.
    # Updates only edited_at (on the run) + last_activity_at (top-level).
    # Never creates a run, never touches other fields.
    def mark_run_edited(run_id)
      raise ArgumentError, "run_id must be Integer" unless run_id.is_a?(Integer)

      data = load
      run  = data["runs"].find { |r| r["run_id"] == run_id }
      raise "run_id #{run_id} not found in session #{@session_id}" if run.nil?

      now = iso8601_now
      run["edited_at"]         = now
      data["last_activity_at"] = now

      atomic_write(data)
      run
    end

    # Status transition: open|reassigned → closed. Stamps closed_at +
    # last_activity_at. Closing from reassigned is the "shipped without
    # bouncing back to me" path (sync-status detects status=Done/RFS/RFP
    # while still assigned to someone else and rolls the aikiq session
    # forward to closed). Clears reassigned_at + reassigned_to.
    def close_session
      data = load
      unless %w[open reassigned].include?(data["status"])
        raise "cannot close: session is '#{data['status']}', expected 'open' or 'reassigned'"
      end

      now = iso8601_now
      data["status"]           = "closed"
      data["closed_at"]        = now
      data["reassigned_at"]    = nil
      data["reassigned_to"]    = nil
      data["last_activity_at"] = now

      atomic_write(data)
      data
    end

    # Status transition: open → reassigned. Distinct from `closed` because
    # the work isn't done — the session has been handed off and is expected
    # to come back. Stamps reassigned_at + reassigned_to (optional). Does
    # NOT touch closed_at — that's reserved for actual completion.
    def reassign_session(reassigned_to: nil)
      data = load
      unless data["status"] == "open"
        raise "cannot reassign: session is '#{data['status']}', expected 'open'"
      end

      now = iso8601_now
      data["status"]           = "reassigned"
      data["reassigned_at"]    = now
      data["reassigned_to"]    = (reassigned_to.nil? || reassigned_to.to_s.strip.empty?) ? nil : reassigned_to.to_s
      data["last_activity_at"] = now

      atomic_write(data)
      data
    end

    # Status transition: closed → archived. Preserves closed_at. Bumps last_activity_at.
    def archive_session
      data = load
      unless data["status"] == "closed"
        raise "cannot archive: session is '#{data['status']}', expected 'closed'"
      end

      data["status"]           = "archived"
      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      data
    end

    # Status transition: closed|archived|reassigned → open. Requires force:
    # true for closed|archived (deliberate rewind of completed work). For
    # reassigned, force is NOT required — the session is expected to return
    # naturally when the assignee bounces back. Clears closed_at,
    # reassigned_at, reassigned_to.
    def reopen_session(force: false)
      data = load
      if data["status"] == "open"
        raise "cannot reopen: session is already open"
      end

      unless data["status"] == "reassigned" || force == true
        raise ArgumentError, "reopen of #{data['status']} session requires force: true"
      end

      data["status"]           = "open"
      data["closed_at"]        = nil
      data["reassigned_at"]    = nil
      data["reassigned_to"]    = nil
      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      data
    end

    # Update a checklist item according to its declared type.
    # Never auto-sets a boolean to false: booleans can only be toggled on.
    # Returns the updated {value, checked_at} entry.
    def update_checklist(key, value = nil)
      schema = CHECKLIST_SCHEMA[key]
      raise ArgumentError, "unknown checklist key: #{key.inspect}" if schema.nil?

      data  = load
      entry = data["checklist"][key]
      now   = iso8601_now

      case schema[:type]
      when :boolean
        raise ArgumentError, "checklist key '#{key}' takes no value" unless value.nil?
        entry["value"] = true

      when :array
        raise ArgumentError, "checklist key '#{key}' requires a value" if value.nil? || value.to_s.empty?
        str = value.to_s
        entry["value"] = Array(entry["value"])
        entry["value"] << str unless entry["value"].include?(str)

      when :timestamp
        # Nil, empty, or the literal "now" (case-insensitive) → current UTC
        # ISO8601. Saves callers from having to shell out to `date -u`.
        resolved =
          if value.nil? || value.to_s.empty? || value.to_s.downcase == "now"
            iso8601_now
          else
            begin
              Time.iso8601(value.to_s)
            rescue ArgumentError
              raise ArgumentError, "invalid ISO8601 timestamp for '#{key}': #{value.inspect}"
            end
            value.to_s
          end
        entry["value"] = resolved
      end

      entry["checked_at"]      = now
      data["last_activity_at"] = now

      atomic_write(data)
      entry
    end

    # Append a new pending task. Returns the inserted entry (with task_id).
    def add_task(description)
      desc = description.to_s.strip
      raise ArgumentError, "task description required" if desc.empty?

      data = load
      data["tasks"] ||= []
      now = iso8601_now

      entry = {
        "task_id"      => next_task_id_from(data["tasks"]),
        "description"  => desc,
        "status"       => "pending",
        "created_at"   => now,
        "completed_at" => nil,
        "note"         => nil
      }

      data["tasks"] << entry
      data["last_activity_at"] = now

      atomic_write(data)
      entry
    end

    # Mark an existing pending task done. Stamps completed_at + last_activity_at.
    def complete_task(task_id)
      raise ArgumentError, "task_id must be Integer" unless task_id.is_a?(Integer)

      data = load
      data["tasks"] ||= []
      task = data["tasks"].find { |t| t["task_id"] == task_id }
      raise "task_id #{task_id} not found in session #{@session_id}" if task.nil?

      now = iso8601_now
      task["status"]          = "done"
      task["completed_at"]    = now
      data["last_activity_at"] = now

      atomic_write(data)
      task
    end

    # Revert a done task back to pending. Clears completed_at.
    def reopen_task(task_id)
      raise ArgumentError, "task_id must be Integer" unless task_id.is_a?(Integer)

      data = load
      data["tasks"] ||= []
      task = data["tasks"].find { |t| t["task_id"] == task_id }
      raise "task_id #{task_id} not found in session #{@session_id}" if task.nil?

      now = iso8601_now
      task["status"]           = "pending"
      task["completed_at"]     = nil
      data["last_activity_at"] = now

      atomic_write(data)
      task
    end

    # Attach or clear the free-text note on a task. Empty string → nil.
    def update_task_note(task_id, text)
      raise ArgumentError, "task_id must be Integer" unless task_id.is_a?(Integer)
      raise ArgumentError, "note must be String or nil" unless text.nil? || text.is_a?(String)

      data = load
      data["tasks"] ||= []
      task = data["tasks"].find { |t| t["task_id"] == task_id }
      raise "task_id #{task_id} not found in session #{@session_id}" if task.nil?

      task["note"]             = (text.nil? || text.empty?) ? nil : text
      data["last_activity_at"] = iso8601_now

      atomic_write(data)
      task
    end

    # Set or clear the free-text note. Empty string is normalized to nil.
    # Stamps note_updated_at whenever the note is set; clears it when cleared.
    #
    # Notes are content-linted via validate_note_content! unless force: true.
    # Forced writes record the reason in data["note_force_reason"] for audit
    # and so the daily jog can skip them (force-bypassed notes are explicitly
    # marked low-quality and shouldn't headline the standup line).
    def update_note(text, force: false, force_reason: nil)
      raise ArgumentError, "note must be String or nil" unless text.nil? || text.is_a?(String)

      data = load
      now  = iso8601_now
      cleared = text.nil? || text.empty?

      unless cleared || force
        validate_note_content!(text)
      end

      if force && !cleared
        if force_reason.nil? || force_reason.to_s.strip.empty?
          raise ArgumentError, "force: true requires a non-empty force_reason"
        end
      end

      data["note"]              = cleared ? nil : text
      data["note_updated_at"]   = cleared ? nil : now
      data["note_force_reason"] = (force && !cleared) ? force_reason.to_s : nil
      data["last_activity_at"]  = now

      atomic_write(data)
      data
    end

    # Atomic write: validate → tmp file → rename. Cleans up the tmp file on failure.
    def atomic_write(data)
      validate_structure(data)

      FileUtils.mkdir_p(File.dirname(path))

      tmp_path = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      begin
        File.write(tmp_path, JSON.pretty_generate(data))
        File.rename(tmp_path, path)
      rescue
        File.delete(tmp_path) if File.exist?(tmp_path)
        raise
      end

      data
    end

    private

    def resolved_project_root
      @project_root || Maciekos::PROJECT_ROOT
    end

    # Content linter for notes. Hard-error rules in order; first failure
    # raises ArgumentError with a message naming the rule + the matched
    # phrase + a remediation hint. Soft warnings go to stderr without
    # raising. Bypass via update_note(text, force: true, force_reason: "...").
    def validate_note_content!(text)
      flat = text.to_s.strip

      if flat.length < NOTE_LENGTH_FLOOR
        raise ArgumentError,
              "note too short (#{flat.length} chars; min #{NOTE_LENGTH_FLOOR}). " \
              "Say what the ticket is about + what you concretely did."
      end

      if flat.length > NOTE_LENGTH_CEILING
        raise ArgumentError,
              "note too long (#{flat.length} chars; max #{NOTE_LENGTH_CEILING}). " \
              "Move dump-style detail into sessions/<id>/dump/<topic>.md and keep the note tight."
      end

      if flat.start_with?("[auto")
        raise ArgumentError,
              "note must not start with [auto — that prefix is reserved for the historical " \
              "jira_summary backfill sweep and is filtered from the daily jog."
      end

      lowered = flat.downcase
      NOTE_DISALLOWED_PHRASES.each do |phrase|
        next unless lowered.include?(phrase.downcase)
        raise ArgumentError,
              "note contains disallowed phrase #{phrase.inspect} — drop tooling/workflow " \
              "meta-references and describe ticket state instead. " \
              "If you really need to write this, pass --force --force-reason '<why>'."
      end

      unless flat =~ NOTE_VERB_RE
        raise ArgumentError,
              "note has no outcome verb (closed/verified/approved/refined/asked/awaiting/...). " \
              "Say what concretely happened, not just context. " \
              "If this is intentional, pass --force --force-reason '<why>'."
      end

      NOTE_SOFT_WARN_PHRASES.each do |phrase|
        if lowered.include?(phrase.downcase)
          warn "note: soft warning — contains #{phrase.inspect}; consider rewriting to drop it (not blocking)."
        end
      end

      true
    end

    def validate_checklist(checklist)
      raise "session_log corrupt: checklist must be a Hash" unless checklist.is_a?(Hash)

      missing = CHECKLIST_DEFAULTS.keys - checklist.keys
      raise "session_log corrupt: checklist missing keys: #{missing.join(', ')}" if missing.any?

      CHECKLIST_DEFAULTS.each_key do |key|
        entry = checklist[key]
        raise "session_log corrupt: checklist[#{key}] must be a Hash" unless entry.is_a?(Hash)
        unless entry.key?("value") && entry.key?("checked_at")
          raise "session_log corrupt: checklist[#{key}] missing 'value' or 'checked_at'"
        end
      end
    end

    def validate_runs(runs)
      raise "session_log corrupt: runs must be an Array" unless runs.is_a?(Array)

      runs.each_with_index do |run, i|
        raise "session_log corrupt: runs[#{i}] must be a Hash" unless run.is_a?(Hash)

        missing = RUN_REQUIRED_KEYS - run.keys
        raise "session_log corrupt: runs[#{i}] missing keys: #{missing.join(', ')}" if missing.any?

        raise "session_log corrupt: runs[#{i}].run_id must be Integer" unless run["run_id"].is_a?(Integer)
        raise "session_log corrupt: runs[#{i}].workflow_id must be non-empty String" unless run["workflow_id"].is_a?(String) && !run["workflow_id"].empty?
        raise "session_log corrupt: runs[#{i}].workflow_iteration must be Integer" unless run["workflow_iteration"].is_a?(Integer)

        unless run["output_file_name"].nil? || run["output_file_name"].is_a?(String)
          raise "session_log corrupt: runs[#{i}].output_file_name must be String or null"
        end

        unless [true, false, nil].include?(run["validation_passed"])
          raise "session_log corrupt: runs[#{i}].validation_passed must be true/false/null"
        end

        unless run["created_at"].is_a?(String) && !run["created_at"].empty?
          raise "session_log corrupt: runs[#{i}].created_at must be non-empty String"
        end

        unless run["edited_at"].nil? || run["edited_at"].is_a?(String)
          raise "session_log corrupt: runs[#{i}].edited_at must be String or null"
        end

        if run.key?("jira_snapshot_sha") && !(run["jira_snapshot_sha"].is_a?(String) && run["jira_snapshot_sha"].length == 64)
          raise "session_log corrupt: runs[#{i}].jira_snapshot_sha must be 64-char hex String"
        end
      end
    end

    def next_run_id_from(runs)
      return 1 if runs.empty?
      runs.map { |r| r["run_id"].to_i }.max + 1
    end

    def next_task_id_from(tasks)
      return 1 if tasks.empty?
      tasks.map { |t| t["task_id"].to_i }.max + 1
    end

    def validate_tasks(tasks)
      raise "session_log corrupt: tasks must be an Array" unless tasks.is_a?(Array)

      tasks.each_with_index do |task, i|
        raise "session_log corrupt: tasks[#{i}] must be a Hash" unless task.is_a?(Hash)

        missing = TASK_REQUIRED_KEYS - task.keys
        raise "session_log corrupt: tasks[#{i}] missing keys: #{missing.join(', ')}" if missing.any?

        raise "session_log corrupt: tasks[#{i}].task_id must be Integer" unless task["task_id"].is_a?(Integer)
        raise "session_log corrupt: tasks[#{i}].description must be non-empty String" unless task["description"].is_a?(String) && !task["description"].empty?

        unless VALID_TASK_STATUSES.include?(task["status"])
          raise "session_log corrupt: tasks[#{i}].status must be one of #{VALID_TASK_STATUSES.inspect}"
        end

        unless task["created_at"].is_a?(String) && !task["created_at"].empty?
          raise "session_log corrupt: tasks[#{i}].created_at must be non-empty String"
        end

        unless task["completed_at"].nil? || task["completed_at"].is_a?(String)
          raise "session_log corrupt: tasks[#{i}].completed_at must be String or null"
        end

        unless task["note"].nil? || task["note"].is_a?(String)
          raise "session_log corrupt: tasks[#{i}].note must be String or null"
        end
      end
    end

    def validate_check_results(results)
      raise "session_log corrupt: check_results must be an Array" unless results.is_a?(Array)

      results.each_with_index do |entry, i|
        raise "session_log corrupt: check_results[#{i}] must be a Hash" unless entry.is_a?(Hash)

        missing = CHECK_RESULT_REQUIRED_KEYS - entry.keys
        raise "session_log corrupt: check_results[#{i}] missing keys: #{missing.join(', ')}" if missing.any?

        raise "session_log corrupt: check_results[#{i}].run_id must be Integer" unless entry["run_id"].is_a?(Integer)

        unless entry["check_id"].is_a?(String) && !entry["check_id"].empty?
          raise "session_log corrupt: check_results[#{i}].check_id must be non-empty String"
        end

        unless [true, false].include?(entry["passed"])
          raise "session_log corrupt: check_results[#{i}].passed must be true/false"
        end

        unless CHECK_RESULT_VALID_TIERS.include?(entry["tier"])
          raise "session_log corrupt: check_results[#{i}].tier must be one of #{CHECK_RESULT_VALID_TIERS.inspect}"
        end

        unless entry["messages_truncated"].is_a?(String)
          raise "session_log corrupt: check_results[#{i}].messages_truncated must be String"
        end

        unless entry["checked_at"].is_a?(String) && !entry["checked_at"].empty?
          raise "session_log corrupt: check_results[#{i}].checked_at must be non-empty String"
        end

        unless [true, false].include?(entry["forced"])
          raise "session_log corrupt: check_results[#{i}].forced must be true/false"
        end

        unless entry["force_reason"].nil? || entry["force_reason"].is_a?(String)
          raise "session_log corrupt: check_results[#{i}].force_reason must be String or null"
        end
      end
    end

    def validate_jira_snapshot(snap)
      raise "session_log corrupt: jira_snapshot must be a Hash" unless snap.is_a?(Hash)

      missing = JIRA_SNAPSHOT_REQUIRED_KEYS - snap.keys
      raise "session_log corrupt: jira_snapshot missing keys: #{missing.join(', ')}" if missing.any?

      unless snap["ticket_key"].is_a?(String) && !snap["ticket_key"].empty?
        raise "session_log corrupt: jira_snapshot.ticket_key must be non-empty String"
      end

      unless snap["content_sha256"].is_a?(String) && snap["content_sha256"].length == 64
        raise "session_log corrupt: jira_snapshot.content_sha256 must be 64-char hex String"
      end

      unless snap["byte_size"].is_a?(Integer) && snap["byte_size"] >= 0
        raise "session_log corrupt: jira_snapshot.byte_size must be non-negative Integer"
      end

      unless snap["captured_at"].is_a?(String) && !snap["captured_at"].empty?
        raise "session_log corrupt: jira_snapshot.captured_at must be non-empty String"
      end

      unless snap["captured_by"].is_a?(String) && !snap["captured_by"].empty?
        raise "session_log corrupt: jira_snapshot.captured_by must be non-empty String"
      end
    end

    def validate_playbook_loads(loads)
      raise "session_log corrupt: playbook_loads must be an Array" unless loads.is_a?(Array)

      loads.each_with_index do |entry, i|
        raise "session_log corrupt: playbook_loads[#{i}] must be a Hash" unless entry.is_a?(Hash)

        missing = PLAYBOOK_LOAD_REQUIRED_KEYS - entry.keys
        raise "session_log corrupt: playbook_loads[#{i}] missing keys: #{missing.join(', ')}" if missing.any?

        unless entry["names"].is_a?(Array) && entry["names"].all? { |n| n.is_a?(String) }
          raise "session_log corrupt: playbook_loads[#{i}].names must be Array of Strings"
        end

        unless entry["loaded_at"].is_a?(String) && !entry["loaded_at"].empty?
          raise "session_log corrupt: playbook_loads[#{i}].loaded_at must be non-empty String"
        end

        unless entry["why"].nil? || entry["why"].is_a?(String)
          raise "session_log corrupt: playbook_loads[#{i}].why must be String or null"
        end
      end
    end

    def next_workflow_iteration_from(runs, workflow_id)
      id = workflow_id.to_s
      runs.count { |r| r["workflow_id"] == id } + 1
    end

    def default_payload
      now = iso8601_now
      {
        "session_id"       => @session_id,
        "status"           => "open",
        "created_at"       => now,
        "closed_at"        => nil,
        "last_activity_at" => now,
        "note"             => nil,
        "note_updated_at"  => nil,
        "checklist"        => default_checklist,
        "runs"             => [],
        "tasks"            => []
      }
    end

    def default_checklist
      CHECKLIST_DEFAULTS.each_with_object({}) do |(key, default), h|
        h[key] = { "value" => default, "checked_at" => nil }
      end
    end

    def iso8601_now
      Time.now.utc.iso8601
    end
  end
end

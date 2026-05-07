# lib/maciekos/session_backfill.rb
require "time"

module Maciekos
  # Rebuild a session's runs[] from numbered category artifacts on disk.
  # Used for legacy sessions that pre-date session metadata, and to repair
  # drift after manual file changes. Tasks, note, and checklist are preserved.
  class SessionBackfill
    SKIP_DIRS = %w[outputs dump jira_attachments].freeze

    attr_reader :unmatched_files

    def initialize(session_id, project_root: nil)
      raise ArgumentError, "session_id required" if session_id.nil? || session_id.to_s.empty?
      @session_id      = session_id.to_s
      @project_root    = project_root
      @unmatched_files = []
    end

    # Walk numbered category JSONs, build a runs[] array, write back to
    # session_log.json. Returns the new runs array.
    #
    # adjust_created_at: when true (default), shift created_at backward to
    #   the earliest run's mtime so the timeline reads sensibly. Set to
    #   false to preserve the existing created_at.
    def call(adjust_created_at: true)
      raise "session directory not found: #{session_dir}" unless Dir.exist?(session_dir)

      runs = build_runs
      return runs if runs.empty?

      sm   = SessionMetadata.new(@session_id, project_root: @project_root)
      data = sm.exists? ? sm.load : sm.create_if_missing

      data["runs"] = runs

      if adjust_created_at && Time.iso8601(data["created_at"]) > Time.iso8601(runs.first["created_at"])
        data["created_at"] = runs.first["created_at"]
      end

      data["last_activity_at"] = compute_last_activity(data, runs)

      sm.atomic_write(data)
      runs
    end

    # Latest known activity timestamp across all maintained fields.
    # Backfill always recomputes this — `create_if_missing` plants a
    # last_activity_at of "now" on fresh logs, which would otherwise mark
    # every backfilled legacy session as just-now-active.
    def compute_last_activity(data, runs)
      candidates = [
        runs.last["created_at"],
        data["note_updated_at"],
        data["closed_at"]
      ]
      (data["tasks"] || []).each do |t|
        candidates << t["created_at"]
        candidates << t["completed_at"]
      end
      data["checklist"].each_value { |entry| candidates << entry["checked_at"] }

      candidates.compact.map { |s| Time.iso8601(s) }.max.utc.iso8601
    end

    private

    def session_dir
      File.join(resolved_project_root, "sessions", @session_id)
    end

    def resolved_project_root
      @project_root || Maciekos::PROJECT_ROOT
    end

    # Sorted longest-first so prefix collisions resolve to the longer match
    # (e.g. `jira_code_review` wins over `jira` for `jira_code_review_X`).
    def workflow_ids
      @workflow_ids ||= Dir.glob(File.join(resolved_project_root, "workflows", "*.yaml"))
                           .map { |f| File.basename(f, ".yaml") }
                           .sort_by { |w| -w.length }
    end

    def parse_workflow_id(rest)
      workflow_ids.find { |w| rest == w || rest.start_with?("#{w}_") }
    end

    # Workflow runs write the <category>/*.json and outputs/*.{md,csv} within
    # the same run, so their mtimes are close. Pass 1 matches each category
    # file to the outputs file whose mtime is nearest (within MATCH_WINDOW).
    # Pass 2 assigns any remaining outputs to remaining category files of the
    # same workflow_id in NNN order — covers user-edited .md files whose
    # mtime drifted past the proximity window.
    MATCH_WINDOW_SECS = 60

    def build_runs
      category_files = collect_category_files
      return [] if category_files.empty?

      outputs_by_wf = collect_outputs_by_workflow

      category_files.sort_by! { |c| [c[:mtime], c[:nnn]] }

      matched = Array.new(category_files.length)

      category_files.each_with_index do |c, i|
        out = pop_closest_output(outputs_by_wf[c[:workflow_id]], c[:mtime])
        matched[i] = out if out
      end

      indices_by_wf = (0...category_files.length).group_by { |i| category_files[i][:workflow_id] }
      indices_by_wf.each do |wf, indices|
        leftover_indices = indices.reject { |i| matched[i] }
        leftover_outputs = outputs_by_wf[wf].sort_by { |e| e[:nnn] }
        leftover_indices.zip(leftover_outputs).each do |i, out|
          matched[i] = out if out
        end
      end

      iter = Hash.new(0)
      category_files.each_with_index.map do |c, i|
        wf = c[:workflow_id]
        iter[wf] += 1
        out = matched[i]
        {
          "run_id"             => i + 1,
          "workflow_id"        => wf,
          "workflow_iteration" => iter[wf],
          "output_file_name"   => out ? File.basename(out[:path]) : nil,
          "validation_passed"  => nil,
          "created_at"         => c[:mtime].utc.iso8601,
          "edited_at"          => nil
        }
      end
    end

    def pop_closest_output(pool, target_mtime)
      return nil if pool.empty?
      closest_idx = nil
      closest_d   = nil
      pool.each_with_index do |entry, idx|
        d = (entry[:mtime] - target_mtime).abs
        if closest_d.nil? || d < closest_d
          closest_d   = d
          closest_idx = idx
        end
      end
      return nil if closest_d.nil? || closest_d > MATCH_WINDOW_SECS
      pool.delete_at(closest_idx)
    end

    def collect_category_files
      files = []
      Dir.glob(File.join(session_dir, "*", "*.json")).each do |f|
        parent = File.basename(File.dirname(f))
        next if SKIP_DIRS.include?(parent)
        bn = File.basename(f, ".json")
        unless bn =~ /\A(\d+)_(.+)\z/
          @unmatched_files << f
          next
        end
        wf = parse_workflow_id(Regexp.last_match(2))
        unless wf
          @unmatched_files << f
          next
        end
        files << { path: f, nnn: Regexp.last_match(1).to_i, workflow_id: wf, mtime: File.mtime(f) }
      end
      files
    end

    def collect_outputs_by_workflow
      by_wf = Hash.new { |h, k| h[k] = [] }
      Dir.glob(File.join(session_dir, "outputs", "*")).each do |f|
        bn = File.basename(f).sub(/\.(md|csv)\z/, "")
        next unless bn =~ /\A(\d+)_(.+)\z/
        wf = parse_workflow_id(Regexp.last_match(2))
        next unless wf
        by_wf[wf] << { path: f, nnn: Regexp.last_match(1).to_i, mtime: File.mtime(f) }
      end
      by_wf
    end
  end
end

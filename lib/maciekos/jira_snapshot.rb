# lib/maciekos/jira_snapshot.rb
require "open3"
require "digest"
require "time"

module Maciekos
  # Captures and verifies a SHA256 fingerprint of `jira view XX-XXX`
  # output for a session. Stored in session_log.json under jira_snapshot.
  # Used to detect ticket drift — answer "do I need to re-run jira_summary?"
  # without re-reading the ticket by hand.
  #
  # The Jira project key prefix defaults to "XX" and is overridable via
  # the AIKIQ_JIRA_PROJECT_KEY env var (e.g. set to "PROJ" for PROJ-1234).
  class JiraSnapshot
    class TicketKeyNotResolvable < StandardError; end
    class JiraFetchFailed < StandardError; end

    attr_reader :session_id

    def initialize(session_id)
      raise ArgumentError, "session_id required" if session_id.nil? || session_id.to_s.empty?
      @session_id = session_id.to_s
    end

    # Reads the configured Jira project key prefix. Defaults to "XX".
    def self.project_key_prefix
      (ENV["AIKIQ_JIRA_PROJECT_KEY"] || "XX").to_s
    end

    # Extract <PREFIX>-<NUM> from a session id like "1234_x_y" or "XX-1234".
    def ticket_key
      @ticket_key ||= begin
        prefix = self.class.project_key_prefix
        m = @session_id.match(/\A(?:#{Regexp.escape(prefix)}-)?(\d{3,5})/)
        raise TicketKeyNotResolvable, "session id #{@session_id.inspect} has no #{prefix}-XXXX" unless m
        "#{prefix}-#{m[1]}"
      end
    end

    # Fetch fresh jira view output and compute its fingerprint. Returns the
    # snapshot hash but does NOT persist it. Use #capture to write.
    # The `raw_text` field lets the gate code inspect the body (e.g., for
    # last-comment-author detection) without re-fetching. SessionMetadata
    # explicitly drops it before persisting; never lands in session_log.json.
    #
    # The fingerprint is hashed over a *normalized* form of the output so
    # that `jira view`'s relative timestamps ("created: 27 days ago", per-
    # comment "<Author>, 14 hours ago") don't tick over daily and trigger
    # spurious requires_jira_unchanged halts. The raw_text we hand back is
    # untouched — workflows that auto-feed it as input still see the
    # original wording.
    def fetch
      out, _err, status = Open3.capture3("jira", "view", ticket_key)
      unless status.success?
        raise JiraFetchFailed, "jira view #{ticket_key} failed (exit #{status.exitstatus})"
      end
      {
        "ticket_key"     => ticket_key,
        "content_sha256" => Digest::SHA256.hexdigest(self.class.normalize_for_sha(out)),
        "byte_size"      => out.bytesize,
        "captured_at"    => Time.now.utc.iso8601,
        "raw_text"       => out
      }
    end

    # Collapses go-jira's relative-time strings to a constant token. Public
    # so the spec / smoke harness can replay it. Patterns covered:
    #   "27 days ago", "14 hours ago", "3 weeks ago", "1 year ago"
    #   "yesterday", "today", "just now"
    # All become "<TIMEAGO>". Anything else is left intact — we want true
    # ticket-state changes (status, assignee, new comments, edits) to keep
    # flipping the SHA.
    RELATIVE_TIME_RE = /\b(?:\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago|yesterday|today|just\s+now)\b/i

    def self.normalize_for_sha(text)
      text.to_s.gsub(RELATIVE_TIME_RE, "<TIMEAGO>")
    end

    # Pull the most recent comment author's display name from the `jira view`
    # text. The CLI prints comments oldest-first under a `comments:` section,
    # each opening with `- | # <Author Name>, <relative time>`. Returns nil
    # when the ticket has no comments.
    def self.latest_comment_author(jira_view_text)
      return nil unless jira_view_text.is_a?(String)
      matches = jira_view_text.scan(/^\s*-\s*\|\s*#\s+([^,\n]+?)\s*,\s*[^\n]*ago\s*$/)
      return nil if matches.empty?
      matches.last.first.strip
    end

    # Fetch + persist to session_log.json. captured_by tags the source so
    # later inspection can tell a manual `aikiq snapshot` from one written
    # automatically by a workflow run (e.g. captured_by: "jira_summary").
    def capture(captured_by: "manual")
      data = fetch
      data["captured_by"] = captured_by.to_s
      sm = SessionMetadata.new(@session_id)
      sm.create_if_missing unless sm.exists?
      sm.set_jira_snapshot(data)
      data
    end

    # Returns { stored:, current:, changed: } where stored may be nil if
    # nothing was previously captured. Both current fetch and the comparison
    # are deterministic — the same ticket state produces the same sha256.
    def diff
      sm = SessionMetadata.new(@session_id)
      raise "session_log not found for #{@session_id}" unless sm.exists?

      stored = sm.load["jira_snapshot"]
      current = fetch
      {
        "stored"  => stored,
        "current" => current,
        "changed" => stored.nil? || stored["content_sha256"] != current["content_sha256"]
      }
    end
  end
end

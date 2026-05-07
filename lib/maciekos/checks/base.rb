# lib/maciekos/checks/base.rb
require "time"

module Maciekos
  module Checks
    # Result struct returned by a Check#run. `messages` is a list of human
    # lines surfaced to stdout/stderr; the persisted form in session_log
    # truncates to 500 chars to keep the audit log scannable.
    class Result
      attr_reader :id, :passed, :tier, :messages, :checked_at

      def initialize(id:, passed:, tier: :fast, messages: [])
        @id          = id.to_s
        @passed      = !!passed
        @tier        = tier.to_sym
        @messages    = Array(messages).map(&:to_s)
        @checked_at  = Time.now.utc.iso8601
      end

      # Persistence shape — mirrors session_log.json check_results entries.
      # `forced` and `force_reason` fields are filled in by the runner when
      # --force-gate bypasses; not the Check's responsibility.
      def to_h(run_id:, forced: false, force_reason: nil)
        {
          "run_id"             => run_id.to_i,
          "check_id"           => @id,
          "passed"             => @passed,
          "tier"               => @tier.to_s,
          "messages_truncated" => @messages.join(" | ")[0, 500],
          "checked_at"         => @checked_at,
          "forced"             => !!forced,
          "force_reason"       => force_reason.nil? ? nil : force_reason.to_s
        }
      end
    end

    # Base class. Subclasses define id (class method), optionally override
    # tier and applies_to?, and implement run(context).
    #
    # Auto-registry via inherited hook — every subclass is collectable via
    # Base.all and lookup-able via Base.find(id). No manifest file.
    #
    # Context shape passed to #run:
    #   {
    #     workflow:      <wf hash from WorkflowEngine.load_workflow>,
    #     workflow_id:   "jira_comment",
    #     selected:      <symbol-keyed hash from Evaluator's selected>,
    #     artifact_path: <abs path to NNN_<workflow>.json>,
    #     output_path:   <abs path to outputs/NNN_<workflow>.md or nil>,
    #     session_id:    "1234_x_y"
    #   }
    class Base
      def self.id
        raise NotImplementedError, "subclass must define self.id"
      end

      def self.tier
        :fast
      end

      # Default: check applies to every workflow that lists it in vars.gates.
      # Subclasses narrow when needed (e.g. class_paths only on jira_comment).
      def applies_to?(_workflow_id)
        true
      end

      def run(_context)
        raise NotImplementedError, "subclass must define #run"
      end

      # ---- registry ----

      @registry = []

      def self.inherited(subclass)
        @registry ||= []
        @registry << subclass
        super
      end

      def self.all
        @registry ||= []
        @registry.dup
      end

      def self.find(check_id)
        all.find { |c| c.id == check_id.to_s }
      end
    end
  end
end

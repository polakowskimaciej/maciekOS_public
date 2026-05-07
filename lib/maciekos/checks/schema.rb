# lib/maciekos/checks/schema.rb
require_relative "base"
require_relative "../evaluator"

module Maciekos
  module Checks
    # Formal Check wrapper around Evaluator#validate_structure. Phase 1 of
    # the AST plan halted on selected[:structure_score]; Phase 2 always
    # recomputes via Evaluator so the same Check behaves correctly under
    # both `run_workflow` (selected is fresh) and `verify` (selected was
    # written long ago, possibly before the schema-resolution fix in
    # commit fac3957). Single source of truth: the Evaluator.
    class Schema < Base
      def self.id
        "schema"
      end

      def self.tier
        :fast
      end

      # Listing schema in vars.gates without a vars.schema_path would
      # always halt — that's intentional. Declaring the gate without a
      # schema is a config bug.
      def applies_to?(_workflow_id)
        true
      end

      def run(context)
        text = extract_text(context[:selected])
        if text.nil? || text.empty?
          return Result.new(
            id: self.class.id, tier: self.class.tier, passed: false,
            messages: ["selected response had no text payload to validate"]
          )
        end

        evaluator = Evaluator.new(context[:workflow])
        score     = evaluator.validate_structure(text: text)

        if score == 1.0
          Result.new(
            id: self.class.id, tier: self.class.tier, passed: true,
            messages: ["schema validation passed"]
          )
        else
          schema_path = context[:workflow]&.dig("vars", "schema_path")
          Result.new(
            id:       self.class.id,
            tier:     self.class.tier,
            passed:   false,
            messages: [
              "selected response failed schema validation (recomputed structure_score=#{score})",
              "vars.schema_path: #{schema_path}",
              "artifact: #{context[:artifact_path]}"
            ]
          )
        end
      end

      private

      # `raw.message.content` is OpenRouter's verbatim assistant message
      # — the source of truth. Some historical artifacts stored a
      # Ruby-inspect dump under `text` instead of the actual content;
      # prefer raw.message.content and fall back to :text only when raw
      # is missing.
      def extract_text(selected)
        return nil unless selected.is_a?(Hash)
        selected.dig(:raw, :message, :content) ||
          selected.dig("raw", "message", "content") ||
          selected[:text] ||
          selected["text"]
      end
    end
  end
end

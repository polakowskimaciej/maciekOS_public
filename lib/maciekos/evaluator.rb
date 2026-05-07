# lib/maciekos/evaluator.rb
require "json-schema"
require "json"

module Maciekos
  class Evaluator
    def initialize(workflow)
      @workflow = workflow
      @weights = { structure: 0.5, correctness: 0.3, style: 0.2 }
    end

    def validate_and_select(responses, run_id)
      evaluated = responses.map do |r|
        structure   = validate_structure(r)
        correctness = deterministic_correctness_score(r)
        style       = deterministic_style_score(r)
        score = @weights[:structure]   * structure +
                @weights[:correctness] * correctness +
                @weights[:style]       * style
        r.merge(
          score:              score,
          structure_score:    structure,
          correctness_score:  correctness,
          style_score:        style
        )
      end
      { run_id: run_id, evaluated: evaluated, selected: select_best(evaluated) }
    end

    def validate_structure(response)
      schema_path = resolve_schema_path
      return 0 unless schema_path && File.exist?(schema_path)
      begin
        obj = JSON.parse(response[:text])
        schema = JSON.parse(File.read(schema_path))
        # json-schema v6 resolves `$schema` by URL (draft-07) and errors out
        # offline. Our schemas are simple enough that draft-04 default works;
        # strip the meta-schema reference to avoid the network round trip.
        schema.delete("$schema")
        JSON::Validator.validate!(schema, obj) ? 1.0 : 0.0
      rescue
        0.0
      end
    end

    # Schema path lives at `vars.schema_path` in every active workflow YAML.
    # The legacy `validators[0].schema` lookup never worked — it stayed under
    # the wrong key and held an unexpanded `{{vars.schema_path}}` template
    # in some workflows, so structure_score was silently 0 for every run.
    # Resolution is relative to the workflow YAML's directory.
    def resolve_schema_path
      raw = @workflow.dig("vars", "schema_path")
      return nil if raw.nil? || raw.to_s.empty?
      return raw if File.exist?(raw)
      wf_path = @workflow["_workflow_path"]
      return nil unless wf_path
      File.expand_path(raw, File.dirname(wf_path))
    end

    def deterministic_correctness_score(response)
      text = (response[:text] || "").to_s
      text.length > 20 ? 1.0 : 0.0
    end

    def deterministic_style_score(response)
      text = (response[:text] || "").to_s
      banned = ["TODO", "FIXME"]
      banned.any? { |b| text.include?(b) } ? 0.0 : 1.0
    end

    def select_best(evaluated)
      # signature used as deterministic tiebreaker
      evaluated.max_by { |r| [r[:score], r[:signature]] }
    end
  end
end

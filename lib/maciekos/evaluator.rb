# lib/maciekos/evaluator.rb
require "json-schema"
require "json"

module Maciekos
  class Evaluator
    def initialize(workflow)
      @workflow = workflow
      @weights = {structure: 0.5, correctness: 0.3, style: 0.2}
    end

    def validate_and_select(responses, run_id)
      evaluated = responses.map do |r|
        structure = validate_structure(r)
        correctness = deterministic_correctness_score(r)
        style = deterministic_style_score(r)
        score = @weights[:structure] * structure +
                @weights[:correctness] * correctness +
                @weights[:style] * style
        rules = load_rules(r)
        desired_patterns = load_desired_patterns(r)
        r.merge(score: score, structure_score: structure, correctness_score: correctness, style_score: style)
      end
      selected = select_best(evaluated)
      { run_id: run_id, evaluated: evaluated, selected: selected }
    end

    def validate_structure(response)
      schema_path = @workflow.dig("vars","validators",0,"schema")
      return 0 unless schema_path && File.exist?(schema_path)
      begin
        obj = JSON.parse(response[:text])
        JSON::Validator.validate!(schema_path, obj) ? 1.0 : 0.0
      rescue
        0.0
      end
    end

    def deterministic_correctness_score(response)
      text = (response[:text] || "").to_s
      text.length > 20 ? 1.0 : 0.0
    end

    def deterministic_style_score(response)
      text = (response[:text] || "").to_s
      # deterministic heuristic: penalise banned words list (none -> 1)
      banned = ["TODO", "FIXME"]
      banned.any? { |b| text.include?(b) } ? 0.0 : 1.0
    end

    def select_best(evaluated)
      best = evaluated.max_by { |r| [r[:score], r[:signature]] } # signature for deterministic tiebreaker
      best
    end

    def validate_style(response, examples)
      return 1.0 unless examples # Skip if no examples

      text = response[:text].to_s

      # Simple deterministic style checks
      score = 1.0

      # Check format matches examples
      if examples_use_json? && !valid_json?(text)
        score -= 0.5
      end

      # Check key presence if JSON
      if valid_json?(text)
        example_keys = extract_example_keys(examples)
        response_keys = extract_keys(text)

        missing = example_keys - response_keys
        score -= (missing.length * 0.1)
      end

      # Enforce style rules
      banned_patterns = %w[TODO FIXME NOTE]
      found_banned = banned_patterns.select { |p| text.include?(p) }
      score -= (found_banned.length * 0.1)

      [score, 0.0].max # Don't go below 0
    end

    private

    def examples_use_json?
      @workflow.dig("vars", "examples_path")&.end_with?(".json")
    end

    def valid_json?(text)
      JSON.parse(text)
      true
    rescue
      false
    end

    def extract_example_keys(examples)
      return [] unless examples
      JSON.parse(examples).keys
    rescue
      []
    end

    def extract_keys(text)
      JSON.parse(text).keys
    rescue
      []
    end

    def load_rules(workflow_id)
      workflow_path = File.join("workflows", "#{workflow_id}.yaml")
      if File.exist?(workflow_path)
        wf = YAML.load_file(workflow_path)
        wf["rules"] || []
      else
        []
      end
    end

    def load_desired_patterns(workflow_id)
      workflow_path = File.join("workflows", "#{workflow_id}.yaml")
      if File.exist?(workflow_path)
        wf = YAML.load_file(workflow_path)
        wf["desired_patterns"] || []
      else
        []
      end
    end
  end
end


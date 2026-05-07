# lib/maciekos/workflow_engine.rb
require "yaml"
require "json"
require "fileutils"
require "date"

module Maciekos
  PROJECT_ROOT = File.expand_path("../..", __dir__)

  class WorkflowEngine
    # Search these candidate directories (ordered). Relative to this file.
    WORKFLOW_DIRS = [
      File.expand_path("../../workflows/examples", __dir__),
      File.expand_path("../../workflows", __dir__),
      File.expand_path("../..", __dir__)
    ].freeze

    ARTIFACT_DIR = File.join(Maciekos::PROJECT_ROOT, __dir__)

    # List workflows found under any candidate directory (unique, sorted).
    # Paths containing "/_" (e.g. workflows/_examples/) are excluded on purpose.
    def list_workflows
      files = WORKFLOW_DIRS.flat_map do |d|
        next [] unless Dir.exist?(d)
        Dir.glob(File.join(d, "*.yaml")).reject { |path| path.include?("/_") }
      end.compact.uniq

      files.map { |p| File.basename(p, ".yaml") }.uniq.sort
    end

    # Load the named workflow by searching candidate directories in order.
    def load_workflow(id)
      tried = []
      WORKFLOW_DIRS.each do |d|
        path = File.join(d, "#{id}.yaml")
        tried << path
        next unless File.exist?(path)

        content = File.read(path)
        begin
          wf = if YAML.respond_to?(:safe_load)
                 YAML.safe_load(content, permitted_classes: [Date, Time], aliases: true) || {}
               else
                 YAML.load(content) || {}
               end
        rescue Psych::DisallowedClass, Psych::Exception => e
          warn "Warning: YAML.safe_load failed for #{path} (#{e.class}): #{e.message}. Retrying with permissive loader."
          wf = YAML.load(content) || {}
        end

        wf["_workflow_path"] = path
        return wf
      end

      raise "Workflow #{id} not found. Paths tried:\n  - #{tried.join("\n  - ")}"
    end

    # Build the prepared prompt and extract a system_message from workflow if present.
    # Returns: [prepared_prompt (string), system_message (string or nil)]
    def prepare_prompt(wf, session_id, input)
      system_message = wf["system_message"] || wf["description"] || "You are maciekOS assistant."

      schema_text   = load_workflow_schemas(wf)
      examples_text = load_workflow_examples(wf)

      parts = []

      warn "[WorkflowEngine] session: #{session_id}" if ENV["MACIEKOS_DEBUG"] == "true"

      parts << "WORKFLOW: #{wf['id'] || wf['_workflow_path'] || 'unknown'}"
      parts << "TIMESTAMP: #{Time.now.utc.iso8601}"
      parts << "TICKET: #{session_id}"

      parts << examples_text if examples_text
      parts << schema_text   if schema_text

      parts << (wf["instructions"] || wf["prompt_template"] || "")
      parts << "\nINPUT:\n#{input}"

      [parts.join("\n\n"), system_message]
    end

    # Writes the raw JSON artifact.
    # - session present → sessions/<session>/<category>/NNN_<workflow>[_label].json
    # - no session      → artifacts/<workflow>_<run_id>.json
    def write_artifact(workflow_id, run_id, result, session: nil, label: nil)
      category = workflow_id.split("_").first

      base_dir =
        if session
          File.join(Maciekos::PROJECT_ROOT, "sessions", session, category)
        else
          File.join(Maciekos::PROJECT_ROOT, "artifacts")
        end

      FileUtils.mkdir_p(base_dir)

      filename =
        if session
          index  = Dir[File.join(base_dir, "*.json")].count + 1
          prefix = format("%03d", index)
          label ? "#{prefix}_#{workflow_id}_#{label}.json" : "#{prefix}_#{workflow_id}.json"
        else
          "#{workflow_id}_#{run_id}.json"
        end

      path = File.join(base_dir, filename)
      File.write(path, JSON.pretty_generate(result))
      path
    end

    private

    def load_workflow_schemas(workflow)
      schemas_path = workflow.dig("vars", "schema_path")
      return nil unless schemas_path

      workflow_dir = File.dirname(workflow["_workflow_path"])
      full_path    = File.expand_path(schemas_path, workflow_dir)

      SchemasLoader.new(workflow["_workflow_path"]).load_schemas(full_path)
    end

    def load_workflow_examples(workflow)
      examples = workflow.dig("vars", "examples")
      return nil unless examples&.any?

      ExamplesLoader.new(workflow["_workflow_path"]).load_examples(examples)
    end
  end
end

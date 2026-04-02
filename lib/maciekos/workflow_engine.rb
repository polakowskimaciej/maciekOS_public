# lib/maciekos/workflow_engine.rb
require "yaml"
require "json"
require "fileutils"
require "date"

module Maciekos
  PROJECT_ROOT = File.expand_path("../..", __dir__)
  class WorkflowEngine
    WORKFLOW_DIRS = [
      File.expand_path("../../workflows/examples", __dir__),
      File.expand_path("../../workflows", __dir__),
      File.expand_path("../..", __dir__) # fallback to repo root/workflows if present
    ].freeze

    ARTIFACT_DIR = File.join(Maciekos::PROJECT_ROOT, __dir__)

    def list_workflows
      files = WORKFLOW_DIRS.flat_map do |d|
        next [] unless Dir.exist?(d)
        # Exclude subdirectories starting with _
        Dir.glob(File.join(d, "*.yaml")).reject do |path|
          path.include?("/_")
        end
      end.compact.uniq

      files.map { |p| File.basename(p, ".yaml") }.uniq.sort
    end

    def load_workflow(id)
      tried = []
      WORKFLOW_DIRS.each do |d|
        path = File.join(d, "#{id}.yaml")
        tried << path
        if File.exist?(path)
          content = File.read(path)
          begin
            # Use safe_load with permit minimal classes (Date, Time) and aliases for compatibility
            if YAML.respond_to?(:safe_load)
              wf = YAML.safe_load(content, permitted_classes: [Date, Time], aliases: true) || {}
            else
              wf = YAML.load(content) || {}
            end
            wf["_workflow_path"] = path
            return wf
          rescue Psych::DisallowedClass, Psych::Exception => e
            warn "Warning: YAML.safe_load failed for #{path} (#{e.class}): #{e.message}. Retrying with permissive loader."
              wf = YAML.load(content) || {}
            wf["_workflow_path"] = path
            return wf
          end
        end
      end

      raise "Workflow #{id} not found. Paths tried:\n  - #{tried.join("\n  - ")}"
    end

    def prepare_prompt(wf, session_id, input)
      system_message = wf["system_message"] || wf["description"] || "You are maciekOS assistant."

      schema_path = wf.dig("vars", "schema_path")
      schema_text = load_workflow_schemas(wf)
      # Debug examples loading
      examples_path = wf.dig("vars", "examples_path")

      examples_text = load_workflow_examples(wf)

        # Build prompt parts
        parts = []

        puts session_id
        parts << "WORKFLOW: #{wf['id'] || wf['_workflow_path'] || 'unknown'}"
        parts << "TIMESTAMP: #{Time.now.utc.iso8601}"
        parts << "TICKET: #{session_id}"

        # Add examples if available
        if examples_text
          parts << examples_text
        end

        if schema_text
          parts << schema_text
        end

      parts << (wf["instructions"] || wf["prompt_template"] || "")
      parts << "\nINPUT:\n#{input}"

      prepared = parts.join("\n\n")

      [prepared, system_message]
    end


    def write_artifact(workflow_id, run_id, result, session: nil, label: nil)
      # Extract category from workflow_id (e.g., "jira" from "jira_comment")
      category = workflow_id.split('_').first

      base_dir =
        if session
          File.join(Maciekos::PROJECT_ROOT, "sessions", session, category)
        else
          File.join(Maciekos::PROJECT_ROOT, "artifacts")
        end

      FileUtils.mkdir_p(base_dir)

      index =
        if session
          Dir[File.join(base_dir, "*.json")].count + 1
        end

      filename =
        if session
          prefix = format("%03d", index)
          name = label ? "#{prefix}_#{workflow_id}_#{label}.json" : "#{prefix}_#{workflow_id}.json"
          name
        else
          "#{workflow_id}_#{run_id}.json"
        end

      path = File.join(base_dir, filename)
      File.write(path, JSON.pretty_generate(result))
      path
    end

    def resolve_schema_path(schema_name)
      File.join(
        Maciekos::PROJECT_ROOT,
        "validators",
        "#{schema_name}_schema.json"
      )

  end

    def debug_log(message)
      return unless @debug
      puts "[DEBUG] OutputProcessor: #{message}"
    end

    private

    def load_workflow_schemas(workflow)
      # puts "\n=== Schema Loading Debug ==="
      schemas_path = workflow.dig("vars", "schema_path")
      # puts "1. Schema path from workflow vars: #{schemas_path || 'nil'}"
        return nil unless schemas_path

      workflow_dir = File.dirname(workflow["_workflow_path"])
      # puts "2. Workflow directory: #{workflow_dir}"

        full_path = File.expand_path(schemas_path, workflow_dir)
      # puts "3. Resolved full schema path: #{full_path}"
        # puts "4. File exists?: #{File.exist?(full_path)}"

        loader = SchemasLoader.new(workflow["_workflow_path"])
      schemas = loader.load_schemas(full_path)
      # puts "5. Loaded schema content?: #{!schemas.nil?}"
        # puts "=== End Schema Loading ===\n"
      schemas
    end

    def load_workflow_examples(workflow)
      # puts "\n=== Examples Loading Debug ==="
      examples = workflow.dig("vars", "examples")
      # puts "1. Examples from workflow vars: #{examples ? examples.length : 'nil'} examples"
        return nil unless examples&.any?

      workflow_dir = File.dirname(workflow["_workflow_path"])
      # puts "2. Workflow directory: #{workflow_dir}"

        loader = ExamplesLoader.new(workflow["_workflow_path"])
      examples_text = loader.load_examples(examples)  # Pass examples array directly
      # puts "3. Loaded examples content?: #{!examples_text.nil?}"
        # puts "=== End Examples Loading ===\n"
      examples_text
    end
  end
end

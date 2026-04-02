# lib/maciekos/schemas_loader.rb
require 'yaml'
require 'json'

module Maciekos
  class SchemasLoader

    def initialize(workflow_path)
      @workflow_path = workflow_path
      @schemas_dir = File.dirname(workflow_path)
    end

    def load_schemas(schemas_config_path)
      # puts "\n=== Schema Loader Debug ==="
      # puts "1. Attempting to load schema from: #{schemas_config_path}"
        return nil unless schemas_config_path && File.exist?(schemas_config_path)

      begin
        if schemas_config_path.end_with?('.json')
          # puts "2. Loading as direct JSON schema file"
          schema_content = File.read(schemas_config_path)
          # puts "3. Successfully read schema file (#{schema_content.length} chars)"
          return "JSON Schema:\n#{schema_content}"
        else
          # puts "2. Loading as YAML config file"
          config = YAML.load_file(schemas_config_path)
          # puts "3. Successfully loaded YAML config"
          schemas = load_schema_files(config['schemas'])
          result = format_schemas_block(config, schemas)
          # puts "4. Formatted schema block: #{!result.nil?}"
            return result
        end
      rescue => e
         puts "ERROR: Failed to load schema: #{e.class} - #{e.message}"
           puts e.backtrace[0..2]
        nil
      ensure
        # puts "=== End Schema Loader ===\n"
      end
    end

    private

    def load_schema_files(schema_configs)
      return [] unless schema_configs&.any?

      schema_configs.map do |schema|
        # Resolve path relative to schemas config file
        file_path = File.expand_path(schema['file'], @schemas_config_dir)

        next nil unless File.exist?(file_path)

        content = File.read(file_path)

        {
          id: schema['id'],
          content: content,
          description: schema['description']
        }
      end.compact
    end

    def format_schemas_block(config, schemas)
      return nil if schemas.empty?

      parts = []

      if config['system_message']
        parts << "SYSTEM:\n#{config['system_message'].strip}"
      end

      # Add style rules
      if config['style_rules']&.any?
        parts << "STYLE RULES:\n#{config['style_rules'].map { |r| "- #{r}" }.join("\n")}"
      end

      parts << "schemas:"
      schemas.each do |schema|
        parts << format_schema(schema)
      end

      parts.join("\n\n")
    end

    def format_schema(schema)
      <<~schema
      Input schema (#{schema[:id]}):
        #{schema[:description]}

        Output:
        #{schema[:content]}
        schema
    end
  end
end


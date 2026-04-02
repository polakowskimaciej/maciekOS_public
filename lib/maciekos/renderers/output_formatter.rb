# lib/maciekos/renderers/output_formatter.rb
require_relative 'generic_renderer'

module Maciekos
  module Renderers
    class OutputFormatter
      def self.format(workflow:, content:)
        # Extract content from code blocks if present
        if content.is_a?(String)
          if content.match(/```(?:json)?\n(.*)\n```/m)
            content = $1
          end
        end

        if content.is_a?(String) && content.strip.start_with?('{') && content.strip.end_with?('}')
          begin
            content = JSON.parse(content)
          rescue JSON::ParserError
            # Keep original content if parsing fails
          end
        end

        rendered = GenericRenderer.new(
          workflow: workflow,
          content: content
        ).render

        "<!-- maciekOS: This is an auto-generated file. Edit with care. -->\n\n#{rendered}"
      end
    end
  end
end

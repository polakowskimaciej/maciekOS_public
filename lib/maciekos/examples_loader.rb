require 'yaml'
require 'json'

# lib/maciekos/examples_loader.rb
module Maciekos
  class ExamplesLoader
    def initialize(workflow_path)
      @workflow_path = workflow_path
      @examples_dir = File.dirname(workflow_path)
    end

    def load_examples(examples_config)
      # puts "\n=== Examples Loader Debug ==="
      # puts "1. Examples config: #{examples_config.inspect}"
      return nil unless examples_config&.any?

      example_pairs = examples_config.group_by { |ex| ex['id'] }
      # puts "2. Found #{example_pairs.size} example pairs"

      examples = example_pairs.map do |id, pair|
        input_config = pair.find { |p| p['input'] }
        output_config = pair.find { |p| p['output'] }
        
        next unless input_config && output_config
        
        input_path = File.expand_path(input_config['input'], File.dirname(@workflow_path))
        output_path = File.expand_path(output_config['output'], File.dirname(@workflow_path))
        
        # puts "  - Loading pair #{id}:"
        # puts "    Input: #{input_path}"
        # puts "    Output: #{output_path}"
        
        next unless File.exist?(input_path) && File.exist?(output_path)

        {
          id: id,
          description: input_config['description'],
          input: File.read(input_path),
          output: File.read(output_path)
        }
      end.compact

      format_examples_block(examples)
    end

    private

    def format_examples_block(examples)
      return nil if examples.empty?

      parts = ["EXAMPLES:"]
      examples.each do |example|
        parts << format_example(example)
      end

      # puts "3. Formatted #{examples.size} example pairs"
      parts.join("\n\n")
    end

    def format_example(example)
      <<~EXAMPLE
      Example #{example[:id]}:
      #{example[:description] if example[:description]}

      Input:
      #{example[:input].strip}

      Output:
      #{example[:output].strip}

      EXAMPLE
    end
  end
end

# lib/maciekos/output_processor.rb
require 'fileutils'
require 'json'
require_relative 'renderers/output_formatter'
require_relative 'output_writer'

module Maciekos
  class OutputProcessor
    def initialize(workflow_id:, session_id: nil)
      @workflow_id = workflow_id
      @session_id = session_id
      @debug = ENV['MACIEKOS_DEBUG'] == 'true'
    end

    def process(artifact)
      debug_log "Processing artifact for workflow: #{@workflow_id}"
        debug_log "Session ID: #{@session_id}" if @session_id

        content = extract_content(artifact)
      if content.nil?
        debug_log "No content extracted from artifact"
        return nil
      end

      debug_log "Content extracted successfully"
      debug_log "Content type: #{content.class}"

        # For testmo workflows, skip markdown formatting and write raw CSV
        if csv_workflow?
          debug_log "CSV workflow detected, writing raw content"
          rendered = content.to_s
        else
          rendered = Renderers::OutputFormatter.format(
            workflow: @workflow_id,
            content: content
          )
          debug_log "Content rendered, length: #{rendered.length}"
        end

      write_output(rendered)
    end

    private

    def extract_content(artifact)
      debug_log "Extracting content from artifact"
      return nil unless artifact

      selected = artifact[:selected] || artifact["selected"]
      debug_log "Selected response found: #{!!selected}"

        return nil unless selected

      # Try to get content from standard locations
      content = selected.dig(:raw, "message", "content") ||
        selected.dig("raw", "message", "content")

      if content
        debug_log "Raw content found, length: #{content.length}"

          # Try to parse as JSON if it looks like JSON
          if content.strip.start_with?('{') && content.strip.end_with?('}')
            begin
              parsed = JSON.parse(content)
              debug_log "Successfully parsed content as JSON"
              return parsed
            rescue JSON::ParserError => e
              debug_log "JSON parsing failed: #{e.message}"
                return content
            end
          end

        return content
      end

      debug_log "No content found in standard locations"
      nil
    end


    def write_output(content)
      path = output_path
      FileUtils.mkdir_p(File.dirname(path))

      # Ensure jira_attachments and dump directories exist for this session
      ensure_session_directories

      status = Maciekos::OutputWriter.write(path, content)

      case status
      when :written
        puts "Output written to: #{path}"
      when :skipped
        puts "Output skipped (file exists and is edited): #{path}"
      end

      path
    rescue StandardError => e
      puts "Error writing output: #{e.message}"
        debug_log "Error details: #{e.full_message}"
        nil
    end


    def ensure_session_directories
      return unless @session_id

      base_path = File.join(Maciekos::PROJECT_ROOT, "sessions", @session_id)
      FileUtils.mkdir_p(File.join(base_path, "jira_attachments"))
      FileUtils.mkdir_p(File.join(base_path, "dump"))
    end


    def output_path
      extension = csv_workflow? ? '.csv' : '.md'

      if @session_id
        sequence = next_sequence_number
        path = File.join(
          Maciekos::PROJECT_ROOT,
          "sessions",
          @session_id,
          "outputs",
          "#{format('%03d', sequence)}_#{@workflow_id}#{extension}"
        )
        debug_log "Session-based path: #{path}"
          path
      else
        # Default path structure for non-session runs (no numbering needed)
        path = File.join(
          Maciekos::PROJECT_ROOT,
          "outputs",
          @workflow_id,
          "#{Time.now.strftime('%Y%m%d_%H%M%S')}#{extension}"
        )
        debug_log "Default path: #{path}"
          path
      end
    end

    def csv_workflow?
      @workflow_id.to_s.match?(/testmo/)
    end

    def next_sequence_number
      outputs_dir = File.join(Maciekos::PROJECT_ROOT, "sessions", @session_id, "outputs")
      return 1 unless Dir.exist?(outputs_dir)

      existing_files = Dir.glob(File.join(outputs_dir, "*"))

      max_num = existing_files.map do |filepath|
        basename = File.basename(filepath)
        if basename =~ /^(\d+)_/
            $1.to_i
        else
          0
        end
      end.max || 0

      max_num + 1
    end

    def debug_log(message)
      return unless @debug
      puts "[DEBUG] OutputProcessor: #{message}"
    end
  end
end

# lib/maciekos/file_processor.rb
require "digest"

module Maciekos
  class FileProcessor
    # File type detection patterns
    FILE_TYPES = {
      diff: %w[.diff .patch],
      source: %w[.rb .py .js .ts .java .c .cpp .h .hpp .go .rs .php .swift .kt],
      config: %w[.yaml .yml .json .toml .xml .ini .conf .cfg],
      log: %w[.log .txt],
      markdown: %w[.md .markdown],
      data: %w[.csv .tsv .dat]
    }.freeze

    def initialize(max_size: 1_048_576, compress: false)
      @max_size = max_size
      @compress = compress
    end

    def collect_from_directory(dir_path, patterns = ["*"])
      files = []
      
      patterns.each do |pattern|
        Dir.glob(File.join(dir_path, "**", pattern)).each do |path|
          next unless File.file?(path)
          next if File.size(path) > @max_size
          files << path
        end
      end
      
      files.sort # deterministic ordering
    end

    def process_files(file_paths)
      parts = []
      
      file_paths.each_with_index do |path, idx|
        file_num = idx + 1
        content = read_file_safe(path)
        
        if content.nil?
          parts << format_file_error(file_num, path, "Unable to read file")
          next
        end

        file_type = detect_file_type(path)
        parts << format_file_block(file_num, path, content, file_type)
      end
      
      parts.join("\n\n")
    end

    private

    def read_file_safe(path)
      return nil unless File.exist?(path)
      return nil if File.size(path) > @max_size
      
      content = File.read(path)
      
      if content.encoding == Encoding::ASCII_8BIT && content.count("\x00") > 0
        return "[Binary file: #{File.basename(path)}, #{File.size(path)} bytes]"
      end
      
      if @compress && content.length > 10_000
        return compress_content(content)
      end
      
      content
    rescue => e
      "[Error reading #{File.basename(path)}: #{e.message}]"
    end

    def detect_file_type(path)
      ext = File.extname(path).downcase
      
      FILE_TYPES.each do |type, extensions|
        return type if extensions.include?(ext)
      end
      
      :unknown
    end

    def format_file_block(num, path, content, file_type)
      basename = File.basename(path)
      size = content.length
      
      type_label = case file_type
                   when :diff then "DIFF"
                   when :source then "SOURCE (#{File.extname(path)[1..-1]})"
                   when :config then "CONFIG"
                   when :log then "LOG"
                   when :markdown then "MARKDOWN"
                   when :data then "DATA"
                   else "FILE"
                   end
      
      <<~BLOCK
        --- BEGIN #{type_label} [#{num}]: #{basename} (#{size} chars) ---
        #{content}
        --- END #{type_label} [#{num}] ---
      BLOCK
    end

    def format_file_error(num, path, error_msg)
      <<~BLOCK
        --- FILE [#{num}]: #{File.basename(path)} ---
        [ERROR: #{error_msg}]
        --- END FILE [#{num}] ---
      BLOCK
    end

    def compress_content(content)
      lines = content.lines
      if lines.length > 200
        head = lines[0..100].join
        tail = lines[-100..-1].join
        middle_lines = lines.length - 200
        
        "#{head}\n... [#{middle_lines} lines omitted] ...\n#{tail}"
      else
        content
      end
    end
  end
end

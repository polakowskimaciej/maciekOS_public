# lib/maciekos/output_writer.rb
require 'fileutils'

module Maciekos
  class OutputWriter
    EDIT_MARKER = "<!-- maciekOS: edited -->"

    def self.write(path, content)
      if File.exist?(path)
        existing = File.read(path)
        if existing.include?(EDIT_MARKER)
          puts "Skipping edited file: #{path}"
          return :skipped
        end
      end

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      :written
    end
  end
end

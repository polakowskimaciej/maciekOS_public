# lib/maciekos/renderers/generic_renderer.rb
module Maciekos
  module Renderers
    class GenericRenderer
      HEADING_LEVELS = {
        1 => '#',
        2 => '##',
        3 => '###',
        4 => '####',
        5 => '#####'
      }

      def initialize(workflow:, content:)
        @workflow = workflow
        @content = content
        @output = +""
      end

      def render
        add_header(@workflow, level: 2)
        render_value(@content, level: 3)
        @output
      end

      private

      def add_header(text, level:)
        @output << "#{HEADING_LEVELS[level]} #{humanize(text)}\n\n"
      end

      def render_value(value, level:)
        case value
        when Hash   then render_hash(value, level)
        when Array  then render_array(value, level)
        when String then render_string(value)
        when nil    then render_nil
        else        render_primitive(value)
        end
        @output
      end

      def render_hash(hash, level)
        return if hash.empty?

        hash.each do |key, value|
          # Skip rendering if value is nil or empty collection
          next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          add_header(key, level: level)
          
          case value
          when Hash
            render_value(value, level: level + 1)
          when Array
            render_array(value, level)
          else
            render_value(value, level: level)
          end
        end
      end

      def render_array(array, level)
        return if array.empty?

        if array.all? { |item| simple_value?(item) }
          array.each { |item| @output << "- #{item}\n" }
          @output << "\n"
        else
          array.each { |item| render_value(item, level: level) }
        end
      end

      def render_string(str)
        if str.include?("\n")
          @output << "```\n#{str}\n```\n\n"
        else
          @output << "#{str}\n\n"
        end
      end

      def render_primitive(value)
        @output << "#{value}\n\n"
      end

      def render_nil
        @output << "_No value provided_\n\n"
      end

      def simple_value?(value)
        value.is_a?(String) || value.is_a?(Numeric) || 
        value.is_a?(TrueClass) || value.is_a?(FalseClass)
      end

      def humanize(text)
        text.to_s
          .tr('_', ' ')
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
          .gsub(/([a-z\d])([A-Z])/, '\1 \2')
          .capitalize
      end
    end
  end
end


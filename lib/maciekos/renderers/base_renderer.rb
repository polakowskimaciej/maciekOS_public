# lib/maciekos/renderers/base_renderer.rb

module Maciekos
  module Renderers
    class BaseRenderer
      def initialize(artifact)
        @artifact = artifact
        @content  = artifact[:content]
      end

      def render
        raise NotImplementedError, "Renderer must implement #render"
      end

      protected

      def h2(text)
        "## #{text}\n"
      end

      def h3(text)
        "### #{text}\n"
      end

      def bullet(text)
        "- #{text}\n"
      end

      def bullets(items)
        items.map { |i| bullet(i) }.join
      end

      def blank
        "\n"
      end
    end
  end
end


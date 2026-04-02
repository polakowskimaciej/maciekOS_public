# lib/maciekos/validators/json_schema_validator.rb
require "json-schema"

module Maciekos
  module Validators
    class JsonSchemaValidator
      def self.valid?(schema_path, text)
        return false unless File.exist?(schema_path)
        obj = JSON.parse(text) rescue nil
        return false unless obj
        JSON::Validator.validate(schema_path, obj)
      end
    end
  end
end


# lib/maciekos/openrouter_adapter.rb
require "httparty"
require "digest"
require "yaml"
require "thread"
require "json"
require "time"

module Maciekos
  class OpenRouterAdapter
    CHAT_PATH = "/chat/completions".freeze

    def initialize(config_path = File.expand_path("../config/openrouter.yaml", __dir__))
      @cfg = YAML.load_file(config_path) rescue {}
      @endpoint = @cfg.dig("openrouter", "endpoint") || "https://openrouter.ai/api/v1"
      @timeout = @cfg.dig("openrouter", "timeout_seconds") || 30
      @api_key = load_api_key_if_present
      @default_provider_opts = (@cfg.dig("openrouter", "provider") || {}).dup
    end

    def load_api_key_if_present
      return ENV["OPENROUTER_API_KEY"] if ENV["OPENROUTER_API_KEY"] && !ENV["OPENROUTER_API_KEY"].empty?
      keyfile = File.expand_path("~/.config/maciekos/openrouter_api_key")
      return File.read(keyfile).strip if File.exist?(keyfile) && !File.read(keyfile).strip.empty?
      nil
    end

    def call_with_fanout(model_prefs, prepared_prompt, opts = {})
      if opts[:models_override] && opts[:models_override].is_a?(Array) && !opts[:models_override].empty?
        models = opts[:models_override].map(&:to_s)
        return call_chat_completions_multi(models, prepared_prompt, opts)
      end

      tier_lists = Array(model_prefs).map do |tier_cfg|
        tier = tier_cfg["tier"]
        fanout = tier_cfg.fetch("fanout", true)
        raw_models = @cfg.dig("model_aliases", tier) || []
        models = Array(raw_models).map { |m| normalize_model_entry(m) }
        { tier: tier, models: models, fanout: fanout }
      end

      results = []

      tier_lists.each do |entry|
        models = entry[:models] || []
        if entry[:fanout] && models.size > 1
          results.concat(call_chat_completions_multi(models, prepared_prompt, opts))
        else
          models_to_call = models.empty? ? [] : [models.first]
          models_to_call.each do |m|
            results << call_chat_completions_single(m, prepared_prompt, opts)
          end
        end
      end

      normalized = results.each_with_index.map do |r, i|
        r = stringify_keys(r)
        r[:model] = (r[:model] || r["model"] || "unknown:#{i}").to_s
        r
      end

      normalized.sort_by { |r| r[:model].to_s }
    end

    private

    def normalize_model_entry(entry)
      case entry
      when String then entry
      when Hash then entry["name"] || entry[:name] || entry.values.first.to_s
      else entry.to_s
      end
    end

    def call_chat_completions_multi(models_array, prepared_prompt, opts = {})
      url = "#{@endpoint}#{CHAT_PATH}"
      headers = base_headers
      payload = {
        models: models_array,
        messages: build_messages(prepared_prompt, opts[:system_message]),
        temperature: opts.fetch(:temperature, 0),
        top_p: opts.fetch(:top_p, 0),
        frequency_penalty: opts.fetch(:frequency_penalty, 0),
        presence_penalty: opts.fetch(:presence_penalty, 0),
        stream: opts.fetch(:stream, false),
        provider: (@default_provider_opts.merge(opts.fetch(:provider, {})))
      }.compact

      log_curl(url: url, headers: headers, payload: payload)

      started_at = Time.now
      resp = HTTParty.post(url, body: JSON.generate(payload), headers: headers, timeout: @timeout)
      latency = Time.now - started_at

      if resp.code >= 400
        return models_array.map { |m| { model: m.to_s, error: "HTTP #{resp.code}: #{resp.body}", latency: latency } }
      end

      body = resp.parsed_response
      parse_multi_model_response(models_array, body, latency, prepared_prompt)
    rescue => e
      models_array.map { |m| { model: m.to_s, error: e.message.to_s } }
    end

    def call_chat_completions_single(model, prepared_prompt, opts = {})
      url = "#{@endpoint}#{CHAT_PATH}"
      headers = base_headers
      payload = {
        model: model.to_s,
        messages: build_messages(prepared_prompt, opts[:system_message]),
        temperature: opts.fetch(:temperature, 0),
        top_p: opts.fetch(:top_p, 0),
        frequency_penalty: opts.fetch(:frequency_penalty, 0),
        presence_penalty: opts.fetch(:presence_penalty, 0),
        stream: opts.fetch(:stream, false),
        provider: (@default_provider_opts.merge(opts.fetch(:provider, {})))
      }.compact

      log_curl(url: url, headers: headers, payload: payload)

      started_at = Time.now
      resp = HTTParty.post(url, body: JSON.generate(payload), headers: headers, timeout: @timeout)
      latency = Time.now - started_at

      if resp.code >= 400
        return { model: model.to_s, error: "HTTP #{resp.code}: #{resp.body}", latency: latency }
      end

      body = resp.parsed_response
      text = extract_text(body)
      signature = deterministic_signature(model.to_s, prepared_prompt, text)
      { model: model.to_s, text: text, raw: body, latency: latency, signature: signature }
    rescue => e
      { model: model.to_s, error: e.message.to_s }
    end

    # Build deterministic messages array
    def build_messages(prepared_prompt, workflow_system_message = nil)
      system_msg = workflow_system_message || @cfg.dig("openrouter", "system_message") || "You are maciekOS assistant."
      [
        { "role" => "system", "content" => system_msg },
        { "role" => "user",   "content" => prepared_prompt }
      ]
    end

    # Parse multi-model responses robustly
    def parse_multi_model_response(models_array, body, latency, prepared_prompt)
      results = []

      if body.is_a?(Hash) && body["results"].is_a?(Array)
        body["results"].each do |entry|
          model_id = entry["model"] || entry["model_id"] || "unknown"
          text = extract_text(entry)
          sig = deterministic_signature(model_id.to_s, prepared_prompt, text)
          results << { model: model_id.to_s, text: text, raw: entry, latency: latency, signature: sig }
        end
        models_array.each do |m|
          results << { model: m.to_s, error: "no result for model #{m}", latency: latency } unless results.any? { |r| r[:model].to_s == m.to_s }
        end
        return results
      end

      if body.is_a?(Hash) && (body["choices"] || body["output"] || body["outputs"])
        models_array.each_with_index do |m, i|
          portion = nil
          if body["outputs"].is_a?(Array) && body["outputs"][i]
            portion = body["outputs"][i]
          elsif body["choices"].is_a?(Array) && body["choices"][i]
            portion = body["choices"][i]
          elsif body["output"].is_a?(Array) && body["output"][i]
            portion = body["output"][i]
          else
            portion = body
          end
          text = extract_text(portion)
          sig = deterministic_signature(m.to_s, prepared_prompt, text)
          results << { model: m.to_s, text: text, raw: portion, latency: latency, signature: sig }
        end
        return results
      end

      text = extract_text(body)
      models_array.map do |m|
        { model: m.to_s, text: text, raw: body, latency: latency, signature: deterministic_signature(m.to_s, prepared_prompt, text) }
      end
    end

    # Best-effort text extraction
    def extract_text(body)
      return "" if body.nil?
      begin
        if body.is_a?(Hash)
          return body.dig("output", "text").to_s if body.dig("output", "text")
          if body["output"].is_a?(Array) && body["output"].first.is_a?(String)
            return body["output"].first.to_s
          end
          if body["results"].is_a?(Array) && body["results"].first.is_a?(Hash)
            r = body["results"].first
            return r.dig("output", "text").to_s if r.dig("output", "text")
          end
          if body["choices"].is_a?(Array) && body["choices"].first
            c = body["choices"].first
            return c["text"].to_s if c["text"]
            return c["message"]["content"].to_s if c["message"] && c["message"]["content"]
          end
        elsif body.is_a?(Array)
          return body.first.to_s
        else
          return body.to_s
        end
      rescue => _e
        # ignore and fallback
      end
      body.to_s
    end

    def deterministic_signature(model_name, prompt, text)
      Digest::SHA256.hexdigest([model_name.to_s, prompt.to_s, text.to_s].join("|"))
    end

    def base_headers
      h = { "Content-Type" => "application/json" }
      h["Authorization"] = "Bearer #{@api_key}" if @api_key
      h
    end

    def stringify_keys(hash_like)
      return hash_like unless hash_like.is_a?(Hash)
      result = {}
      hash_like.each do |k, v|
        key = k.is_a?(String) ? k : k.to_s
        result[key.to_sym] = v
      end
      result
    end

    # -------------------------
    # Curl logging utilities
    # -------------------------
    def logging_enabled?
      ENV["MACIEKOS_LOG_CURL"] == "1"
    end

    def redact_auth_header_value(value)
      return value if value.nil? || value.empty?
      if ENV["MACIEKOS_LOG_CURL_SHOW_KEY"] == "1"
        value
      else
        # assume Bearer <token>
        parts = value.split
        if parts.length >= 2
          token = parts[1]
          "Bearer #{token[0..5]}***REDACTED***"
        else
          "#{value[0..5]}***REDACTED***"
        end
      end
    end

    def log_curl(url:, headers:, payload:)
      return unless logging_enabled?
      masked = headers.transform_values { |v| v == headers["Authorization"] ? redact_auth_header_value(v) : v }
      header_args = masked.map { |k, v| %Q(-H "#{k}: #{v}") }.join(" \\\n  ")
      body_json = JSON.generate(payload)
      curl_cmd = <<~CURL
        curl -X POST "#{url}" \\
          #{header_args} \\
          -d '#{body_json}'
      CURL
      puts "\n=== OUTBOUND REQUEST (CURL) ==="
      puts curl_cmd
      puts "===============================\n\n"
    end
  end
end

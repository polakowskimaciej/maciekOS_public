# lib/maciekos/jira_client.rb
require "httparty"
require "yaml"
require "json"
require "base64"

module Maciekos
  # Thin client for the live Jira Cloud REST API. Built specifically because
  # go-jira's `jira list` calls the deprecated /rest/api/2/search endpoint,
  # which Atlassian removed in 2025. The replacement is /rest/api/3/search/jql
  # — different shape (cursor pagination, explicit fields list).
  #
  # Config sourced from ~/.jira.d/config.yml (the same file go-jira uses) so
  # the user doesn't have to set up credentials twice. Env vars
  # (AIKIQ_JIRA_ENDPOINT / AIKIQ_JIRA_EMAIL / AIKIQ_JIRA_API_TOKEN) win when
  # set — useful in CI or when juggling instances.
  #
  # Auth: Basic <base64(email:token)>. Atlassian Cloud's documented
  # auth scheme for API tokens (the ATATT... format). Bearer also works
  # for their token format on most endpoints, but Basic is what their
  # current docs prescribe and it's the safer default.
  class JiraClient
    class AuthMissing   < StandardError; end
    class ConfigMissing < StandardError; end
    class FetchFailed   < StandardError; end

    DEFAULT_FIELDS = %w[summary status assignee priority updated issuetype].freeze

    attr_reader :endpoint, :email

    def initialize(endpoint: nil, email: nil, token: nil)
      cfg          = load_config
      @endpoint    = (endpoint || ENV["AIKIQ_JIRA_ENDPOINT"] || cfg["endpoint"]).to_s.sub(%r{/+\z}, "")
      @email       = email || ENV["AIKIQ_JIRA_EMAIL"] || cfg["user"]
      @token       = token || ENV["AIKIQ_JIRA_API_TOKEN"] || cfg.dig("authentication", "token")

      raise ConfigMissing, "no Jira endpoint (set AIKIQ_JIRA_ENDPOINT or write ~/.jira.d/config.yml)" if @endpoint.nil? || @endpoint.empty?
      raise AuthMissing,   "no Jira email (set AIKIQ_JIRA_EMAIL or `user:` in ~/.jira.d/config.yml)" if @email.nil? || @email.to_s.empty?
      raise AuthMissing,   "no Jira API token (set AIKIQ_JIRA_API_TOKEN or `authentication.token` in ~/.jira.d/config.yml)" if @token.nil? || @token.to_s.empty?
    end

    # Hits /rest/api/3/search/jql. Returns the parsed JSON Hash:
    # { "issues" => [...], "nextPageToken" => "...", "isLast" => bool }
    # Caller is responsible for paging — most CLI uses don't need it.
    def search_jql(jql:, fields: DEFAULT_FIELDS, max_results: 25, next_page_token: nil)
      params = {
        "jql"        => jql,
        "fields"     => Array(fields).join(","),
        "maxResults" => max_results
      }
      params["nextPageToken"] = next_page_token if next_page_token
      get("/rest/api/3/search/jql", params)
    end

    # GET /rest/api/3/issue/{key}. fields can narrow the payload (e.g. just
    # "fixVersions") to keep the round trip small.
    def get_issue(key, fields: nil)
      params = {}
      params["fields"] = Array(fields).join(",") if fields && !Array(fields).empty?
      get("/rest/api/3/issue/#{key}", params)
    end

    # PUT /rest/api/3/issue/{key}. `fields` is a Hash mirroring Jira's
    # `{"fields": {...}}` body. Returns nil on the canonical 204 success.
    def update_issue(key, fields:)
      put("/rest/api/3/issue/#{key}", { "fields" => fields })
    end

    # GET /rest/api/3/project/{key}/versions. Returns an Array of version
    # Hashes (id, name, released, archived, releaseDate?). No paging — Jira
    # returns the full list in one go.
    def list_versions(project)
      get("/rest/api/3/project/#{project}/versions", {})
    end

    # GET /rest/api/3/user/search?query=... — substring match against
    # displayName / email. Returns an Array of user Hashes.
    def search_users(query, max_results: 10)
      get("/rest/api/3/user/search", { "query" => query, "maxResults" => max_results })
    end

    private

    def load_config
      path = File.expand_path("~/.jira.d/config.yml")
      return {} unless File.exist?(path)
      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end

    def get(path, params)
      handle("GET", path) do
        HTTParty.get("#{@endpoint}#{path}", headers: auth_headers, query: params, timeout: 30)
      end
    end

    def put(path, body)
      handle("PUT", path) do
        HTTParty.put(
          "#{@endpoint}#{path}",
          headers: auth_headers.merge("Content-Type" => "application/json"),
          body:    body.to_json,
          timeout: 30
        )
      end
    end

    def auth_headers
      {
        "Authorization" => "Basic " + Base64.strict_encode64("#{@email}:#{@token}"),
        "Accept"        => "application/json"
      }
    end

    def handle(verb, path)
      resp = yield
      case resp.code
      when 204
        nil
      when 401, 403
        raise AuthMissing, "Jira returned #{resp.code} — token invalid or lacks permission for #{verb} #{path}"
      when 400
        msg = parse_error(resp.body) || resp.body.to_s[0, 200]
        raise FetchFailed, "#{verb} #{path} → 400 Bad Request: #{msg}"
      when 404
        raise FetchFailed, "#{verb} #{path} → 404 Not Found (issue/project key wrong, or token can't see it)"
      when 410
        raise FetchFailed, "#{verb} #{path} → 410 Gone (endpoint removed by Atlassian — code is out of date)"
      when (200..299)
        resp.parsed_response
      else
        msg = parse_error(resp.body) || resp.body.to_s[0, 200]
        raise FetchFailed, "#{verb} #{path} → HTTP #{resp.code}: #{msg}"
      end
    rescue HTTParty::Error, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => e
      raise FetchFailed, "Jira request failed (#{e.class}): #{e.message}"
    end

    def parse_error(body)
      return nil if body.nil? || body.empty?
      data = JSON.parse(body)
      Array(data["errorMessages"]).join("; ").then { |s| s.empty? ? nil : s }
    rescue JSON::ParserError
      nil
    end
  end
end

# lib/maciekos/sentry_client.rb
require "httparty"
require "json"
require "time"

module Maciekos
  # Read-only Sentry API client for QA investigation. Wraps the four public
  # endpoints sufficient to pull an issue + its latest event with stacktrace
  # and breadcrumbs into a session for downstream LLM workflows.
  #
  # Auth: SENTRY_AUTH_TOKEN env var, or ~/.config/maciekos/sentry_auth_token.
  # Org/project default to SENTRY_ORG / SENTRY_PROJECT env vars.
  #
  # Stability: Sentry's public API is contractually backward-compatible —
  # attributes can only be added, never removed or retyped. Building against
  # the four endpoints below is safe; private/experimental endpoints are not
  # used here.
  class SentryClient
    DEFAULT_BASE_URL = "https://sentry.io/api/0"

    class AuthMissing      < StandardError; end
    class ConfigMissing    < StandardError; end
    class FetchFailed      < StandardError; end

    def initialize(org: nil, project: nil, base_url: nil)
      @org      = (org      || ENV["SENTRY_ORG"]).to_s
      @project  = (project  || ENV["SENTRY_PROJECT"]).to_s
      @base_url = (base_url || ENV["SENTRY_BASE_URL"] || DEFAULT_BASE_URL).chomp("/")
      @token    = load_token
    end

    attr_reader :org, :project, :base_url

    # When `project` is set: GET /projects/{org}/{project}/issues/
    # When `project` is absent: GET /organizations/{org}/issues/ (org-wide)
    # statsPeriod accepts e.g. "24h", "14d" (self-hosted) or "1h"/"7d" (SaaS).
    def list_issues(limit: 25, since: "24h", query: nil)
      raise ConfigMissing, "Sentry org required (set SENTRY_ORG or pass --org)" if @org.empty?
      params = { limit: limit, statsPeriod: since }
      params[:query] = query if query && !query.empty?
      path =
        if @project.empty?
          "/organizations/#{@org}/issues/"
        else
          "/projects/#{@org}/#{@project}/issues/"
        end
      get(path, params)
    end

    def project_set?
      !@project.empty?
    end

    # GET /organizations/{org}/projects/
    # Lists all projects the token can see in the org. Used by
    # `aikiq sentry-projects` so the user doesn't need to remember slugs.
    def list_projects
      raise ConfigMissing, "Sentry org required (set SENTRY_ORG or pass --org)" if @org.empty?
      get("/organizations/#{@org}/projects/")
    end

    # GET /issues/{issue_id}/
    # issue_id may be the numeric Sentry id or a short id like "MY-PROJ-AB".
    # Short ids get resolved to numeric via the shortids endpoint first —
    # /issues/{shortid}/ returns 404 on at least Sentry self-hosted older
    # than ~24.5; the shortids resolver works on every supported version.
    def fetch_issue(issue_id)
      get("/issues/#{resolve_id(issue_id)}/")
    end

    # GET /issues/{issue_id}/events/latest/
    # Returns the most recent event, with `entries` array carrying exception
    # frames, breadcrumbs, request data, etc.
    def fetch_latest_event(issue_id)
      get("/issues/#{resolve_id(issue_id)}/events/latest/")
    end

    # Numeric ids pass through unchanged. Short ids (anything non-numeric)
    # resolve via /organizations/{org}/shortids/{short_id}/, which returns
    # the parent group object containing the numeric id. Cached per client
    # instance so fetch_issue + fetch_latest_event on the same id make one
    # resolution call, not two.
    def resolve_id(issue_id)
      raw = issue_id.to_s
      return raw if raw =~ /\A\d+\z/
      @resolved ||= {}
      return @resolved[raw] if @resolved.key?(raw)

      raise ConfigMissing, "Sentry org required to resolve short id (set SENTRY_ORG or pass --org)" if @org.empty?

      data    = get("/organizations/#{@org}/shortids/#{raw}/")
      numeric = data.is_a?(Hash) ? (data.dig("group", "id") || data["groupId"]) : nil
      raise FetchFailed, "could not resolve short id #{raw} — response had no group.id" unless numeric

      @resolved[raw] = numeric.to_s
    end

    private

    def load_token
      return ENV["SENTRY_AUTH_TOKEN"] if ENV["SENTRY_AUTH_TOKEN"] && !ENV["SENTRY_AUTH_TOKEN"].empty?
      keyfile = File.expand_path("~/.config/maciekos/sentry_auth_token")
      if File.exist?(keyfile)
        token = File.read(keyfile).strip
        return token unless token.empty?
      end
      raise AuthMissing, "set SENTRY_AUTH_TOKEN or write the token to ~/.config/maciekos/sentry_auth_token"
    end

    def get(path, params = {})
      url     = "#{@base_url}#{path}"
      headers = { "Authorization" => "Bearer #{@token}", "Accept" => "application/json" }
      resp    = HTTParty.get(url, headers: headers, query: params, timeout: 30)
      if resp.code == 401
        raise AuthMissing, "Sentry returned 401 — token invalid or lacks scope"
      end
      if resp.code >= 400
        raise FetchFailed, "GET #{path} → HTTP #{resp.code}: #{resp.body.to_s[0, 200]}"
      end
      resp.parsed_response
    end
  end
end

require "json"

class ScenarioScopeExtractor
  WORKFLOWS = %w[
    jira_summary
    jira_review
    code_review
    jira_code_review
  ]

  def self.call(session_id: nil, project_root: nil)
    outputs = {}
    WORKFLOWS.each do |wf|
      raw = fetch_output(wf, session_id, project_root)
      outputs[wf] = normalize(raw) if raw
    rescue => e
      STDERR.puts "[Scope Extractor] Warning: Failed to fetch #{wf}: #{e.message}"
    end
    
    result = build_result(outputs)
    puts result.to_json
  end

  def self.extract(session_id: nil, project_root: nil)
    outputs = {}
    WORKFLOWS.each do |wf|
      raw = fetch_output(wf, session_id, project_root)
      outputs[wf] = normalize(raw) if raw
    rescue => e
      STDERR.puts "[Scope Extractor] Warning: Failed to fetch #{wf}: #{e.message}"
    end
    
    build_result(outputs)
  end

  def self.fetch_output(name, session_id, project_root)
    return nil unless session_id && project_root
    
    session_path = File.join(project_root, "sessions", session_id, "outputs")
    return nil unless Dir.exist?(session_path)
    
    # Find files matching pattern: <seq>_<workflow_id>.ext or <seq>_<workflow_id>_suffix.ext
    all_files = Dir.glob(File.join(session_path, "*"))
    files = all_files.select do |filepath|
      basename = File.basename(filepath)
      # Strict match to avoid matching 'jira_code_review' when looking for 'code_review'
      basename =~ /^\d+_#{Regexp.escape(name)}(\.|_)/
    end
    
    return nil if files.empty?
    
    # Sort by numeric prefix to get latest
    latest_file = files.sort_by do |filename|
      File.basename(filename).split('_').first.to_i
    end.last
    
    STDERR.puts "[Scope Extractor] Found #{name}: #{File.basename(latest_file)}"
    
    File.read(latest_file)
  end

  def self.normalize(raw)
    if raw.include?("```json")
      start = raw.index('{')
      ending = raw.rindex('}')
      raise "No JSON content found" unless start && ending
      json_str = raw[start..ending]
      JSON.parse(json_str)
    elsif raw.include?("### ")
      parse_markdown(raw)
    else
      JSON.parse(raw)
    end
  rescue JSON::ParserError => e
    raise "Parse error: #{e.message}"
  end

  def self.parse_markdown(text)
    sections = {}
    current_section = nil
    current_content = []
    
    lines = text.split("\n")
    lines.each do |line|
      if line.start_with?("### ")
        if current_section
          sections[current_section] = process_section_content(current_content)
        end
        current_section = line[4..-1].strip.downcase.gsub(/\s+/, "_").gsub(/[^\w_]/, "")
        current_content = []
      elsif current_section
        current_content << line
      end
    end
    
    if current_section
      sections[current_section] = process_section_content(current_content)
    end
    
    mapped = {}
    map = {
      "ticket_key" => "ticket_key",
      "title" => "title",
      "overall_assessment" => "overall_assessment",
      "findings" => "findings",
      "missing_information" => "missing_information",
      "testing_requirements" => "testing_requirements",
      "risks" => "risks",
      "release_readiness" => "release_readiness"
    }
    
    sections.each do |k, v|
      mk = map[k]
      mapped[mk] = v if mk
    end
    
    mapped
  end

  def self.process_section_content(lines)
    lines = lines.drop_while(&:empty?).reverse.drop_while(&:empty?).reverse
    non_empty = lines.reject(&:empty?)
    
    if non_empty.all? { |l| l.strip.start_with?("- ") || l.strip.start_with?("* ") }
      return non_empty.map { |l| l.strip.sub(/^[-*]\s+/, "") }
    end
    
    lines.join("\n").strip
  end

  def self.build_result(outputs)
    jira_summary = outputs["jira_summary"] || {}
    jira_review = outputs["jira_review"] || {}
    code_review = outputs["code_review"] || {}
    jira_code_review = outputs["jira_code_review"] || {}
    
    base_behaviors = []
    if jira_review["testing_requirements"].is_a?(Array)
      base_behaviors.concat(jira_review["testing_requirements"])
    end
    if jira_summary["decisions"].is_a?(Array)
      base_behaviors.concat(jira_summary["decisions"])
    end
    base_behaviors.compact!
    base_behaviors.uniq!
    
    gap_texts = []
    missing_info = jira_review["missing_information"]
    risks = jira_review["risks"]
    
    gap_texts.concat(missing_info) if missing_info.is_a?(Array)
    gap_texts << missing_info if missing_info.is_a?(String)
    gap_texts.concat(risks) if risks.is_a?(Array)
    gap_texts << risks if risks.is_a?(String)
    
    gap_string = gap_texts.join(" ")
    
    authorization_gap = gap_string.include?("Authorization") || gap_string.include?("capability") || gap_string.include?("entity_config") || gap_string.include?("permission")
    nil_safety_gap = gap_string.include?("missing") || gap_string.include?("absent") || gap_string.include?("nil") || gap_string.include?("uuid") || gap_string.include?("identifier")
    external_api_gap = gap_string.include?("API") || gap_string.include?("external") || gap_string.include?("SoftFair") || gap_string.include?("Fondsfinanz")
    permission_layering_gap = gap_string.include?("child_user") || gap_string.include?("parent_user") || gap_string.include?("group")
    
    # Fix this condition - add parentheses for clarity
    general_spec_gap = false
    has_missing_info = missing_info && (
      (missing_info.respond_to?(:empty?) && !missing_info.empty?) ||
      !missing_info.respond_to?(:empty?)
    )
    if has_missing_info && !(authorization_gap || nil_safety_gap || external_api_gap || permission_layering_gap)
      general_spec_gap = true
    end
    
    code_risk_detected = false
    if code_review["issues"].is_a?(Array)
      code_risk_detected = code_review["issues"].any? do |issue|
        issue.is_a?(Hash) && issue["data"].is_a?(Array) && ["robustness", "security", "bug"].include?(issue["data"][1])
      end
    end
    
    external_api_involved = false
    
    ext_sync = jira_summary["external_partner_synchronization"]
    if ext_sync.is_a?(Array) && !ext_sync.empty?
      external_api_involved = true
    elsif ext_sync.is_a?(String) && !ext_sync.empty?
      external_api_involved = true
    end
    
    external_api_involved ||= gap_string.include?("API")
    
    if code_review["issues"].is_a?(Array)
      code_review["issues"].each do |issue|
        if issue.is_a?(Hash) && issue["message"].is_a?(String) && issue["message"].include?("client")
          external_api_involved = true
        end
      end
    end
    
    extra_scope = jira_code_review["extra_scope"]
    if extra_scope.is_a?(Array) && extra_scope.any? { |s| s.include?("API") }
      external_api_involved = true
    elsif extra_scope.is_a?(String) && extra_scope.include?("API")
      external_api_involved = true
    end
    
    alignment_status = jira_code_review["alignment_status"] || "aligned"
    
    scenario_priority = case alignment_status
    when "misaligned" then "high"
    when "partially_aligned" then "medium"
    else "normal"
    end
    
    if code_risk_detected && external_api_involved
      scenario_priority = "high"
    end
    
    ticket_key = jira_summary["ticket_key"] || jira_review["ticket_key"] || ""
    
    {
      "ticket_key" => ticket_key,
      "scenario_priority" => scenario_priority,
      "alignment_status" => alignment_status,
      "base_behaviors" => base_behaviors,
      "invariants" => {
        "authorization_negative" => true,
        "nil_safety" => true,
        "child_user_layering" => true,
        "external_api_resilience" => true
      },
      "gaps_detected" => {
        "authorization_gap" => authorization_gap,
        "nil_safety_gap" => nil_safety_gap,
        "external_api_gap" => external_api_gap,
        "permission_layering_gap" => permission_layering_gap,
        "general_spec_gap" => general_spec_gap
      },
      "code_risk_detected" => code_risk_detected,
      "external_api_involved" => external_api_involved
    }
  end
end

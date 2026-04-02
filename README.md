# Code Analysis & Improvements

## Current Issues

1. **Inconsistent multi-file handling**: The FILEBLOCK formatting has inconsistent indentation
2. **No model selection per workflow**: Workflows hardcode model tiers but can't easily specify preferred models
3. **Missing intelligent file type detection**: All files treated identically
4. **No directory support**: Can't ingest entire folders
5. **Workflow YAML schema incomplete**: `model_preferences` vs `model` vs `default_model` inconsistency
6. **No file size limits**: Large files could blow up prompts
7. **Error handling**: Limited validation of file paths and content

## Improved Implementation

### 1. Enhanced CLI (`lib/maciekos/cli.rb`)

```ruby
# lib/maciekos/cli.rb
require "thor"
require "yaml"
require "securerandom"
require "digest"
require "time"
require_relative "openrouter_adapter"
require_relative "workflow_engine"
require_relative "evaluator"
require_relative "file_processor"

module Maciekos
  class CLI < Thor
    package_name "maciekos"

    def self.exit_on_failure?
      true
    end

    default_task :run_workflow

    desc "run_workflow WORKFLOW [PROMPT]", "Run a workflow with optional prompt and files"
    long_desc <<-LONGDESC
      Execute an AI workflow with flexible input options:

      Examples:
        aikiq code-review "Analyze this"
        aikiq code-review --file diff.patch
        aikiq code-review --file diff1.patch --file diff2.patch
        aikiq code-review "Explain" --file diff.patch --file logs.txt
        aikiq code-review --dir ./src --pattern "*.rb"
        aikiq code-review --model anthropic/claude-3.5-sonnet

      Options:
        --file, -f: Add individual files (repeatable)
        --dir, -d: Add all files from directory (repeatable)
        --pattern: Filter pattern for --dir (e.g., "*.rb,*.js")
        --model: Override workflow's default model
        --max-file-size: Skip files larger than N bytes (default: 1MB)
        --dry-run: Preview without API call
    LONGDESC
    option :file, type: :array, aliases: "-f", desc: "File path(s) to include"
    option :dir, type: :array, aliases: "-d", desc: "Directory path(s) to include"
    option :pattern, type: :string, default: "*", desc: "File pattern for --dir (e.g., '*.rb,*.js')"
    option :model, type: :string, desc: "Override model (e.g., anthropic/claude-3.5-sonnet)"
    option :max_file_size, type: :numeric, default: 1_048_576, desc: "Max file size in bytes (default: 1MB)"
    option :dry_run, type: :boolean, default: false
    option :compress, type: :boolean, default: false, desc: "Compress large file contents"

    def run_workflow(workflow_id = nil, prompt = nil)
      raise Thor::Error, "workflow_id required. Usage: aikiq <workflow-id> [PROMPT] [OPTIONS]" if workflow_id.nil?

      # Initialize file processor
      processor = FileProcessor.new(
        max_size: options[:max_file_size],
        compress: options[:compress]
      )

      # Collect all file paths
      file_paths = []
      file_paths.concat(options[:file]) if options[:file]

      if options[:dir]
        patterns = options[:pattern].split(",").map(&:strip)
        options[:dir].each do |dir_path|
          raise Thor::Error, "Directory not found: #{dir_path}" unless Dir.exist?(dir_path)
          processor.collect_from_directory(dir_path, patterns).each do |path|
            file_paths << path
          end
        end
      end

      # Remove duplicates and validate
      file_paths.uniq!
      file_paths.each do |path|
        raise Thor::Error, "File not found: #{path}" unless File.exist?(path)
      end

      # Build prompt parts
      parts = []

      # Inline prompt (optional)
      parts << prompt.strip if prompt && !prompt.strip.empty?

      # Process files
      unless file_paths.empty?
        file_contents = processor.process_files(file_paths)
        parts << file_contents
      end

      raise Thor::Error, "No input provided. Supply PROMPT, --file, or --dir." if parts.empty?

      prompt_text = parts.join("\n\n")

      # Load and prepare workflow
      engine = WorkflowEngine.new
      wf = engine.load_workflow(workflow_id)
      
      # Allow workflow to specify model override
      model_override = options[:model] || wf.dig("vars", "default_model")
      
      prepared_prompt, system_message = engine.prepare_prompt(wf, prompt_text)

      if options[:dry_run]
        puts "=" * 80
        puts "DRY RUN: #{workflow_id}"
        puts "=" * 80
        puts "Model: #{model_override || 'workflow default'}"
        puts "Files: #{file_paths.length}"
        puts "Prompt length: #{prepared_prompt.length} chars"
        puts "\nFirst 1000 chars:"
        puts prepared_prompt[0..1000]
        puts "\n" + "=" * 80
        return
      end

      # Generate run ID
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      hash = Digest::SHA256.hexdigest(prepared_prompt)[0, 8]
      run_id = "#{ts}-#{hash}"

      # Prepare adapter options
      adapter_opts = { system_message: system_message }
      
      if model_override
        adapter_opts[:models_override] = [model_override]
      end

      # Execute workflow
      adapter = OpenRouterAdapter.new
      model_prefs = wf.dig("vars", "model_preferences") || []
      responses = adapter.call_with_fanout(model_prefs, prepared_prompt, adapter_opts)

      # Evaluate and select
      evaluator = Evaluator.new(wf)
      result = evaluator.validate_and_select(responses, run_id)

      # Save artifact
      artifact_path = engine.write_artifact(workflow_id, run_id, result)
      
      # Display results
      display_results(result, artifact_path, file_paths)
    end

    desc "list", "List available workflows"
    def list
      engine = WorkflowEngine.new
      workflows = engine.list_workflows
      
      puts "\nAvailable workflows:\n\n"
      workflows.each do |wf_id|
        begin
          wf = engine.load_workflow(wf_id)
          desc = wf["description"] || "(no description)"
          model = wf.dig("vars", "default_model") || "default"
          puts "  #{wf_id.ljust(20)} - #{desc} [#{model}]"
        rescue => e
          puts "  #{wf_id.ljust(20)} - (error loading: #{e.message})"
        end
      end
      puts "\n"
    end

    desc "models WORKFLOW", "Show available models for a workflow"
    def models(workflow_id)
      engine = WorkflowEngine.new
      wf = engine.load_workflow(workflow_id)
      
      puts "\nModels for workflow: #{workflow_id}\n\n"
      
      default = wf.dig("vars", "default_model")
      puts "Default: #{default}\n\n" if default
      
      prefs = wf.dig("vars", "model_preferences")
      if prefs
        puts "Model preferences:"
        prefs.each_with_index do |pref, idx|
          puts "  #{idx + 1}. Tier: #{pref['tier']}, Fanout: #{pref.fetch('fanout', true)}"
        end
      end
      puts "\n"
    end

    private

    def display_results(result, artifact_path, file_paths)
      puts "\n" + "=" * 80
      puts "RESULTS"
      puts "=" * 80
      puts "Artifact: #{artifact_path}"
      puts "Files processed: #{file_paths.length}"
      
      selected = result[:selected] || result["selected"]
      
      if selected && (selected[:text] || selected["text"])
        model = selected[:model] || selected["model"] || "unknown"
        text = (selected[:text] || selected["text"]).to_s
        
        puts "\nSelected model: #{model}"
        puts "Response length: #{text.length} chars"
        puts "\n" + "-" * 80
        puts text
        puts "-" * 80
      else
        evaluated = result[:evaluated] || result["evaluated"]
        if evaluated && evaluated.any?
          top = evaluated.max_by { |r| r[:score].to_f }
          puts "\nTop response: #{top[:model]} (score: #{top[:score]})"
          puts "\n" + "-" * 80
          puts (top[:text] || top["text"] || top[:error] || "(no output)")
          puts "-" * 80
        else
          puts "\nNo usable response. Check artifact for details."
        end
      end
      puts "=" * 80 + "\n"
    end
  end
end
```

### 2. New File Processor (`lib/maciekos/file_processor.rb`)

```ruby
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

    # Collect files from directory with pattern matching
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

    # Process multiple files into formatted string
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
      
      # Check if content is binary
      if content.encoding == Encoding::ASCII_8BIT && content.count("\x00") > 0
        return "[Binary file: #{File.basename(path)}, #{File.size(path)} bytes]"
      end
      
      # Compress if needed
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
```

### 3. Enhanced Workflow Schema (`workflows/examples/code-review.yaml`)

```yaml
# workflows/examples/code-review.yaml
id: code-review
version: 2025-12-07
description: "Multi-model code review with structured issue detection"

# Model configuration
vars:
  # Default model (can be overridden with --model)
  default_model: "anthropic/claude-3.5-sonnet"
  
  # Alternative: Use model preferences with tiers
  model_preferences:
    - tier: fast
      fanout: true
    - tier: smart
      fanout: false
  
  # Validation rules
  validators:
    - name: "json-schema"
      schema: "./validators/code_review_schema.json"
  
  # Scoring weights
  scoring:
    structure: 0.5
    correctness: 0.3
    style: 0.2
  
  pass_threshold: 0.75
  max_tokens: 2000
  temperature: 0.1

# System message
system_message: |
  You are an expert code reviewer. Analyze the provided code changes and:
  1. Identify potential bugs, security issues, and performance problems
  2. Suggest improvements for readability and maintainability
  3. Provide specific, actionable feedback
  4. Format output as structured JSON with severity levels

# Prompt template
instructions: |
  Review the following code changes and provide structured feedback.
  
  Return a JSON object with this structure:
  {
    "summary": "Brief overview of changes",
    "issues": [
      {
        "severity": "high|medium|low",
        "category": "bug|security|performance|style",
        "line": 123,
        "message": "Description of issue",
        "suggestion": "Recommended fix"
      }
    ],
    "approval": "approved|changes_requested|needs_discussion"
  }

# Processing steps
steps:
  - name: prepare_prompt
    type: template
    
  - name: call_models
    type: openrouter_call
    timeout: 30
    
  - name: validate_and_score
    type: validate_and_score
    
  - name: select_best
    type: selector
    strategy: "highest_score"
    fallback: "escalate_next_tier"

# Output configuration
outputs:
  format: json
  path: "./artifacts/{{id}}_{{run_id}}.json"
  include_metadata: true
```

### 4. Config with Model Aliases (`config/openrouter.yaml`)

```yaml
# config/openrouter.yaml
openrouter:
  endpoint: "https://openrouter.ai/api/v1"
  timeout_seconds: 60
  system_message: "You are Claude Sonnet 4.5, a large language model from Anthropic."
  
  provider:
    allow_fallbacks: true
    require_parameters: false
    order: ["Anthropic", "OpenAI", "Google"]

# Model tier aliases
model_aliases:
  fast:
    - "anthropic/claude-3-haiku"
    - "google/gemini-2.0-flash-lite-001"
    - "meta-llama/llama-3.1-8b-instruct"
  
  smart:
    - "anthropic/claude-3.5-sonnet"
    - "openai/gpt-4-turbo"
    - "google/gemini-2.0-flash-thinking-exp"
  
  advanced:
    - "anthropic/claude-3-opus"
    - "openai/gpt-4"
    - "google/gemini-exp-1206"
  
  cheap:
    - "meta-llama/llama-3.3-70b-instruct"
    - "google/gemini-2.0-flash-lite-001"
  
  medium:
    - "anthropic/claude-3.5-sonnet"
    - "meta-llama/llama-3.3-70b-instruct"
  
  strong:
    - "anthropic/claude-3-opus"
    - "openai/gpt-4-turbo"
```

### 5. Updated README

````markdown
# maciekOS — AI Workflow Runner

`aikiq` is a deterministic, multi-model AI workflow execution system.

---

## Installation

```bash
git clone <repo>
cd maciekOS
bundle install
sudo ln -sf "$(pwd)/bin/maciekos" /usr/local/bin/aikiq
chmod +x bin/maciekos
```

---

## Configuration

### Environment Variables (.envrc)

```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
export MACIEKOS_LOG_CURL=1              # Optional: log API requests
export MACIEKOS_LOG_CURL_SHOW_KEY=1     # Optional: show full API key in logs
```

Then: `direnv allow`

### Alternative: Config File

```bash
mkdir -p ~/.config/maciekos
echo "sk-or-v1-..." > ~/.config/maciekos/openrouter_api_key
chmod 600 ~/.config/maciekos/openrouter_api_key
```

---

## Usage

### Basic Examples

```bash
# Inline prompt only
aikiq code-review "Review this code for security issues"

# Single file
aikiq code-review --file changes.patch

# Multiple files
aikiq code-review --file diff1.patch --file diff2.patch --file notes.txt

# Inline prompt + files
aikiq code-review "Focus on security" --file api.rb --file tests.rb

# Directory ingestion
aikiq code-review --dir ./src --pattern "*.rb"

# Multiple directories with pattern
aikiq code-review --dir ./lib --dir ./app --pattern "*.rb,*.erb"
```

### Model Selection

```bash
# Use workflow default
aikiq code-review --file changes.patch

# Override with specific model
aikiq code-review --file changes.patch --model anthropic/claude-3.5-sonnet

# Override with fast model
aikiq code-review --file changes.patch --model meta-llama/llama-3.3-70b-instruct
```

### Advanced Options

```bash
# Dry run (preview without API call)
aikiq code-review "Test" --file code.rb --dry-run

# Large file handling
aikiq code-review --file huge.log --compress --max-file-size 5000000

# List workflows
aikiq list

# Show workflow models
aikiq models code-review
```

---

## Workflow Files

Workflows are YAML files in `workflows/` or `workflows/examples/`.

### Model Configuration Options

#### Option 1: Single Default Model

```yaml
vars:
  default_model: "anthropic/claude-3.5-sonnet"
```

#### Option 2: Model Tiers (Multi-Model)

```yaml
vars:
  model_preferences:
    - tier: fast       # Try fast models first
      fanout: true     # Call all models in tier
    - tier: smart      # Escalate if needed
      fanout: false    # Use only first model
```

#### Option 3: Explicit Model List

```yaml
vars:
  models:
    - id: "anthropic/claude-3.5-sonnet"
      weight: 1.0
    - id: "openai/gpt-4-turbo"
      weight: 0.8
```

---

## File Processing Features

### Intelligent Type Detection

Files are automatically labeled by type:

- **DIFF** - `.diff`, `.patch`
- **SOURCE** - `.rb`, `.py`, `.js`, etc.
- **CONFIG** - `.yaml`, `.json`, `.toml`
- **LOG** - `.log`, `.txt`
- **MARKDOWN** - `.md`

### Size Limits

```bash
# Default: 1MB max per file
aikiq code-review --file large.log

# Custom limit: 5MB
aikiq code-review --file large.log --max-file-size 5000000
```

### Content Compression

```bash
# Compress files >10KB (shows first/last 100 lines)
aikiq code-review --file huge.log --compress
```

---

## Output

Results saved to: `artifacts/<workflow>_<timestamp>-<hash>.json`

Structure:

```json
{
  "run_id": "20251207T123456Z-abc123",
  "workflow": "code-review",
  "timestamp": "2025-12-07T12:34:56Z",
  "selected": {
    "model": "anthropic/claude-3.5-sonnet",
    "text": "...",
    "score": 0.95,
    "latency": 2.3
  },
  "evaluated": [...],
  "metadata": {
    "files_processed": 3,
    "total_chars": 12543
  }
}
```

---

## Model Aliases

Defined in `config/openrouter.yaml`:

- **fast**: Claude Haiku, Gemini Flash, Llama 8B
- **smart**: Claude Sonnet, GPT-4 Turbo, Gemini Pro
- **advanced**: Claude Opus, GPT-4
- **cheap**: Llama 70B, Gemini Flash
- **medium**: Claude Sonnet, Llama 70B
- **strong**: Claude Opus, GPT-4

---

## Deterministic Behavior

- Files processed in sorted order
- Model responses sorted by model ID
- Identical inputs → identical outputs (at temperature=0)
- Reproducible artifact hashes

---

## Example Workflow

```bash
# Review all Ruby files in a project
aikiq code-review \
  --dir ./app \
  --dir ./lib \
  --pattern "*.rb" \
  --model anthropic/claude-3.5-sonnet \
  > review.txt
```

---

## Troubleshooting

### "File not found"
- Check file path is correct
- Use absolute paths or paths relative to current directory

### "No input provided"
- Must provide either inline prompt, --file, or --dir

### "Workflow not found"
- Run `aikiq list` to see available workflows
- Check `workflows/` and `workflows/examples/` directories

### API Errors
- Verify `OPENROUTER_API_KEY` is set
- Check `~/.config/maciekos/openrouter_api_key` permissions
- Enable curl logging: `export MACIEKOS_LOG_CURL=1`

---

### symlink script
```sh
# Remove old symlink
sudo rm -f /usr/local/bin/aikiq

# Create wrapper that forces bundle path
sudo tee /usr/local/bin/aikiq > /dev/null << 'WRAPPER'
#!/bin/bash
# maciekOS wrapper - forces bundler context

# Find the maciekOS installation
MACIEKOS_ROOT="/home/maciej/Documents/maciekOS"

# Verify installation exists
if [[ ! -d "$MACIEKOS_ROOT" ]]; then
  echo "Error: maciekOS not found at $MACIEKOS_ROOT"
  exit 1
fi

# Force bundle to use maciekOS Gemfile
export BUNDLE_GEMFILE="$MACIEKOS_ROOT/Gemfile"

# Execute the actual script
exec "$MACIEKOS_ROOT/bin/maciekos" "$@"
WRAPPER

sudo chmod +x /usr/local/bin/aikiq
```

```sh
# Create wrapper scripts
sudo tee /usr/local/bin/aikiq > /dev/null << 'WRAPPER'
#!/bin/bash
# maciekOS wrapper - forces bundler context

# Find the maciekOS installation
MACIEKOS_ROOT="/home/maciej/Documents/maciekOS"

# Verify installation exists
if [[ ! -d "$MACIEKOS_ROOT" ]]; then
  echo "Error: maciekOS not found at $MACIEKOS_ROOT"
  exit 1
fi

# Force bundle to use maciekOS Gemfile
export BUNDLE_GEMFILE="$MACIEKOS_ROOT/Gemfile"

# Execute the actual script
exec "$MACIEKOS_ROOT/bin/maciekos" "$@"
WRAPPER

sudo tee /usr/local/bin/aikiq-repl > /dev/null << 'WRAPPER'
#!/bin/bash
# maciekOS REPL wrapper

MACIEKOS_ROOT="/home/maciej/Documents/maciekOS"

if [[ ! -d "$MACIEKOS_ROOT" ]]; then
  echo "Error: maciekOS not found at $MACIEKOS_ROOT"
  exit 1
fi

export BUNDLE_GEMFILE="$MACIEKOS_ROOT/Gemfile"

exec "$MACIEKOS_ROOT/bin/maciekos-repl" "$@"
WRAPPER

# Make both executable
sudo chmod +x /usr/local/bin/aikiq
sudo chmod +x /usr/local/bin/aikiq-repl
```

## Shell Completion

To enable shell completion:

### Bash
Add to your `~/.bashrc`:
```bash
source /path/to/maciekOS/completions/aikiq.bash

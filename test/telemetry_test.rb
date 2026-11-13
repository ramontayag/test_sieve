# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/test_sieve/telemetry/metadata"
require_relative "../lib/test_sieve/telemetry/writer"

class TelemetryTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("telemetry")
    @path = File.join(@root, "nested/outcomes.jsonl")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_writer_appends_records_that_can_be_read_before_run_end
    writer = TestSieve::Telemetry::Writer.new(output_path: @path)
    assert_equal [], writer.records
    record = writer.append("schema_version" => 1, "type" => "run_start", "run_id" => "one")
    assert_equal "one", record.payload["run_id"]
    assert_equal ["run_start"], writer.records.map { |item| item.payload["type"] }
    writer.append("schema_version" => 1, "type" => "run_end", "completed" => true)
    assert_equal ["run_start", "run_end"], writer.records.map { |item| item.payload["type"] }
    assert_equal 2, File.readlines(@path).size
  end

  def test_record_rejects_invalid_json_schema_types_outcomes_and_identity
    ["bad", "[]", '{"schema_version":2,"type":"run_start"}', '{"schema_version":1,"type":"unknown"}'].each do |line|
      assert_raises(ArgumentError) { TestSieve::Telemetry::Record.parse(line) }
    end
    assert_raises(ArgumentError) { TestSieve::Telemetry::Record.new(type: "test_result", outcome: "unknown", test_id: "A#test_a") }
    assert_raises(ArgumentError) { TestSieve::Telemetry::Record.new(type: "test_result", outcome: "pass") }
    assert_equal "pass", TestSieve::Telemetry::Record.new(type: "test_result", outcome: "pass", test_id: "A#test_a").payload["outcome"]
  end

  def test_metadata_preserves_environment_contract_and_is_cached
    env = {
      "TEST_SUITE_NAME" => "system-shard-1", "TEST_SHARD_TOTAL" => "2", "TEST_SHARD_INDEX" => "1",
      "GITHUB_RUN_ID" => "77", "GITHUB_RUN_ATTEMPT" => "3", "GITHUB_WORKFLOW" => "CI",
      "GITHUB_REPOSITORY" => "owner/project", "GITHUB_RUNNER_NAME" => "ci-runner", "SEED" => "123",
      "TEST_BROWSER_NAME" => "chrome", "TEST_BROWSER_VERSION" => "100", "TEST_DRIVER_VERSION" => "100",
      "TEST_SELENIUM_VERSION" => "4", "TEST_FIXTURE_IMAGE" => "fixture:1"
    }
    metadata = TestSieve::Telemetry::Metadata.new(env: env, app_root: @root, git_status: false)
    payload = metadata.run_metadata
    assert_equal "system-shard-1", payload["suite"]
    assert_equal "shard-1-of-2", payload["shard"]
    assert_equal 123, payload["seed"]
    assert_equal "77", payload["workflow_run_id"]
    assert_equal "3", payload["workflow_run_attempt"]
    assert_equal "CI", payload["workflow"]
    assert_equal "owner/project", payload["repository"]
    assert_equal "ci-runner", payload["runner"]
    assert_equal "fixture:1", payload["fixture_image"]
    assert_equal false, payload["dirty"]
    assert_equal "unavailable", payload["commit"]
    assert_equal({"name" => "chrome", "version" => "100", "driver" => "100", "selenium" => "4"}, payload["browser"])
    env["SEED"] = "456"
    assert_same payload, metadata.run_metadata
    assert_equal 123, metadata.run_metadata["seed"]
  end

  def test_metadata_uses_explicit_git_root_and_runner_override
    git("init", "-q")
    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "Fixture")
    metadata = TestSieve::Telemetry::Metadata.new(env: {"TEST_ENV_NUMBER" => "2", "SEED" => "123"}, app_root: @root, runner: "custom")
    assert_equal git("rev-parse", "HEAD").strip, metadata.run_metadata["commit"]
    assert_equal false, metadata.run_metadata["dirty"]
    assert_equal 2, metadata.run_metadata["seed"]
    assert_equal "custom", metadata.run_metadata["runner"]
    File.write(File.join(@root, "untracked"), "dirty")
    assert_equal true, TestSieve::Telemetry::Metadata.new(env: {}, app_root: @root).run_metadata["dirty"]
  end

  def test_telemetry_can_be_required_without_minitest_or_rails
    code = <<~RUBY
      require "test_sieve/telemetry/metadata"
      require "test_sieve/telemetry/writer"
      abort "loaded framework" if defined?(Minitest) || defined?(Rails)
      metadata = TestSieve::Telemetry::Metadata.new(env: {}, app_root: #{JSON.generate(@root)})
      abort "seed" unless metadata.run_metadata["seed"] == "unavailable"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", code)
    assert status.success?, output
  end

  private

  def git(*args)
    output, status = Open3.capture2e("git", *args, chdir: @root)
    assert status.success?, output
    output
  end
end

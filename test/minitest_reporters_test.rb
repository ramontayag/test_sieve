# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/test_sieve/minitest"

class MinitestReportersTest < Minitest::Test
  Metadata = Struct.new(:run_metadata)

  def setup
    @root = Dir.mktmpdir("reporters")
    @path = File.join(@root, "nested/outcomes.jsonl")
    @metadata = Metadata.new({"repository" => "owner/project", "workflow_run_id" => "77",
      "workflow_run_attempt" => "3", "suite" => "unit", "shard" => "shard-1-of-2", "seed" => 123})
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_outcomes_include_execution_order_identity_relative_paths_and_run_boundaries
    reporter = outcome_reporter
    reporter.start
    reporter.record(result("pass"))
    reporter.record(result("fail", failures: [Minitest::Assertion.new("failed")]))
    reporter.record(result("error", failures: [RuntimeError.new("boom")]))
    reporter.record(result("skip", failures: [Minitest::Skip.new("later")]))
    reporter.report
    records = outcome_records
    assert_equal %w[run_start test_result test_result test_result test_result run_end], records.map { |record| record["type"] }
    tests = records[1..4]
    assert_equal %w[pass fail error skip], tests.map { |record| record["outcome"] }
    assert_equal [1, 2, 3, 4], tests.map { |record| record["execution_index"] }
    assert_equal "ExampleTest#pass", tests[0]["test_id"]
    assert_equal "test/example_test.rb", tests[0]["file"]
    assert_equal 10, tests[0]["line"]
    assert_equal 0.123456789012345, tests[0]["duration_seconds"]
    assert_equal "RuntimeError", tests[2]["error_class"]
    assert_equal "boom", tests[2]["error_message"]
    assert_equal "77/3/unit/shard-1-of-2", records.first["run_id"]
    assert_equal "owner/project/77/3/unit/shard-1-of-2", records.first["run_key"]
    assert_equal @metadata.run_metadata, records.first["metadata"]
    assert_equal true, records.last["completed"]
    assert_equal false, records.last["interrupted"]
    assert_equal @path, reporter.output_path
  end

  def test_failure_messages_redact_locations_and_emails_and_limit_length
    failure = Minitest::Assertion.new("/home/private/test.rb:42 person@example.invalid " + "x" * 2100)
    failure.set_backtrace(["/source/test.rb:42"])
    reporter = outcome_reporter
    reporter.record(result("fail", failures: [failure]))
    record = outcome_records.first
    assert record["error_message"].start_with?("<location> <email> ")
    assert_equal 2000, record["error_message"].size
    assert_equal ["/source/test.rb:42"], record["backtrace"]
  end

  def test_interruption_marks_run_incomplete_without_losing_flushed_results
    reporter = outcome_reporter
    reporter.start
    reporter.record(result("pass"))
    assert_equal %w[run_start test_result], outcome_records.map { |record| record["type"] }
    reporter.interrupted!
    reporter.report
    assert_equal false, outcome_records.last["completed"]
    assert_equal true, outcome_records.last["interrupted"]
    assert_equal false, reporter.passed?
  end

  def test_outside_paths_remain_absolute_and_relative_paths_use_explicit_root
    reporter = outcome_reporter
    reporter.record(result("outside", file: "#{@root}-other/test.rb"))
    reporter.record(result("relative", file: "test/relative.rb"))
    assert_equal ["#{@root}-other/test.rb", "test/relative.rb"], outcome_records.map { |record| record["file"] }
  end

  def test_outcome_write_errors_warn_at_start_record_and_end_without_raising
    File.write(@path = File.join(@root, "blocker"), "file")
    reporter = outcome_reporter(path: File.join(@path, "outcomes.jsonl"))
    _, stderr = capture_io do
      reporter.start
      reporter.record(result("fail", failures: [Minitest::Assertion.new("failed")]))
      reporter.report
    end
    assert_equal 3, stderr.lines.size
    assert_includes stderr, "TestSieve::Minitest::OutcomeReporter"
    assert reporter.passed?
  end

  def test_a_recovered_write_error_cannot_claim_complete_recording
    reporter = outcome_reporter
    reporter.start
    directory = File.dirname(@path)
    saved = "#{directory}-saved"
    File.rename(directory, saved)
    File.write(directory, "not a directory")
    _, stderr = capture_io { reporter.record(result("lost")) }
    assert_includes stderr, "could not record lost"
    File.delete(directory)
    File.rename(saved, directory)
    reporter.report

    assert_equal %w[run_start run_end], outcome_records.map { |record| record.fetch("type") }
    assert_equal false, outcome_records.last.fetch("completed")
    assert_equal false, outcome_records.last.fetch("interrupted")
    assert reporter.passed?
  end

  def test_timings_preserve_metadata_precision_and_sort_slowest_first_with_tiebreakers
    reporter = timing_reporter
    with_clock_time(1000.0, 1508.123) do
      reporter.start
      reporter.record(result("z", time: 0.5, file: "test/b.rb", line: 20))
      reporter.record(result("y", time: 0.5, file: "test/b.rb", line: 10))
      reporter.record(result("b", time: 0.5, file: "test/a.rb", klass: "ZTest"))
      reporter.record(result("b", time: 0.5, file: "test/a.rb", klass: "ATest"))
      reporter.record(result("a", time: 0.5, file: "test/a.rb", klass: "ATest"))
      reporter.record(result("slow", time: 2.0, failures: [Minitest::Assertion.new("failed")]))
      reporter.record(result("precise"))
      reporter.report
    end
    payload = JSON.parse(File.read(@path))
    assert_equal "unit", payload["suite"]
    assert_equal @metadata.run_metadata, payload["metadata"]
    assert_in_delta 508.123, payload["duration_seconds"], 0.001
    assert_equal 7, payload["test_count"]
    assert_equal %w[slow a b b y z precise], payload["tests"].map { |test| test["test_name"] }
    assert_equal 0.123456789012345, payload["tests"].last["duration_seconds"]
    assert_equal "test/example_test.rb", payload["tests"].first["file"]
  end

  def test_timing_report_without_start_has_nil_duration
    timing_reporter.report
    payload = JSON.parse(File.read(@path))
    assert_nil payload["duration_seconds"]
    assert_equal [], payload["tests"]
    assert_equal 0, payload["test_count"]
  end

  def test_timing_write_failure_warns_without_raising
    File.write(File.join(@root, "blocker"), "file")
    previous = $VERBOSE
    [nil, false, true].each do |verbosity|
      reporter = timing_reporter(path: File.join(@root, "blocker/timings.json"))
      $VERBOSE = verbosity
      stderr = capture_warnings { reporter.report }
      assert_includes stderr, "TestSieve::Minitest::TimingReporter"
      assert_includes stderr, "blocker/timings.json"
      assert $VERBOSE.equal?(verbosity)
      assert reporter.passed?
    end
  ensure
    $VERBOSE = previous
  end

  def test_timing_creates_parent_directory_and_records_full_precision_for_only_failed_result
    reporter = timing_reporter
    reporter.start
    reporter.record(result("failed", failures: [Minitest::Assertion.new("failed")]))
    reporter.report
    assert File.directory?(File.dirname(@path))
    payload = JSON.parse(File.read(@path))
    assert_equal 1, payload["test_count"]
    assert_equal({"class_name" => "ExampleTest", "test_name" => "failed", "file" => "test/example_test.rb",
      "line" => 10, "duration_seconds" => 0.123456789012345}, payload["tests"].first)
  end

  def test_timing_keeps_outside_paths_and_supports_original_app_root_keyword
    reporter = TestSieve::Minitest::TimingReporter.new(output_path: @path, suite_name: "unit", app_root: @root)
    reporter.record(result("inside", file: File.join(@root, "test/a.rb")))
    reporter.record(result("outside", file: "/other/test/b.rb"))
    reporter.report
    assert_equal @root, reporter.app_root
    assert_equal ["/other/test/b.rb", "test/a.rb"], JSON.parse(File.read(@path))["tests"].map { |test| test["file"] }.sort
  end

  def test_outcome_supports_original_app_root_keyword_and_default_metadata
    reporter = TestSieve::Minitest::OutcomeReporter.new(output_path: @path, app_root: @root)
    reporter.record(result("inside"))
    assert_equal "test/example_test.rb", outcome_records.first["file"]
    assert_equal "unavailable", outcome_records.first.dig("metadata", "commit")
  end

  private

  def with_clock_time(*values)
    original = Minitest.method(:clock_time)
    clock = values.each
    Minitest.define_singleton_method(:clock_time) { clock.next }
    yield
  ensure
    Minitest.define_singleton_method(:clock_time, original)
  end

  def capture_warnings
    previous = $VERBOSE
    $VERBOSE = true
    capture_io { yield }.last
  ensure
    $VERBOSE = previous
  end

  def outcome_reporter(path: @path)
    TestSieve::Minitest::OutcomeReporter.new(output_path: path, metadata: @metadata, root: @root)
  end

  def timing_reporter(path: @path)
    TestSieve::Minitest::TimingReporter.new(output_path: path, suite_name: "unit", metadata: @metadata, root: @root)
  end

  def result(name, failures: [], file: File.join(@root, "test/example_test.rb"), line: 10, time: 0.123456789012345, klass: "ExampleTest")
    result = Minitest::Result.new(name)
    result.klass = klass
    result.time = time
    result.source_location = [file, line]
    result.failures = failures
    result
  end

  def outcome_records
    TestSieve::Telemetry::Writer.new(output_path: @path).records.map(&:payload)
  end
end

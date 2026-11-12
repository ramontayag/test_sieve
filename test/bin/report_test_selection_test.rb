# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "yaml"
require_relative "../support/project"

class ReportTestSelectionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "test/support/bin/report-test-selection")

  def setup
    @root = Dir.mktmpdir("selection-comparison")
    git("init", "-q")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    owners = %w[ selected omitted ].to_h do |name|
      files = [ "test/#{name}_test.rb", "test/system/#{name}_test.rb" ]
      ([ "app/#{name}.rb" ] + files).each { |path| write(path, "") }
      [ name, { "sources" => [ "app/#{name}.rb" ], "inputs" => [], "notes" => name,
        "tests" => { "unit" => [ files[0] ], "learner" => [ files[1] ] } } ]
    end
    write("config/test_ownership.yml", YAML.dump("version" => 1, "default" => "full_suite", "broad_changes" => [], "owners" => owners))
    @base = commit
    write("app/selected.rb", "changed")
    @head = commit
    @selection = TestOwnership::Selector.new(policy: FixtureProject::POLICY, root: @root, base: @base, head: @head, comparison: "push").call
    @expected = { "repository" => "owner/repo", "workflow_run_id" => "123", "workflow_run_attempt" => "2",
      "commit" => @head, "system_shards" => [ "shard-0-of-2", "shard-1-of-2" ], "runs" => [] }
    collect("unit", "unavailable", %w[ selected omitted ])
    collect("system", "shard-0-of-2", [ "selected" ])
    collect("system", "shard-1-of-2", [ "omitted" ])
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_compares_normalized_outputs_and_preserves_omitted_failures
    report, stderr, status = compare
    assert status.success?, stderr
    assert_equal "complete", report["status"]
    %w[ unit system ].each do |suite|
      %w[ selected omitted ].each do |group|
        results = report.fetch("results").fetch(suite).fetch(group)
        assert_equal %w[ error fail pass skip ], results.map { |result| result.fetch("outcome") }.sort
        failure = results.find { |result| result["outcome"] == "fail" }
        assert_includes failure["error_message"], "Screenshot comparison failed"
        assert_equal "result_failure", failure.dig("screenshot", "association")
        assert_equal "unknown", results.find { |result| result["outcome"] == "error" }.dig("screenshot", "association")
      end
    end
    assert_equal @head, report.dig("selection", "source_sha")
    assert_match(/\A[0-9a-f]{64}\z/, report.dig("selection", "rules_digest"))
    assert_equal 8, report.fetch("artifacts").size
    assert_includes stderr, "complete"
    assert_includes stderr, "omitted: 2 failures/errors"
    assert_equal report, compare.first
  end

  def test_rejects_missing_stale_or_claimed_selection_identity
    %w[ source_sha base_sha ownership_digest base_ownership_digest rules_digest ].each do |field|
      original = @selection[field]
      @selection[field] = "a" * 64
      assert_inconclusive
      @selection[field] = original
    end
    @selection["unit_files"] = [ "test/omitted_test.rb" ]
    assert_inconclusive
  end

  def test_requires_unit_and_every_expected_system_shard_once
    original = @expected["runs"].dup
    @expected["runs"].pop
    assert_inconclusive
    @expected["runs"] = original + [ original.last ]
    assert_inconclusive
    @expected["runs"] = original
    @expected["system_shards"] = []
    assert_inconclusive
  end

  def test_rejects_wrong_attempt_dirty_commit_and_missing_timing_metadata
    path = @expected["runs"].first["timings"]
    original = JSON.parse(File.read(path))
    [ nil, original["metadata"].merge("workflow_run_attempt" => "1"),
      original["metadata"].merge("dirty" => true), original["metadata"].merge("commit" => @base) ].each do |metadata|
      File.write(path, JSON.generate(original.merge("metadata" => metadata)))
      assert_inconclusive
    end
  end

  def test_rejects_missing_malformed_truncated_interrupted_and_duplicate_outcomes
    path = @expected["runs"].first["outcomes"]
    original = File.read(path)
    records = original.lines.map { |line| JSON.parse(line) }
    interrupted = records.map(&:dup)
    interrupted.last["interrupted"] = true
    variants = [ "", "{\n", "null\n", original.chomp, jsonl(records[0...-1]), jsonl(interrupted), original + original,
      jsonl([ records.first, records[1], *records[1..] ]) ]
    variants.each do |content|
      File.write(path, content)
      assert_inconclusive
    end
    File.delete(path)
    assert_inconclusive
  end

  def test_rejects_conflicting_timings_and_unsafe_or_wrong_suite_paths
    path = @expected["runs"].first["timings"]
    original = JSON.parse(File.read(path))
    [ { "file" => "../test/selected_test.rb" }, { "file" => "test/system/selected_test.rb" },
      { "duration_seconds" => -1 }, { "duration_seconds" => 99 }, { "line" => 999 },
      { "class_name" => "Other" } ].each do |change|
      altered = Marshal.load(Marshal.dump(original))
      altered["tests"].first.merge!(change)
      File.write(path, JSON.generate(altered))
      assert_inconclusive
    end
    original["tests"] << original["tests"].first
    original["test_count"] += 1
    File.write(path, JSON.generate(original))
    assert_inconclusive
  end

  def test_rejects_consistently_forged_paths
    change_run(0) do |records, timings|
      records[1]["file"] = "test/absent_test.rb"
      timings["tests"].find { |test| test["test_name"] == records[1]["test_name"] && test["class_name"] == records[1]["test_class"] }["file"] = "test/absent_test.rb"
    end
    assert_inconclusive
  end

  def test_rejects_duplicate_tests_across_shards
    change_run(2) do |records, timings|
      records[1...-1].each do |record|
        record["test_class"] = "system_selected"
        record["test_id"] = "system_selected##{record['test_name']}"
        record["file"] = "test/system/selected_test.rb"
      end
      timings["tests"].each do |test|
        test["class_name"] = "system_selected"
        test["file"] = "test/system/selected_test.rb"
      end
    end
    assert_inconclusive
  end

  def test_rejects_duplicate_json_keys_and_wrong_outcome_identity
    path = @expected["runs"].first["outcomes"]
    original = File.read(path)
    records = original.lines.map { |line| JSON.parse(line) }
    %w[ run_id run_key test_id execution_index timestamp ].each do |field|
      altered = Marshal.load(Marshal.dump(records))
      altered[1][field] = "wrong"
      File.write(path, jsonl(altered))
      assert_inconclusive
    end
    File.write(path, original.sub('"schema_version":1', '"schema_version":2,"schema_version":1'))
    assert_inconclusive
  end

  def test_malformed_timing_documents_are_inconclusive_json_not_command_crashes
    path = @expected["runs"].first["timings"]
    [ "{\n", "null", "[]", '{"tests":false}', '{"suite":"unit","suite":"system"}' ].each do |content|
      File.write(path, content)
      assert_inconclusive
    end
  end

  def test_retains_valid_omitted_failures_when_timings_are_missing_corrupt_or_inconsistent
    run = @expected["runs"].last
    original = JSON.parse(File.read(run["timings"]))
    inconsistent = original.merge("test_count" => 999)
    [ nil, "{\n", JSON.generate(inconsistent) ].each do |content|
      File.delete(run["timings"]) if File.exist?(run["timings"])
      File.write(run["timings"], content) if content
      report = assert_inconclusive
      results = report.fetch("results").fetch("system").fetch("omitted")
      assert_equal %w[ error fail pass skip ], results.map { |result| result.fetch("outcome") }.sort
      failure = results.find { |result| result["outcome"] == "fail" }
      assert_equal "result_failure", failure.dig("screenshot", "association")
      assert_includes failure.dig("screenshot", "evidence").join, "Screenshot comparison failed"
      refute report["reasons"].any? { |reason| reason.include?("missing test files") }
    end
  end

  def test_rejects_a_whole_file_missing_from_consistent_outcomes_and_timings
    change_run(0) do |records, timings|
      records.reject! { |record| record["file"] == "test/omitted_test.rb" }
      records[1...-1].each_with_index { |record, index| record["execution_index"] = index + 1 }
      timings["tests"].reject! { |test| test["file"] == "test/omitted_test.rb" }
      timings["test_count"] = timings["tests"].size
    end
    report = assert_inconclusive
    assert_equal [ "missing test files: test/omitted_test.rb" ], report["reasons"]
    assert_equal 4, report.dig("results", "unit", "selected").size
  end

  def test_serial_system_run_uses_existing_unavailable_shard_identity
    @expected["runs"] = @expected["runs"].first(1)
    @expected["system_shards"] = [ "unavailable" ]
    collect("system", "unavailable", %w[ selected omitted ])
    report, stderr, status = compare
    assert status.success?, stderr
    assert_equal "complete", report["status"]
  end

  private
    def change_run(index)
      run = @expected["runs"][index]
      records = File.readlines(run["outcomes"]).map { |line| JSON.parse(line) }
      timings = JSON.parse(File.read(run["timings"]))
      yield records, timings
      File.write(run["outcomes"], jsonl(records))
      File.write(run["timings"], JSON.generate(timings))
    end

    def collect(suite, shard, groups)
      metadata = @expected.slice("repository", "workflow_run_id", "workflow_run_attempt", "commit")
        .merge("suite" => suite, "shard" => shard, "dirty" => false)
      outcomes = File.join(@root, "#{suite}-#{shard}.jsonl")
      timings = File.join(@root, "#{suite}-#{shard}.json")
      run_id = [ @expected["workflow_run_id"], @expected["workflow_run_attempt"], suite, shard ].join("/")
      envelope = { "schema_version" => 1, "metadata" => metadata, "timestamp" => "2026-01-01T00:00:00Z",
        "run_id" => run_id, "run_key" => "#{@expected['repository']}/#{run_id}" }
      records = [ envelope.merge("type" => "run_start") ]
      tests = []
      groups.each do |group|
        %w[ pass fail error skip ].each do |outcome|
          file = [ "test", ("system" if suite == "system"), "#{group}_test.rb" ].compact.join("/")
          result = { "test_name" => "test_#{outcome}", "test_class" => "#{suite}_#{group}",
            "file" => file, "line" => 1, "duration_seconds" => 0.25, "outcome" => outcome,
            "test_id" => "#{suite}_#{group}#test_#{outcome}", "execution_index" => records.size }
          if %w[ fail error ].include?(outcome)
            message = outcome == "fail" ? "Screenshot comparison failed: example.diff.png" : "browser disconnected"
            result.merge!("error_class" => "RuntimeError", "error_message" => message, "backtrace" => [])
          end
          records << envelope.merge(result).merge("type" => "test_result")
          tests << result.slice("test_name", "file", "line", "duration_seconds").merge("class_name" => result["test_class"])
        end
      end
      records << envelope.merge("type" => "run_end", "completed" => true, "interrupted" => false)
      File.write(outcomes, jsonl(records))
      File.write(timings, JSON.generate("metadata" => metadata, "suite" => suite, "duration_seconds" => 1.0,
        "tests" => tests, "test_count" => tests.size))
      @expected["runs"] << { "suite" => suite, "shard" => shard, "outcomes" => outcomes, "timings" => timings }
    end

    def jsonl(records)
      records.map { |record| JSON.generate(record) }.join("\n") + "\n"
    end

    def compare
      write("selection.json", JSON.generate(@selection))
      write("expected.json", JSON.generate(@expected))
      stdout, stderr, status = Open3.capture3(BIN, "--root", @root,
        "--selection", File.join(@root, "selection.json"), "--expected", File.join(@root, "expected.json"), chdir: ROOT)
      [ JSON.parse(stdout), stderr, status ]
    end

    def assert_inconclusive
      report, stderr, status = compare
      refute status.success?, stderr
      assert_equal "inconclusive", report["status"]
      refute_empty report["reasons"]
      report
    end

    def write(path, content)
      absolute = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
    end

    def git(*args)
      output, error, status = Open3.capture3("git", *args, chdir: @root)
      raise error unless status.success?
      output.strip
    end

    def commit
      git("add", ".")
      git("commit", "-qm", "snapshot")
      git("rev-parse", "HEAD")
    end
end

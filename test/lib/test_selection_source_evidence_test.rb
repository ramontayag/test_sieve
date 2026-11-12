# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"

require_relative "../support/project"

# Covers how the comparison treats a recorded result whose source file does not
# match the suite that executed it, and a recorded result whose source file
# cannot be traced to a repository file at all.
#
# The two cases are different problems:
#
#   * A cross-suite result points at a real repository test file that another
#     suite executed. The result is real evidence, so it is kept with its
#     execution identity. It cannot stand in for the suite that owns the file.
#   * An unowned result points outside the repository (a gem, for example).
#     The result is real evidence too, but it cannot be attributed to any file,
#     so it cannot satisfy file coverage.
class TestSelectionSourceEvidenceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @root = Dir.mktmpdir("selection-source-evidence")
    @artifacts = Dir.mktmpdir("selection-source-evidence-artifacts")
    @output = Dir.mktmpdir("selection-source-evidence-output")
    git("init", "-q")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    write("app/host.rb", "changed")
    write("test/unit_test.rb", "")
    write("test/system/system_test.rb", "")
    owners = {
      "host" => {
        "sources" => [ "app/host.rb" ], "inputs" => [], "notes" => "host",
        "tests" => { "unit" => [ "test/unit_test.rb" ], "learner" => [ "test/system/system_test.rb" ] }
      }
    }
    write("config/test_ownership.yml", YAML.dump("version" => 1, "default" => "full_suite", "broad_changes" => [], "owners" => owners))
    @base = commit
    write("app/host.rb", "changed again")
    @head = commit
  end

  def teardown
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(@artifacts)
    FileUtils.remove_entry(@output)
  end

  # A unit file executed inside the system job keeps its execution identity and
  # is classified by the file list that owns it.
  def test_unit_file_executed_by_the_system_job_keeps_its_execution_identity
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "system"),
        outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    system_results = report.dig("results", "system")
    total = system_results.values.flatten
    unit_result = total.find { |result| result["file"] == "test/unit_test.rb" }
    refute_nil unit_result
    assert_equal "system", unit_result["execution_suite"]
    assert_equal "unit", unit_result["source_suite"]
    assert_equal "complete", report.fetch("status")
  end

  # The system job executes a unit file. The selection classifies by the file
  # list that owns the source, so the result must not land in the system group.
  def test_unit_file_executed_by_the_system_job_is_classified_by_the_owning_file_list
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "system"),
        outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    unit_results = report.dig("results", "unit").values.flatten
    system_results = report.dig("results", "system").values.flatten
    assert unit_results.any? { |result| result["file"] == "test/unit_test.rb" && result["selection_group"] == "selected" }
    assert system_results.any? { |result| result["file"] == "test/unit_test.rb" && result["selection_group"] == "selected" }
    assert_equal "complete", report.fetch("status")
  end

  # A unit file executed by the system job does not stand in for the unit run.
  # The unit artifact is still required.
  def test_unit_file_executed_by_the_system_job_does_not_satisfy_the_missing_unit_artifact
    report = compare_with(
      unit: [],
      system: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "system") ]
    )

    assert_equal "inconclusive", report.fetch("status")
    assert report.fetch("reasons").any? { |reason| reason.include?("unit/unavailable") },
      report.fetch("reasons").inspect
  end

  # A unit file executed by the system job does not satisfy unit file coverage.
  def test_unit_file_executed_by_the_system_job_does_not_satisfy_unit_file_coverage
    report = compare_with(
      unit: [],
      system: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "system") ]
    )

    reason = report.fetch("reasons").find { |entry| entry.start_with?("missing test files:") }
    refute_nil reason, report.fetch("reasons").inspect
    assert_includes reason, "test/unit_test.rb"
  end

  # A result whose source cannot be traced to a repository file is kept, marked
  # unowned, and does not satisfy coverage for any file.
  def test_result_without_a_repository_source_is_kept_as_unowned
    gem_path = "/usr/local/bundle/ruby/3.4.0/gems/shoulda-context-2.0.0/lib/shoulda/context/context.rb"
    report = compare_with(
      unit: [ outcome(gem_path, "QuestionTest", "test_: Question should belong to task", "unit") ],
      system: [ outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    unit_results = report.dig("results", "unit").values.flatten
    owned = unit_results.reject { |result| result["source"] == "unowned" }
    unowned = unit_results.select { |result| result["source"] == "unowned" }
    assert_empty owned
    assert_equal 1, unowned.size
    assert_equal "test_: Question should belong to task", unowned.first["test_name"]
    assert_equal "pass", unowned.first["outcome"]
    assert_equal "unit", unowned.first["execution_suite"]
  end

  # An unowned result cannot stand in for a repository file that never ran.
  def test_unowned_result_does_not_satisfy_file_coverage
    gem_path = "/usr/local/bundle/ruby/3.4.0/gems/shoulda-context-2.0.0/lib/shoulda/context/context.rb"
    report = compare_with(
      unit: [ outcome(gem_path, "QuestionTest", "test_: Question should belong to task", "unit") ],
      system: [ outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    reason = report.fetch("reasons").find { |entry| entry.start_with?("missing test files:") }
    refute_nil reason, report.fetch("reasons").inspect
    assert_includes reason, "test/unit_test.rb"
  end

  # An unowned result is reported, not silently dropped.
  def test_unowned_result_is_reported_as_a_reason
    gem_path = "/usr/local/bundle/ruby/3.4.0/gems/shoulda-context-2.0.0/lib/shoulda/context/context.rb"
    report = compare_with(
      unit: [ outcome(gem_path, "QuestionTest", "test_: Question should belong to task", "unit") ],
      system: [ outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    assert report.fetch("reasons").any? { |reason| reason.include?("unowned") },
      report.fetch("reasons").inspect
  end

  # The same test id in the unit run and system run is separate execution
  # evidence. Both remain visible, without making complete own-suite coverage
  # inconclusive.
  def test_same_test_id_in_two_suites_keeps_both_results
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_shared_thing", "unit") ],
      system: [ outcome("test/unit_test.rb", "UnitTest", "test_shared_thing", "system"),
        outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    assert_equal "complete", report.fetch("status")
    unit_ids = report.dig("results", "unit").values.flatten.map { |result| result["test_id"] }
    system_ids = report.dig("results", "system").values.flatten.map { |result| result["test_id"] }
    assert_includes unit_ids, "UnitTest#test_shared_thing"
    assert_includes system_ids, "UnitTest#test_shared_thing"
  end

  # A missing timing artifact must not discard the outcome stream, including
  # the failure evidence it carries.
  def test_missing_timing_keeps_the_outcome_stream_including_failures
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [ outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ],
      missing_timing: "unit"
    )

    unit_results = report.dig("results", "unit").values.flatten
    assert_equal 1, unit_results.size
    assert_equal "inconclusive", report.fetch("status")
  end

  # The same test id twice inside one execution suite is a duplicate. The
  # repeat is rejected, and the report says so.
  def test_duplicate_test_id_inside_one_execution_suite_is_rejected
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [
        [ outcome("test/system/system_test.rb", "SystemTest", "test_shared_thing", "system") ],
        [ outcome("test/system/system_test.rb", "SystemTest", "test_shared_thing", "system") ]
      ]
    )

    assert_equal "inconclusive", report.fetch("status")
    assert report.fetch("reasons").any? { |reason| reason.include?("duplicate test across shards") },
      report.fetch("reasons").inspect
  end

  # One duplicate does not discard the rest of the stream.
  def test_duplicate_test_id_keeps_the_other_results_from_the_same_suite
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [
        [
          outcome("test/system/system_test.rb", "SystemTest", "test_first_thing", "system"),
          outcome("test/system/system_test.rb", "SystemTest", "test_shared_thing", "system")
        ],
        [
          outcome("test/system/system_test.rb", "SystemTest", "test_shared_thing", "system")
        ]
      ]
    )

    system_ids = report.dig("results", "system", "selected").map { |result| result["test_id"] }
    assert_includes system_ids, "SystemTest#test_first_thing"
    assert_equal 1, system_ids.count("SystemTest#test_shared_thing")
  end

  def test_duplicate_executions_retain_failures_in_either_shard_order
    [ %w[ pass fail ], %w[ fail pass ] ].each do |statuses|
      records = statuses.map do |status|
        record = outcome("test/system/system_test.rb", "SystemTest", "test_shared_thing", "system", result: status)
        record.merge!("error_class" => "Minitest::Assertion", "error_message" => "screenshot differs", "backtrace" => [ "capture.diff.png" ]) if status == "fail"
        [ record ]
      end
      report = compare_with(unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ], system: records)

      assert_equal "inconclusive", report.fetch("status")
      duplicates = report.dig("results", "system", "rejected_duplicates")
      assert_equal 1, duplicates.size
      assert_equal statuses.last, duplicates.first.fetch("outcome")
      failure = report.dig("results", "system").values.flatten.find { |record| record["outcome"] == "fail" }
      assert_equal "screenshot differs", failure.fetch("error_message")
      assert_includes failure.dig("screenshot", "evidence"), "capture.diff.png"
      assert_includes TestSelection::Summary.new(report).to_markdown, "| system | rejected_duplicates | 1 | #{statuses.last == 'fail' ? 1 : 0} |"
    end
  end

  # A path that escapes the repository is rejected outright.
  def test_path_outside_the_repository_is_rejected
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [ outcome("../../etc/passwd_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    assert_equal "inconclusive", report.fetch("status")
    system_results = report.dig("results", "system").values.flatten
    assert_empty system_results
  end

  # A result attributed to a file that the tested commit does not contain is
  # rejected. It cannot invent coverage for a host file.
  def test_result_for_a_file_outside_the_tested_commit_is_rejected
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [ outcome("test/system/missing_test.rb", "SystemTest", "test_system_thing", "system") ]
    )

    assert_equal "inconclusive", report.fetch("status")
    assert report.fetch("reasons").any? { |reason| reason.include?("test source absent from tested commit") },
      report.fetch("reasons").inspect
  end

  # The outcome stream and the timing stream must describe the same test. A
  # disagreement about the source file is rejected.
  def test_conflicting_outcome_and_timing_attribution_is_rejected
    report = compare_with(
      unit: [ outcome("test/unit_test.rb", "UnitTest", "test_unit_thing", "unit") ],
      system: [ outcome("test/system/system_test.rb", "SystemTest", "test_system_thing", "system") ],
      timing_file_override: { "test/system/system_test.rb" => "test/system/other_test.rb" }
    )

    assert_equal "inconclusive", report.fetch("status")
    assert report.fetch("reasons").any? { |reason| reason.include?("timing results disagree with outcomes") },
      report.fetch("reasons").inspect
  end

  private
    def compare_with(unit:, system:, missing_timing: nil, timing_file_override: {})
      selection = write_selection
      shards = system_shards(system)
      @shard_count = shards.size
      expected = write_expected(unit: unit, shards: shards)
      write_artifacts(unit: unit, shards: shards, missing_timing: missing_timing, timing_file_override: timing_file_override)

      report = TestSelection::Comparison.new(policy: FixtureProject::POLICY, record_parser: FixtureProject::RECORD_PARSER, root: @root, selection: selection, expected: expected).call
      report
    end

    def write_selection
      selection = TestOwnership::Selector.new(policy: FixtureProject::POLICY, root: @root, base: @base, head: @head, comparison: "push").call
      selection["comparison"] = "push"
      path = File.join(@output, "selection.json")
      File.write(path, JSON.pretty_generate(selection))
      path
    end

    def write_expected(unit:, shards:)
      runs = [ { "suite" => "unit", "result_suite" => "unit", "shard" => "unavailable",
        "outcomes" => outcomes_path("unit"), "timings" => timing_path("unit") } ]
      shards.each_with_index do |_records, index|
        shard = "shard-#{index}-of-#{shards.size}"
        runs << { "suite" => "system-shard-#{index}", "result_suite" => "system", "shard" => shard,
          "outcomes" => outcomes_path("system-shard-#{index}"), "timings" => timing_path("system-shard-#{index}") }
      end
      expected = {
        "repository" => "owner/repo", "workflow_run_id" => "123", "workflow_run_attempt" => "2",
        "commit" => @head, "system_shards" => shards.each_index.map { |index| "shard-#{index}-of-#{shards.size}" },
        "runs" => runs
      }
      path = File.join(@output, "expected.json")
      File.write(path, JSON.pretty_generate(expected))
      path
    end

    def write_artifacts(unit:, shards:, missing_timing: nil, timing_file_override: {})
      write_outcomes("unit", unit)
      write_timings("unit", unit, timing_file_override)
      shards.each_with_index do |records, index|
        prefix = "system-shard-#{index}"
        write_outcomes(prefix, records)
        write_timings(prefix, records, timing_file_override)
      end
      return if missing_timing.nil?

      FileUtils.rm_f(timing_path(missing_timing))
    end

    # The system job runs one shard per recorded group. Each group is a list of
    # results that the shard executed.
    def system_shards(system)
      system.is_a?(Array) && system.first.is_a?(Array) ? system : [ system ]
    end

    def write_outcomes(prefix, records)
      path = outcomes_path(prefix)
      FileUtils.mkdir_p(File.dirname(path))
      lines = [ JSON.generate(envelope_record(prefix, "run_start")) ]
      records.each_with_index { |entry, index| lines << JSON.generate(outcome_record(prefix, entry, index + 1)) }
      lines << JSON.generate(envelope_record(prefix, "run_end").merge("completed" => true, "interrupted" => false))
      File.write(path, lines.join("\n") + "\n")
    end

    def envelope_record(prefix, type)
      {
        "schema_version" => 1, "type" => type,
        "run_id" => "123/2/#{prefix}/#{shard_for(prefix)}",
        "run_key" => "owner/repo/123/2/#{prefix}/#{shard_for(prefix)}",
        "timestamp" => "2026-11-10T11:08:32Z",
        "metadata" => metadata(prefix)
      }
    end

    def write_timings(prefix, records, overrides)
      path = timing_path(prefix)
      FileUtils.mkdir_p(File.dirname(path))
      tests = records.map do |entry|
        file = overrides.fetch(entry["file"], entry["file"])
        { "class_name" => entry["test_class"], "test_name" => entry["test_name"],
          "file" => file, "line" => entry["line"], "duration_seconds" => entry["duration_seconds"] }
      end
      payload = {
        "suite" => prefix == "unit" ? "unit" : prefix,
        "metadata" => metadata(prefix),
        "duration_seconds" => 1.0,
        "test_count" => tests.size,
        "tests" => tests
      }
      File.write(path, JSON.pretty_generate(payload))
    end

    def outcome_record(prefix, entry, execution_index)
      {
        "schema_version" => 1, "type" => "test_result",
        "run_id" => "123/2/#{prefix}/#{shard_for(prefix)}",
        "run_key" => "owner/repo/123/2/#{prefix}/#{shard_for(prefix)}",
        "timestamp" => "2026-11-10T11:08:33Z",
        "metadata" => metadata(prefix),
        "test_id" => "#{entry['test_class']}##{entry['test_name']}",
        "test_class" => entry["test_class"],
        "test_name" => entry["test_name"],
        "file" => entry["file"],
        "line" => entry["line"],
        "execution_index" => execution_index,
        "outcome" => entry["outcome"],
        "duration_seconds" => entry["duration_seconds"]
      }.merge(entry.slice("error_class", "error_message", "backtrace"))
    end

    def metadata(prefix)
      {
        "suite" => prefix, "shard" => shard_for(prefix), "seed" => 1, "commit" => @head,
        "dirty" => false, "runner" => "runner", "workflow_run_id" => "123", "workflow_run_attempt" => "2",
        "workflow" => "CI", "repository" => "owner/repo"
      }
    end

    # The shard identity the recorded run declares. It must match the expected
    # run exactly, because the evidence is bound to that identity.
    def shard_for(prefix)
      return "unavailable" if prefix == "unit"

      "shard-#{prefix.delete_prefix('system-shard-')}-of-#{@shard_count}"
    end

    def outcome(file, test_class, test_name, suite, shard: nil, result: "pass")
      { "file" => file, "test_class" => test_class, "test_name" => test_name, "line" => 1,
        "duration_seconds" => 0.1, "outcome" => result, "suite" => suite, "shard" => shard }
    end

    def outcomes_path(prefix)
      File.join(@artifacts, "tmp/test-results", prefix, "outcomes.jsonl")
    end

    def timing_path(prefix)
      File.join(@artifacts, "tmp/test-timings", "#{prefix}.json")
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

# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/test_sieve/rails"

class RailsAdapterTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rails-adapter")
    @unit = "test/with spaces_test.rb"
    @system = "test/system/flow_test.rb"
    [@unit, @system].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.write(File.join(@root, path), "")
    end
    File.write(File.join(@root, "runner.rb"), <<~RUBY)
      require "json"
      File.open("calls.jsonl", "a") { |file| file.puts JSON.generate(ARGV) }
      File.open("suites.jsonl", "a") { |file| file.puts JSON.generate(ENV.fetch("TEST_SUITE_NAME")) }
      Process.kill("TERM", Process.pid) if File.exist?("signal")
      exit(File.exist?("status") ? File.read("status").to_i : 0)
    RUBY
    @command = [RbConfig.ruby, "runner.rb"]
    @selection = { "mode" => "selected", "unit_files" => [@unit], "system_files" => [@system] }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_policy_defaults_and_overrides
    policy = TestSieve::Rails.policy
    assert_equal %w[unit system], policy.required_roles
    assert_equal ["test_ownership.yml", "config/test_sieve.rb", "Gemfile", "Gemfile.lock"], policy.rules
    assert policy.test?(@unit)
    assert policy.system?(@system)
    custom = TestSieve::Rails.policy(manifest_path: "ownership.yml", required_roles: ["fast"],
      role_suites: { "fast" => "unit" }, test_pattern: "checks/*.rb", system_pattern: "browser/*.rb", rules: ["deps"])
    assert custom.test?("checks/one.rb")
    assert_equal ["deps"], custom.rules
  end

  def test_runs_separate_processes_and_preserves_spaces_without_shell
    assert_equal 0, run_selection
    assert_equal [[@unit], [@system]], calls
  end

  def test_full_runs_explicit_inventory_with_custom_wrapper
    @selection["mode"] = "full"
    assert_equal 0, run_selection(suite: "system")
    assert_equal [[@system]], calls
  end

  def test_multi_suite_run_rejects_shared_reporter_output_paths_before_execution
    %w[TEST_OUTCOMES_OUTPUT TEST_TIMING_OUTPUT].each do |key|
      original = ENV[key]
      begin
        ENV[key] = "results.json"
        error = assert_raises(ArgumentError) { run_selection }
        assert_match(/--suite unit.*--suite system.*separate output paths/, error.message)
      ensure
        original ? ENV[key] = original : ENV.delete(key)
      end
    end
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_multi_suite_run_uses_group_names_instead_of_explicit_single_suite_name
    original = ENV["TEST_SUITE_NAME"]
    ENV["TEST_SUITE_NAME"] = "system-shard-0"
    assert_equal 0, run_selection
    assert_equal %w[unit system], File.readlines(File.join(@root, "suites.jsonl")).map { |line| JSON.parse(line) }
  ensure
    original ? ENV["TEST_SUITE_NAME"] = original : ENV.delete("TEST_SUITE_NAME")
  end

  def test_single_suite_allows_explicit_reporter_output_path
    original = ENV["TEST_OUTCOMES_OUTPUT"]
    ENV["TEST_OUTCOMES_OUTPUT"] = "results.jsonl"
    assert_equal 0, run_selection(suite: "unit")
    assert_equal [[@unit]], calls
  ensure
    original ? ENV["TEST_OUTCOMES_OUTPUT"] = original : ENV.delete("TEST_OUTCOMES_OUTPUT")
  end

  def test_child_suite_names_match_groups_and_preserve_explicit_ci_name
    original = ENV.delete("TEST_SUITE_NAME")
    assert_equal 0, run_selection
    assert_equal %w[unit system], File.readlines(File.join(@root, "suites.jsonl")).map { |line| JSON.parse(line) }
    ENV["TEST_SUITE_NAME"] = "system-shard-0"
    assert_equal 0, run_selection(suite: "system")
    assert_equal "system-shard-0", JSON.parse(File.readlines(File.join(@root, "suites.jsonl")).last)
  ensure
    original ? ENV["TEST_SUITE_NAME"] = original : ENV.delete("TEST_SUITE_NAME")
  end

  def test_default_command_uses_explicit_rails_files
    FileUtils.mkdir_p(File.join(@root, "bin"))
    File.write(File.join(@root, "bin/rails"), File.read(File.join(@root, "runner.rb")))
    assert_equal 0, TestSieve::Rails.run(selection: @selection, root: @root)
    assert_equal [["test", @unit], ["test", @system]], calls
  end

  def test_skips_empty_group_without_invoking_runner
    @selection["unit_files"] = []
    assert_equal 0, run_selection(suite: "unit")
    refute File.exist?(File.join(@root, "calls.jsonl"))
    assert_equal 0, run_selection
    assert_equal [[@system]], calls
  end

  def test_rejects_empty_inventory_and_malformed_selections_before_execution
    [nil, {}, { "mode" => "full", "unit_files" => [], "system_files" => [] },
      @selection.merge("system_files" => nil), @selection.merge("system_files" => [@unit])].each do |selection|
      assert_raises(ArgumentError) { run_selection(selection:) }
    end
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_rejects_unsafe_missing_and_outside_files_before_any_execution
    File.symlink("/etc/passwd", File.join(@root, "test/outside_test.rb"))
    ["--help", "../test.rb", "/etc/passwd", "test/a\n_test.rb", "test/../one.rb", "test/missing_test.rb",
      "test/outside_test.rb", "test/a_test.rb:1", "test/*_test.rb", 42].each do |path|
      selection = @selection.merge("system_files" => [path])
      assert_raises(ArgumentError) { run_selection(selection:) }
    end
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_propagates_failure_and_error_exit_codes_without_starting_second_group
    [1, 2, 17].each do |status|
      File.write(File.join(@root, "status"), status.to_s)
      assert_equal status, run_selection
    end
    assert_equal [[@unit], [@unit], [@unit]], calls
  end

  def test_propagates_child_signal
    File.write(File.join(@root, "signal"), "")
    assert_equal 128 + Signal.list.fetch("TERM"), run_selection
    assert_equal [[@unit]], calls
  end

  def test_rejects_invalid_suite_and_command
    assert_raises(ArgumentError) { run_selection(suite: "other") }
    assert_raises(ArgumentError) { run_selection(command: "echo") }
    assert_raises(ArgumentError) { run_selection(command: []) }
  end

  def test_missing_executable_is_nonzero
    refute_equal 0, run_selection(command: ["./absent-runner"])
  end

  def test_base_require_does_not_load_rails_adapter_or_framework
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rtest_sieve", "-e",
      'puts [defined?(::Rails), defined?(TestSieve::Rails)].inspect')
    assert status.success?, error
    assert_equal "[nil, nil]\n", output
  end

  private

  def run_selection(**options)
    TestSieve::Rails.run(**{ selection: @selection, root: @root, command: @command }.merge(options))
  end

  def calls
    File.readlines(File.join(@root, "calls.jsonl")).map { |line| JSON.parse(line) }
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require_relative "../lib/test_sieve/cli"

class CLITest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("sieve-cli")
    @out, @err = StringIO.new, StringIO.new
    git("init", "-q")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "Test")
    @unit, @system = "test/feature test_test.rb", "test/system/flow_test.rb"
    ["app/feature.rb", @unit, @system, "test/unowned_test.rb"].each { |path| write(path, "original") }
    @manifest = { "version" => 1, "default" => "full_suite", "broad_changes" => [],
      "owners" => { "feature" => { "sources" => ["app/feature.rb"], "inputs" => [], "notes" => "Feature",
        "tests" => { "unit" => [@unit], "system" => [@system] } } } }
    write_manifest
    write("runner.rb", 'require "json"; File.open("calls.jsonl", "a") { |f| f.puts JSON.generate(ARGV) }; exit 0')
    @base = commit
    write("app/feature.rb", "changed")
    @head = commit
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_select_defaults_to_head_and_pr_and_prints_json
    assert_equal 0, cli.call(["select", "--base", @base])
    result = JSON.parse(@out.string)
    assert_equal "selected", result["mode"]
    assert_equal "pr", result["comparison"]
    assert_equal [@unit], result["unit_files"]
    assert_equal [@system], result["system_files"]
  end

  def test_unknown_files_select_full_inventory_and_show_reasons
    write("unknown.txt", "unknown")
    commit
    assert_equal 0, cli.call(["select", "--base", @base, "--comparison", "push"])
    result = JSON.parse(@out.string)
    assert_equal "full", result["mode"]
    assert_includes result["reasons"], "unknown_path:unknown.txt"
    assert_equal [@unit, "test/unowned_test.rb"], result["unit_files"]
  end

  def test_dependency_and_default_config_changes_require_full_selection
    ["Gemfile", "Gemfile.lock", "config/test_sieve.rb"].each do |path|
      write(path, "changed")
      commit
      @out.truncate(0); @out.rewind
      assert_equal 0, cli.call(["select", "--base", @base])
      result = JSON.parse(@out.string)
      assert_equal "full", result["mode"]
      assert_includes result["reasons"], "ownership_rules_changed"
    end
  end

  def test_run_prints_decision_and_runs_exact_files
    assert_equal 0, cli.call(["run", "--base", @base])
    assert_equal [[@unit], [@system]], calls
    assert_match(/selected.*1 unit, 1 system/, @err.string)
  end

  def test_run_limits_suite_and_propagates_child_exit
    write("runner.rb", "exit 23")
    commit
    assert_equal 23, cli.call(["run", "--base", @base, "--suite", "system"])
  end

  def test_run_reports_shared_reporter_output_error_without_executing_children
    original = ENV["TEST_TIMING_OUTPUT"]
    ENV["TEST_TIMING_OUTPUT"] = "timings.json"
    refute_equal 0, cli.call(["run", "--base", @base])
    assert_match(/--suite unit.*--suite system/, @err.string)
    refute File.exist?(File.join(@root, "calls.jsonl"))
  ensure
    original ? ENV["TEST_TIMING_OUTPUT"] = original : ENV.delete("TEST_TIMING_OUTPUT")
  end

  def test_run_rejects_selected_commit_that_is_not_checked_out
    refute_equal 0, cli.call(["run", "--base", @base, "--head", @base])
    assert_match(/check out the selected commit/, @err.string)
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_run_rejects_uncommitted_tracked_staged_and_untracked_files
    write("app/feature.rb", "uncommitted")
    refute_equal 0, cli.call(["run", "--base", @base])
    git("add", "app/feature.rb")
    refute_equal 0, cli.call(["run", "--base", @base])
    commit
    write("new.rb", "untracked")
    refute_equal 0, cli.call(["run", "--base", @base])
    assert_match(/commit changes/, @err.string)
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_run_allows_ignored_outputs
    write(".gitignore", "ignored-output\n")
    commit
    write("ignored-output", "generated")
    assert_equal 0, cli.call(["run", "--base", @base])
    assert_equal [[@unit, "test/unowned_test.rb"], [@system]], calls
  end

  def test_missing_or_unsafe_refs_never_execute
    ["missing-ref", "--help", "HEAD\n"].each do |ref|
      refute_equal 0, cli.call(["run", "--base", ref])
    end
    refute_equal 0, cli.call(["run", "--base", @base, "--head", "missing"])
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_empty_committed_inventory_fails_instead_of_running_everything
    [@unit, @system, "test/unowned_test.rb"].each { |path| File.delete(File.join(@root, path)) }
    commit
    refute_equal 0, cli.call(["run", "--base", @base])
    assert_match(/no test files/, @err.string)
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_check_reports_positive_inventory_count
    assert_equal 0, cli.call(["check"])
    assert_equal "Ownership valid: 3 test files (1 full_suite default)\n", @out.string
  end

  def test_select_and_run_reject_manifest_overrides_for_an_injected_policy
    supplied = TestSieve::CLI.new(root: @root, policy: TestSieve::Rails.policy, out: @out, err: @err)
    %w[select run].each do |action|
      refute_equal 0, supplied.call([action, "--base", @base, "--manifest", "alternate.yml"])
    end
    assert_includes @err.string, "change manifest_path in the policy"
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_select_and_run_reject_manifest_overrides_for_a_configuration_file
    write("config/test_sieve.rb", "TestSieve::Rails.policy\n")
    commit
    %w[select run].each do |action|
      refute_equal 0, cli.call([action, "--base", @base, "--config", "config/test_sieve.rb", "--manifest", "alternate.yml"])
    end
    assert_includes @err.string, "change manifest_path in the policy"
    refute File.exist?(File.join(@root, "calls.jsonl"))
  end

  def test_check_json_returns_complete_validator_result_unchanged
    assert_equal 0, cli.call(["check", "--json"])
    expected = TestSieve::OwnershipValidator.new(root: @root,
      manifest_path: File.join(@root, "test_ownership.yml"), policy: TestSieve::Rails.policy).call
    assert_equal expected, JSON.parse(@out.string)
  end

  def test_check_uses_injected_policy_manifest_and_allows_independent_manifest_override
    policy = TestSieve::Rails.policy(manifest_path: "config/ownership.yml")
    write("config/ownership.yml", YAML.dump(@manifest))
    File.delete(File.join(@root, "test_ownership.yml"))
    assert_equal 0, cli(policy:).call(["check", "--root", @root])
    write("alternate.yml", YAML.dump(@manifest))
    File.delete(File.join(@root, "config/ownership.yml"))
    @out.truncate(0); @out.rewind
    assert_equal 0, cli(policy:).call(["check", "--manifest", "alternate.yml", "--json"])
    assert_equal @manifest.merge("tests" => {
      @unit => ["feature"], @system => ["feature"], "test/unowned_test.rb" => ["full_suite"]
    }), JSON.parse(@out.string)
    assert_equal "config/ownership.yml", policy.manifest_path
  end

  def test_output_and_root_options
    assert_equal 0, TestSieve::CLI.new(out: @out, err: @err).call(
      ["select", "--root", @root, "--base", @base, "--output", "selection.json"])
    assert_equal "selected", JSON.parse(File.read(File.join(@root, "selection.json")))["mode"]
    assert_empty @out.string
  end

  def test_explicit_trusted_config_supports_custom_required_roles
    tests = @manifest["owners"]["feature"]["tests"]
    tests["learner"] = tests.delete("system")
    write_manifest
    write("policy.rb", 'TestSieve::Rails.policy(required_roles: %w[unit learner], role_suites: {"unit" => "unit", "learner" => "system"})')
    assert_equal 0, cli.call(["check", "--config", "policy.rb"])
    refute_equal 0, cli.call(["check"])
  end

  def test_programmatic_policy_preserves_custom_ownership_roles
    tests = @manifest["owners"]["feature"]["tests"]
    tests["learner"] = tests.delete("system")
    write_manifest
    policy = TestSieve::Rails.policy(required_roles: %w[unit learner], role_suites: {"unit" => "unit", "learner" => "system"})
    assert_equal 0, cli(policy:).call(["check"])
    refute_equal 0, cli(policy:).call(["check", "--config", "policy.rb"])
  end

  def test_config_is_never_executed_automatically
    write("config/test_sieve.rb", 'raise "must not load"')
    assert_equal 0, cli.call(["check"])
  end

  def test_help_and_option_errors
    assert_equal 0, cli.call(["--help"])
    assert_match(/trusted Ruby/, @out.string)
    [["run"], ["select"], ["invalid"], ["check", "extra"], ["run", "--base", @base, "--suite", "bad"],
      ["check", "--suite", "unit"], ["check", "--output", "x"], ["run", "--base", @base, "--selection", "x"]].each do |args|
      refute_equal 0, cli.call(args), args.inspect
    end
    write("bad.rb", "nil")
    refute_equal 0, cli.call(["check", "--config", "bad.rb"])
    refute_equal 0, cli.call(["check", "--config", "absent.rb"])
    write("bad.rb", "broken (")
    refute_equal 0, cli.call(["check", "--config", "bad.rb"])
  end

  def test_executable_without_rails_installed
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
      File.expand_path("../exe/test-sieve", __dir__), "check", "--root", @root)
    assert status.success?, error
    assert_match(/3 test files/, output)
  end

  private

  def cli(**options)
    TestSieve::CLI.new(root: @root, out: @out, err: @err, command: [RbConfig.ruby, "runner.rb"], **options)
  end

  def write(path, content)
    absolute = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, content)
  end

  def write_manifest
    write("test_ownership.yml", YAML.dump(@manifest))
  end

  def git(*args)
    output, error, status = Open3.capture3("git", *args, chdir: @root)
    raise error unless status.success?
    output.strip
  end

  def commit
    git("add", ".")
    git("commit", "-qm", "fixture")
    git("rev-parse", "HEAD")
  end

  def calls
    File.readlines(File.join(@root, "calls.jsonl")).map { |line| JSON.parse(line) }
  end
end

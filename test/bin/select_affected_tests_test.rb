# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "yaml"
require "digest"

class SelectAffectedTestsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "test/support/bin/select-affected-tests")

  def setup
    @root = Dir.mktmpdir("affected-tests")
    git("init", "-q")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    @manifest = { "version" => 1, "default" => "full_suite", "broad_changes" => [], "owners" => {} }
    %w[ source consumer host ].each do |name|
      paths = [ "app/#{name}.rb", "test/#{name}_test.rb", "test/system/#{name}_test.rb" ]
      paths.each { |path| write(path, name) }
      @manifest["owners"][name] = { "sources" => [ paths[0] ], "inputs" => [], "notes" => name,
        "tests" => { "unit" => [ paths[1] ], "learner" => [ paths[2] ] } }
    end
    @manifest["owners"]["consumer"]["depends_on"] = [ "source" ]
    @manifest["owners"]["host"]["depends_on"] = [ "consumer" ]
    write("test/unowned_test.rb")
    policy
    @base = commit
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_transitive_consumers_and_deterministic_committed_metadata
    write("app/source.rb", "changed")
    head = commit
    result = report(head:)
    assert_equal "selected", result["mode"]
    assert_equal %w[ consumer host source ], result["affected_owners"]
    assert_equal %w[ test/consumer_test.rb test/host_test.rb test/source_test.rb ], result["unit_files"]
    assert_equal head, result["source_sha"]
    assert_equal @base, result["base_sha"]
    assert_equal Digest::SHA256.hexdigest(YAML.dump(@manifest)), result["ownership_digest"]
    write("config/test_ownership.yml", "broken")
    write("test/dirty_test.rb")
    write("app/source.rb", "dirty")
    assert_equal result, report(head:)
  end

  def test_single_owner_and_shared_test_consumers
    write("app/host.rb", "changed")
    result = report
    assert_equal "selected", result["mode"]
    assert_equal [ "host" ], result["affected_owners"]
    assert_equal [ "test/system/host_test.rb" ], result["system_files"]
  end

  def test_shared_test_selects_every_owner_and_dependency_cycles_terminate
    @manifest["owners"]["source"]["depends_on"] = [ "host" ]
    @manifest["owners"]["host"]["tests"]["unit"] << "test/consumer_test.rb"
    policy
    @base = commit
    write("test/consumer_test.rb", "changed")
    result = report
    assert_equal "selected", result["mode"]
    assert_equal %w[ consumer host source ], result["affected_owners"]
  end

  def test_unavailable_base_policy_still_uses_head_inventory
    File.delete(File.join(@root, "config/test_ownership.yml"))
    @base = commit
    policy
    assert_full(report, "base_policy_invalid")
  end

  def test_malformed_policy_is_full_even_when_its_paths_were_owned
    write("config/test_ownership.yml", "version: [")
    write("app/source.rb", "changed")
    assert_full(report, "head_policy_invalid")
  end

  def test_owned_addition_and_deletion_update_rules_and_inventory
    write("app/new.rb")
    @manifest["owners"]["source"]["sources"] << "app/new.rb"
    policy
    assert_full(report, "ownership_changed")
    File.delete(File.join(@root, "test/source_test.rb"))
    @manifest["owners"]["source"]["tests"]["unit"] = [ "test/consumer_test.rb" ]
    policy
    result = report
    assert_full(result, "ownership_changed")
    refute_includes result["unit_files"], "test/source_test.rb"
  end

  def test_unsafe_changed_path_is_full_and_symlink_source_is_not_followed
    write("app/unsafe\n.rb")
    assert_full(report, "unsafe_path:#{"app/unsafe\n.rb".inspect}")
    File.delete(File.join(@root, "app/source.rb"))
    File.symlink("/etc/passwd", File.join(@root, "app/source.rb"))
    assert_full(report, "head_policy_invalid")
  end

  def test_empty_and_mixed_unknown_changes_fall_back
    assert_full(report(head: @base), "empty_diff")
    write("app/source.rb", "changed")
    write("unknown.txt")
    assert_full(report, "unknown_path:unknown.txt")
  end

  def test_missing_base_and_policy_fall_back
    assert_full(report(base: "missing", head: @base), "base_unavailable")
    File.delete(File.join(@root, "config/test_ownership.yml"))
    assert_full(report, "head_policy_invalid")
  end

  def test_dependency_removal_preserves_base_consumers_and_requires_full_coverage
    write("app/source.rb", "changed")
    @manifest["owners"]["host"].delete("depends_on")
    policy
    result = report
    assert_full(result, "ownership_changed")
    assert_equal %w[ consumer host source ], result["affected_owners"]
  end

  def test_addition_deletion_and_cross_owner_rename_consider_both_paths
    git("mv", "app/source.rb", "app/renamed.rb")
    @manifest["owners"]["source"]["sources"] = [ "app/consumer.rb" ]
    @manifest["owners"]["consumer"]["sources"] = [ "app/renamed.rb" ]
    policy
    result = report
    assert_full(result, "ownership_changed")
    assert_includes result["changed_paths"], "app/source.rb"
    assert_includes result["changed_paths"], "app/renamed.rb"
    assert_equal %w[ consumer host source ], result["affected_owners"]
  end

  def test_deleted_owned_source_with_stale_policy_is_full
    File.delete(File.join(@root, "app/source.rb"))
    assert_full(report, "head_policy_invalid")
  end

  def test_new_unknown_test_is_in_full_inventory
    write("test/new_test.rb")
    result = report
    assert_full(result, "unknown_path:test/new_test.rb")
    assert_includes result["unit_files"], "test/new_test.rb"
  end

  def test_invalid_dependencies_and_unsafe_references_fall_back
    [ [ "absent" ], [ "source", "source" ], "source" ].each do |dependencies|
      @manifest["owners"]["host"]["depends_on"] = dependencies
      policy
      assert_full(report, "head_policy_invalid")
    end
    @manifest["owners"]["host"].delete("depends_on")
    @manifest["owners"]["host"]["sources"] = [ "../outside.rb" ]
    policy
    assert_full(report, "head_policy_invalid")
  end

  def test_broad_rules_take_precedence
    @manifest["broad_changes"] = [ { "pattern" => "app/**/*", "reason" => "Shared source" } ]
    policy
    @base = commit
    write("app/source.rb", "changed")
    assert_full(report, "broad_path:app/source.rb:Shared source")
  end

  def test_pr_uses_merge_base_while_push_compares_endpoints
    git("checkout", "-qb", "feature")
    write("app/host.rb", "feature")
    head = commit
    git("checkout", "-qb", "target", @base)
    write("unknown.txt")
    target = commit
    pr = report(base: target, head:, comparison: "pr")
    assert_equal "selected", pr["mode"]
    assert_equal @base, pr["base_sha"]
    assert_equal target, pr["requested_base"]
    assert_full(report(base: target, head:, comparison: "push"), "unknown_path:unknown.txt")
  end

  def test_unavailable_tested_inventory_is_an_error_not_empty_success
    [ "missing", "--all" ].each do |head|
      stdout, stderr, status = cli("--base", @base, "--head", head, "--comparison", "push")
      refute status.success?
      assert_empty stdout
      assert_includes stderr, "select-affected-tests"
    end
    File.symlink("/outside", File.join(@root, "test/unsafe_test.rb"))
    stdout, _stderr, status = cli("--base", @base, "--head", commit, "--comparison", "push")
    refute status.success?
    assert_empty stdout
  end

  def test_requires_explicit_endpoints_and_comparison
    stdout, _stderr, status = cli("--base", @base, "--head", @base)
    refute status.success?
    assert_empty stdout
  end

  def test_empty_test_inventory_cannot_report_success
    FileUtils.remove_entry(File.join(@root, "test"))
    stdout, stderr, status = cli("--base", @base, "--head", commit, "--comparison", "push")
    refute status.success?
    assert_empty stdout
    assert_includes stderr, "no test files"
  end

  private
    def write(path, content = "")
      absolute = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
    end

    def policy
      write("config/test_ownership.yml", YAML.dump(@manifest))
    end

    def git(*args)
      output, error, status = Open3.capture3("git", *args, chdir: @root)
      raise error unless status.success?
      output.strip
    end

    def commit
      git("add", ".")
      git("commit", "-qm", "snapshot", "--allow-empty")
      git("rev-parse", "HEAD")
    end

    def cli(*args)
      Open3.capture3(BIN, "--root", @root, *args, chdir: ROOT)
    end

    def report(base: @base, head: commit, comparison: "push")
      stdout, stderr, status = cli("--base", base, "--head", head, "--comparison", comparison)
      assert status.success?, stderr
      JSON.parse(stdout)
    end

    def assert_full(result, reason)
      assert_equal "full", result["mode"]
      assert_includes result["reasons"], reason
      assert_includes result["unit_files"], "test/unowned_test.rb"
      assert_equal %w[ test/system/consumer_test.rb test/system/host_test.rb test/system/source_test.rb ], result["system_files"]
    end
end

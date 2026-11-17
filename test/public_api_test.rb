# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require_relative "../lib/test_sieve"

class PublicApiTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("independent-selection")
    @policy = project_policy
    @files = %w[ checks/acceptance/first.spec checks/acceptance/second.spec ]
    ([ "src/feature.txt", "checks/fast.spec" ] + @files).each { |path| write(path, "sample\n") }
    write("ownership.yml", YAML.dump("version" => 1, "default" => "full_suite", "broad_changes" => [],
      "owners" => { "feature" => { "sources" => [ "src/feature.txt" ], "inputs" => [], "notes" => "Independent fixture",
        "tests" => { "fast" => [ "checks/fast.spec" ], "acceptance" => @files } } }))
    git("init", "-q")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    @base = commit
    write("src/feature.txt", "changed\n")
    @head = commit
    @selection = TestSieve::Selector.new(root: @root, base: @base, head: @head,
      comparison: "push", policy: @policy).call
    @manifest = TestSieve::SystemManifest.build(root: @root, selection: @selection,
      commit: @head, shards: 4, policy: @policy)
    write("manifest.json", JSON.generate(@manifest))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_public_api_selects_and_assigns_four_jobs_without_application_paths
    assert_equal "selected", @selection["mode"]
    assert_equal [ "checks/fast.spec" ], @selection["unit_files"]
    assert_equal @files, @selection["system_files"]
    assert_equal [ [ @files[0] ], [ @files[1] ], [], [] ], @manifest.dig("assignments", "shards")
    assert_equal 4, @manifest.dig("assignments", "total")
  end

  def test_public_api_reads_and_validates_a_manifest_file
    manifest = TestSieve::SystemManifest.from_file(root: @root, path: File.join(@root, "manifest.json"),
      expected_commit: @head, policy: @policy)

    assert_equal @manifest["checksum"], manifest["checksum"]
    assert_equal @manifest.dig("assignments", "shards"), manifest.dig("assignments", "shards")
  end

  def test_changed_policy_identity_rejects_old_manifest
    changed = project_policy(identity: "independent-project-v2")
    error = assert_raises(TestSieve::SystemManifest::Invalid) do
      TestSieve::SystemManifest.new(root: @root, manifest: @manifest, policy: changed).validate(expected_commit: @head)
    end
    assert_includes error.message, "policy_digest"
  end

  def test_changed_engine_version_rejects_old_manifest
    @manifest["selection"]["engine_version"] = "0.0.0"
    error = assert_raises(TestSieve::SystemManifest::Invalid) do
      TestSieve::SystemManifest.new(root: @root, manifest: @manifest, policy: @policy).validate(expected_commit: @head)
    end
    assert_includes error.message, "engine_version"
  end

  private
    def project_policy(identity: "independent-project-v1")
      TestSieve::Policy.new(manifest_path: "ownership.yml",
        test_pattern: "checks/**/*.spec", system_pattern: "checks/acceptance/**/*.spec",
        required_roles: %w[ fast acceptance ], optional_roles: [],
        role_suites: { "fast" => "unit", "acceptance" => "system" },
        rules: [ "ownership.yml" ], identity: identity)
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
      git("commit", "-qm", "fixture")
      git("rev-parse", "HEAD")
    end
end

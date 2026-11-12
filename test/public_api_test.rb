# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require_relative "../lib/test_selection"

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
    @selection = TestOwnership::Selector.new(root: @root, base: @base, head: @head,
      comparison: "push", policy: @policy).call
    @manifest = TestSelection::SystemManifest.build(root: @root, selection: @selection,
      commit: @head, shards: 4, policy: @policy)
    write("manifest.json", JSON.generate(@manifest))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_public_api_selects_assigns_and_verifies_four_jobs_without_application_paths
    assert_equal "selected", @selection["mode"]
    assert_equal [ "checks/fast.spec" ], @selection["unit_files"]
    assert_equal @files, @selection["system_files"]
    assert_equal [ [ @files[0] ], [ @files[1] ], [], [] ], @manifest.dig("assignments", "shards")
    write_results
    gate = verify
    assert gate.call, gate.errors.inspect
    assert_equal "complete", gate.report["status"]

    File.delete(File.join(@root, "results/shard-3.json"))
    gate = verify
    refute gate.call
    assert gate.errors.any? { |error| error.include?("missing shard records") }
  end

  def test_changed_policy_identity_rejects_old_manifest
    changed = project_policy(identity: "independent-project-v2")
    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.new(root: @root, manifest: @manifest, policy: changed).validate(expected_commit: @head)
    end
    assert_includes error.message, "policy_digest"
  end

  def test_changed_engine_version_rejects_old_manifest
    @manifest["selection"]["engine_version"] = "0.0.0"
    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.new(root: @root, manifest: @manifest, policy: @policy).validate(expected_commit: @head)
    end
    assert_includes error.message, "engine_version"
  end

  def test_extra_unidentified_shard_record_cannot_be_discarded
    write_results
    write("results/shard-unknown.json", JSON.generate("files" => []))
    gate = verify
    refute gate.call
    assert gate.errors.any? { |error| error.include?("no integer shard index") }
  end

  def test_nonobject_run_document_cannot_be_discarded
    write_results
    [ "null", "false", "[]" ].each do |content|
      write("results/run.json", content)
      gate = verify
      refute gate.call, content
      assert gate.errors.any? { |error| error.include?("run document must be an object") }
    end
  end

  def test_unknown_record_in_an_empty_job_cannot_be_discarded
    write_results
    write("results/outcomes-3.jsonl", JSON.generate("type" => "unknown") + "\n")
    gate = verify
    refute gate.call
    assert gate.errors.any? { |error| error.include?("unknown normalized record") }
  end

  def test_conflicting_identity_in_an_empty_job_cannot_be_discarded
    write_results
    records = [ { "type" => "run_start", "metadata" => {} },
      { "type" => "run_end", "metadata" => {}, "completed" => true, "interrupted" => false } ]
    write("results/outcomes-3.jsonl", records.map { |record| JSON.generate(record) }.join("\n") + "\n")
    gate = verify
    refute gate.call
    assert gate.errors.any? { |error| error.include?("run metadata") }
  end

  private
    def project_policy(identity: "independent-project-v1")
      TestSelection::Policy.new(manifest_path: "ownership.yml",
        test_pattern: "checks/**/*.spec", system_pattern: "checks/acceptance/**/*.spec",
        required_roles: %w[ fast acceptance ], optional_roles: [],
        role_suites: { "fast" => "unit", "acceptance" => "system" },
        rules: [ "ownership.yml" ], identity: identity)
    end

    def verify
      TestSelection::SystemRunGate.new(root: @root, manifest_path: File.join(@root, "manifest.json"),
        expected_commit: @head, run_id: "local-run", run_attempt: "1", repository: "independent/project",
        shards: 4, run_dirs: [ File.join(@root, "results") ], policy: @policy,
        record_parser: ->(line) { JSON.parse(line) })
    end

    def write_results
      @manifest.dig("assignments", "shards").each_with_index do |files, index|
        write("results/shard-#{index}.json", JSON.generate("shard_index" => index, "shard_total" => 4,
          "commit" => @head, "run_id" => "local-run", "run_attempt" => "1", "mode" => "selected",
          "manifest_checksum" => @manifest["checksum"], "run_files" => @files,
          "files_digest" => TestSelection::RunResult.files_digest(@files), "files" => files,
          "empty" => files.empty?, "exit_status" => 0, "outcomes" => "outcomes-#{index}.jsonl"))
        next if files.empty?

        identity = "local-run/1/system-shard-#{index}/shard-#{index}-of-4"
        envelope = { "timestamp" => "2026-01-01T00:00:00Z", "run_id" => identity,
          "run_key" => "independent/project/#{identity}", "metadata" => {
            "repository" => "independent/project", "workflow_run_id" => "local-run", "workflow_run_attempt" => "1",
            "commit" => @head, "dirty" => false, "suite" => "system-shard-#{index}", "shard" => "shard-#{index}-of-4" } }
        records = [ envelope.merge("type" => "run_start"), envelope.merge("type" => "test_result",
          "test_id" => "Acceptance#case_#{index}", "test_class" => "Acceptance", "test_name" => "case_#{index}",
          "file" => files.first, "line" => 1, "execution_index" => 1, "duration_seconds" => 0.1, "outcome" => "pass"),
          envelope.merge("type" => "run_end", "completed" => true, "interrupted" => false) ]
        write("results/outcomes-#{index}.jsonl", records.map { |record| JSON.generate(record) }.join("\n") + "\n")
      end
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

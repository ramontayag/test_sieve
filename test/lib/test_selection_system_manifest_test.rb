# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "yaml"
require "digest"

require_relative "../support/project"

# Proves that a system-test manifest binds a fixed selection to one commit.
#
# The manifest is the input a runner consumes. A runner must be able to trust
# it without asking the selector again. These tests build manifests from real
# selector reports in real temporary Git repositories, then change one thing at
# a time to show that validation rejects it.
class TestSelectionSystemManifestTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @root = Dir.mktmpdir("system-manifest")
    @output = Dir.mktmpdir("system-manifest-output")
    git("init", "-q")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    @manifest = { "version" => 1, "default" => "full_suite", "broad_changes" => [], "owners" => {} }
    %w[ source consumer host ].each do |name|
      paths = [ "app/#{name}.rb", "test/#{name}_test.rb", "test/system/#{name}_test.rb" ]
      # The test files end with a newline so that the digest covers the
      # committed bytes exactly.
      paths.each { |path| write(path, "#{name}\n") }
      @manifest["owners"][name] = { "sources" => [ paths[0] ], "inputs" => [], "notes" => name,
        "tests" => { "unit" => [ paths[1] ], "learner" => [ paths[2] ] } }
    end
    @manifest["owners"]["consumer"]["depends_on"] = [ "source" ]
    @manifest["owners"]["host"]["depends_on"] = [ "consumer" ]
    policy
    @base = commit
  end

  def teardown
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(@output)
  end

  # A manifest built from a real selection names every selected file, its
  # content checksum, and the shard that runs it.
  def test_builds_a_manifest_from_a_real_selection
    write("app/source.rb", "changed")
    head = commit

    manifest = build(head:)

    assert_equal 1, manifest.fetch("version")
    assert_equal head, manifest.fetch("commit")
    assert_equal "selected", manifest.dig("selection", "mode")
    assert_equal %w[ test/system/consumer_test.rb test/system/host_test.rb test/system/source_test.rb ],
      manifest.fetch("files").keys
    manifest.fetch("files").each do |path, checksum|
      assert_equal Digest::SHA256.hexdigest(git_bytes("show", "#{head}:#{path}")), checksum
    end
    assert_equal [ %w[ test/system/consumer_test.rb ], %w[ test/system/host_test.rb ], %w[ test/system/source_test.rb ] ],
      manifest.dig("assignments", "shards")
  end

  # The caller states which commit the manifest is for. The manifest must
  # refuse a commit that does not match the selection it was built from.
  def test_rejects_an_expected_commit_that_does_not_match_the_selection
    write("app/source.rb", "changed")
    head = commit

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      build(head:, commit: @base)
    end

    assert_includes error.message, "commit"
  end

  # The assignment must cover every selected file exactly once.
  def test_each_selected_file_is_assigned_to_exactly_one_shard
    write("app/source.rb", "changed")
    head = commit

    manifest = build(head:)
    assignments = manifest.dig("assignments", "shards")

    assigned = assignments.flatten
    assert_equal assigned.uniq, assigned
    assert_equal manifest.fetch("files").keys.sort, assigned.sort
  end

  # One selected file across three shards leaves two shards empty. The empty
  # shards are explicit data, not missing results.
  def test_one_file_across_three_shards_produces_two_explicit_empty_assignments
    write("app/host.rb", "changed")
    head = commit

    manifest = build(head:, shards: 3)

    assert_equal [ [ "test/system/host_test.rb" ], [], [] ], manifest.dig("assignments", "shards")
    assert_equal 3, manifest.dig("assignments", "total")
  end

  # Two shards split the selection the same way the existing runner does.
  def test_two_shards_split_the_selection_in_a_round_robin
    write("app/source.rb", "changed")
    head = commit

    manifest = build(head:, shards: 2)

    assert_equal [ %w[ test/system/consumer_test.rb test/system/source_test.rb ],
      %w[ test/system/host_test.rb ] ], manifest.dig("assignments", "shards")
    assert_equal 2, manifest.dig("assignments", "total")
  end

  # A manifest must name at least one file. An empty manifest is not a valid
  # selection.
  def test_rejects_a_manifest_with_no_files
    write("app/source.rb", "changed")
    head = commit
    selection = selector(head:)
    selection["system_files"] = []

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit: head, shards: 3)
    end

    assert_includes error.message, "at least one"
  end

  # A selector report that omits an identity must not produce a manifest.
  # The manifest would name a selection that cannot be verified.
  def test_rejects_a_selector_report_that_omits_an_identity
    write("app/source.rb", "changed")
    head = commit
    selection = selector(head:)
    selection.delete("ownership_digest")

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit: head, shards: 3)
    end

    assert_includes error.message, "missing required keys"
  end

  # A selector report that drops a selected file must not produce a
  # manifest. The manifest would run fewer tests than the selection chose.
  def test_rejects_a_selector_report_that_omits_a_selected_file
    write("app/source.rb", "changed")
    head = commit
    selection = selector(head:)
    selection["system_files"] = [ "test/system/consumer_test.rb" ]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit: head, shards: 3)
    end

    assert_includes error.message, "selection system_files differ"
  end

  # A selector report that names a file outside test/system must not produce
  # a manifest. A system manifest may only carry system tests.
  def test_rejects_a_selector_report_that_names_a_non_system_file
    write("app/source.rb", "changed")
    head = commit
    selection = selector(head:)
    selection["system_files"] = [ "test/host_test.rb" ]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit: head, shards: 3)
    end

    assert_includes error.message, "system test"
  end

  # A manifest must survive a round trip through JSON.
  def test_validates_a_manifest_it_built
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)

    validated = TestSelection::SystemManifest.new(policy: FixtureProject::POLICY, root: @root, manifest:).validate(expected_commit: head)

    assert_equal manifest, validated
  end

  # The digest must cover the committed bytes exactly. A file that ends with
  # a newline must not hash like the same file without one.
  def test_the_digest_covers_the_committed_bytes_including_trailing_newlines
    write("app/source.rb", "changed")
    head = commit
    content = git_bytes("show", "#{head}:test/system/host_test.rb")
    assert_equal "host\n", content

    manifest = build(head:)

    assert_equal Digest::SHA256.hexdigest(content), manifest.dig("files", "test/system/host_test.rb")
    refute_equal Digest::SHA256.hexdigest(content.chomp), manifest.dig("files", "test/system/host_test.rb")
  end

  # The digest must describe the committed bytes. An edit in the working
  # tree that was never committed must not change it.
  def test_the_digest_ignores_uncommitted_edits
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    committed = manifest.dig("files", "test/system/host_test.rb")

    write("test/system/host_test.rb", "edited in the working tree")

    assert_equal committed, build(head:).dig("files", "test/system/host_test.rb")
    assert_equal committed, manifest.dig("files", "test/system/host_test.rb")
  end

  # The manifest content digest detects any edit to the manifest body that no
  # other check names.
  def test_rejects_a_manifest_whose_checksum_does_not_match_its_content
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["checksum"] = "0" * 64

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "checksum"
  end

  # A file whose recorded digest does not match the committed bytes must be
  # rejected. The digest binds the content, not just the path.
  def test_rejects_a_file_whose_committed_content_does_not_match_its_digest
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["files"]["test/system/host_test.rb"] = Digest::SHA256.hexdigest("different content")

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "checksum"
  end

  # A manifest built for one commit must not validate against another commit,
  # even when both commits contain the same files.
  def test_rejects_a_file_whose_content_changed_in_the_tested_commit
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    write("test/system/host_test.rb", "changed after the manifest was built")
    changed = commit

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, changed)
    end

    assert_includes error.message, "commit"
  end

  # The selection embedded in the manifest must still match what the selector
  # computes from the committed tree.
  def test_rejects_a_manifest_whose_embedded_selection_was_altered
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.dig("selection", "system_files") << "test/system/unknown_test.rb"

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "selection"
  end

  # The ownership identity must still match the committed tree.
  def test_rejects_a_stale_ownership_identity
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["selection"]["ownership_digest"] = "0" * 64

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "ownership"
  end

  # The selector identity must still match the installed selector.
  def test_rejects_a_stale_selector_identity
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["selection"]["rules_digest"] = "0" * 64

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "rules_digest"
  end

  # A manifest for another commit must not validate against the commit the
  # caller is running.
  def test_rejects_a_manifest_bound_to_another_commit
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    write("app/host.rb", "changed")
    other = commit

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, other)
    end

    assert_includes error.message, "commit"
  end

  # A missing file is not a valid selection entry.
  def test_rejects_a_missing_path
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["files"].delete("test/system/host_test.rb")

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "test/system/host_test.rb"
  end

  # The same path twice means one file could run twice.
  def test_rejects_a_duplicate_path
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["files"]["test/system/host_test.rb"] = manifest["files"]["test/system/consumer_test.rb"]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "checksum"
  end

  # A path that leaves the repository must be rejected.
  def test_rejects_unsafe_paths
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["files"]["../outside_test.rb"] = manifest["files"]["test/system/host_test.rb"]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "path"
  end

  # A symlink is not a regular committed file. The manifest must not follow it.
  def test_rejects_a_symlink
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    git("rm", "-q", "test/system/host_test.rb")
    File.symlink("test/system/source_test.rb", File.join(@root, "test/system/host_test.rb"))
    symlinked = commit
    manifest["commit"] = symlinked
    manifest["selection"]["source_sha"] = symlinked

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, symlinked)
    end

    assert_includes error.message, "regular file"
  end

  # A file outside test/system is not a system test.
  def test_rejects_a_non_system_file
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["files"]["test/host_test.rb"] = Digest::SHA256.hexdigest(git_bytes("show", "#{head}:test/host_test.rb"))

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "system test"
  end

  # An edited assignment would run a file that the selection did not choose.
  def test_rejects_a_tampered_assignment
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.dig("assignments", "shards")[0] = [ "test/system/unknown_test.rb" ]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "assignment"
  end

  # An assignment that drops a file would leave that file unrun.
  def test_rejects_an_assignment_that_drops_a_selected_file
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.dig("assignments", "shards")[1] = []

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "assignment"
  end

  # A file must appear in exactly one shard.
  def test_rejects_a_file_assigned_to_two_shards
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.dig("assignments", "shards")[1] = [ "test/system/consumer_test.rb" ]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "exactly once"
  end

  # The shard order is part of the assignment. Reordering the shards would
  # send a file to a different job than the manifest describes.
  def test_rejects_reordered_assignments
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.dig("assignments", "shards").reverse!

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "assignment"
  end

  # Every shard must be present, including a shard with no files. A missing
  # shard leaves a job without a manifest.
  def test_rejects_a_missing_empty_shard
    write("app/host.rb", "changed")
    head = commit
    manifest = build(head:, shards: 3)
    assert_equal [ [ "test/system/host_test.rb" ], [], [] ], manifest.dig("assignments", "shards")
    manifest.dig("assignments", "shards").pop

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "every shard"
  end

  # A shard list with a value that is not a path must be rejected with a
  # clear reason, not with an unhandled error.
  def test_rejects_a_shard_assignment_with_a_value_that_is_not_a_path
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.dig("assignments", "shards")[0] = [ "test/system/consumer_test.rb", 42 ]

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "only strings"
  end

  # A selection identity with the wrong type must be rejected with a clear
  # reason, not with an unhandled error.
  def test_rejects_a_selection_identity_with_the_wrong_type
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["selection"]["requested_base_sha"] = 42

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "must be a string"
  end

  # The manifest structure must be exact. Unknown keys are a stale or
  # malformed document.
  def test_rejects_an_unknown_manifest_key
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["approved"] = true

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "unknown keys"
  end

  def test_rejects_a_missing_manifest_key
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest.delete("assignments")

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "missing required keys"
  end

  # A manifest must name a positive number of shards.
  def test_rejects_an_unsupported_shard_count
    write("app/source.rb", "changed")
    head = commit

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      build(head:, shards: 0)
    end

    assert_includes error.message, "shard"
  end

  # A document with conflicting keys must fail. JSON otherwise keeps the last
  # value and hides the conflict.
  def test_rejects_a_document_with_duplicate_json_keys
    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.parse_json('{"version":1,"version":1}')
    end

    assert_includes error.message, "duplicate"
  end

  # A manifest read from a file validates against the commit the caller names.
  def test_reads_and_validates_a_manifest_from_a_file
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    path = File.join(@output, "manifest.json")
    File.write(path, JSON.pretty_generate(manifest))

    validated = TestSelection::SystemManifest.from_file(policy: FixtureProject::POLICY, root: @root, path:, expected_commit: head)

    assert_equal manifest, validated
  end

  # A manifest built from a pull-request comparison must validate against the
  # same comparison.
  def test_builds_and_validates_a_manifest_from_a_pull_request_comparison
    git("checkout", "-qb", "feature")
    write("app/source.rb", "changed")
    head = commit
    git("checkout", "-q", @base)
    git("checkout", "-qb", "target")
    write("unknown.txt")
    target = commit
    selection = selector(head:, base: target, comparison: "pr")

    manifest = TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit: head, shards: 3)
    validated = TestSelection::SystemManifest.new(policy: FixtureProject::POLICY, root: @root, manifest:).validate(expected_commit: head)

    assert_equal manifest, validated
    assert_equal "pr", manifest.dig("selection", "comparison")
  end

  def test_rejects_an_unsupported_comparison_when_building_and_validating
    write("app/source.rb", "changed")
    head = commit
    selection = selector(head:)
    manifest = build(head:)
    selection["comparison"] = "invalid-comparison"
    manifest["selection"]["comparison"] = "invalid-comparison"

    build_error = assert_raises(TestSelection::SystemManifest::Invalid) do
      TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit: head, shards: 3)
    end
    validation_error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    [ build_error, validation_error ].each do |error|
      assert_includes error.message, "comparison must be pr or push"
    end
  end

  # A manifest whose base commit cannot be found cannot be verified. It must
  # be rejected, not reported as a valid selection.
  def test_rejects_a_manifest_whose_base_commit_cannot_be_found
    write("app/source.rb", "changed")
    head = commit
    manifest = build(head:)
    manifest["selection"]["requested_base_sha"] = "0" * 40

    error = assert_raises(TestSelection::SystemManifest::Invalid) do
      validate(manifest, head)
    end

    assert_includes error.message, "recomputed"
  end

  private
    def build(head:, commit: head, shards: 3)
      selection = selector(head:)
      TestSelection::SystemManifest.build(policy: FixtureProject::POLICY, root: @root, selection:, commit:, shards:)
    end

    def validate(manifest, commit)
      TestSelection::SystemManifest.new(policy: FixtureProject::POLICY, root: @root, manifest:).validate(expected_commit: commit)
    end

    def selector(head:, base: @base, comparison: "push")
      stdout, stderr, status = Open3.capture3(
        File.join(ROOT, "test/support/bin/select-affected-tests"), "--root", @root,
        "--base", base, "--head", head, "--comparison", comparison
      )
      raise stderr unless status.success?

      JSON.parse(stdout)
    end

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

    # Returns the committed bytes without changing them.
    def git_bytes(*args)
      output, error, status = Open3.capture3("git", *args, chdir: @root)
      raise error unless status.success?

      output
    end

    def commit
      git("add", ".")
      git("commit", "-qm", "snapshot", "--allow-empty")
      git("rev-parse", "HEAD")
    end
end

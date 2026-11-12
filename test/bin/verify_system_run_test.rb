# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

require_relative "../support/project"

# Proves that the result gate accepts a run that covered exactly the list it
# was asked to cover, and rejects a run that did not.
#
# The gate reads the records a run left behind. It proves execution, not
# approval: a verified manifest establishes integrity, and the gate
# establishes that every assigned file actually ran.
#
# The records are claims. The gate never takes a requirement from them.
class VerifySystemRunTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "test/support/bin/verify-system-run")
  REPOSITORY = "owner/repo"

  def setup
    @root = Dir.mktmpdir("verify-system-run")
    @work = File.join(@root, "work")
    FileUtils.mkdir_p([ @work, File.join(@work, "test/system"), File.join(@work, "app"),
                        File.join(@work, "config"), File.join(@work, "test") ])
    git("init", "-q", "-b", "main")
    %w[a b c].each do |name|
      write("test/system/#{name}_test.rb", "# #{name}\n")
      write("test/#{name}_test.rb", "# #{name}\n")
      write("app/#{name}.rb", "# #{name}\n")
    end
    write_ownership
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
    @base = git("rev-parse", "HEAD")
    write("app/a.rb", "# changed\n")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "change")
    @commit = git("rev-parse", "HEAD")
    @manifest = write_manifest
    @manifest_checksum = JSON.parse(File.read(@manifest)).fetch("checksum")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # A run that covered every assigned file passes.
  def test_accepts_a_run_that_covered_every_assigned_file
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    stdout, stderr, status = gate(run_dir)

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "complete", report.fetch("status")
    assert_equal "selected", report.fetch("mode")
  end

  # A run that recorded no result for an assigned file did not run that
  # file. The gate must reject it.
  def test_rejects_a_run_missing_a_result_for_an_assigned_file
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards, results: { 0 => [] })

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "test/system/a_test.rb"
  end

  # A shard that failed did not prove its assignment.
  def test_rejects_a_run_whose_shard_failed
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards, exit_status: { 0 => 1 })

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "exited 1"
  end

  # A recorded failure is a failed test, whatever the shard's exit status
  # claims.
  def test_rejects_a_shard_that_recorded_a_failed_test
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards, outcomes: { 0 => "fail" })

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "recorded failed tests"
  end

  # A recorded error is a failed test too.
  def test_rejects_a_shard_that_recorded_an_errored_test
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards, outcomes: { 0 => "error" })

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "recorded failed tests"
  end

  # A result another suite executed does not show that the system suite ran
  # the assigned file.
  def test_rejects_a_result_from_another_suite_as_coverage
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards,
      results: { 0 => [ "test/a_test.rb" ] })

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "no recorded result for test/system/a_test.rb"
  end

  # A run with a missing shard record has not shown that every shard ran.
  def test_rejects_a_run_missing_a_shard_record
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    File.delete(File.join(run_dir, "shard-1.json"))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "missing shard records"
  end

  # A shard that claims an empty assignment but has files assigned cannot
  # stand in for the tests it skipped.
  def test_rejects_a_shard_that_claims_an_empty_assignment_but_has_files
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    record = JSON.parse(File.read(File.join(run_dir, "shard-0.json")))
    record["empty"] = true
    File.write(File.join(run_dir, "shard-0.json"), JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "empty assignment"
  end

  # An empty shard must not hide results. A shard that claims to be empty
  # but recorded results is not empty.
  def test_rejects_an_empty_shard_that_recorded_results
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    record = JSON.parse(File.read(File.join(run_dir, "shard-1.json")))
    record["empty"] = true
    File.write(File.join(run_dir, "shard-1.json"), JSON.generate(record))
    write_outcomes(run_dir, 1, files: [ "test/system/a_test.rb" ], total: 2)

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "empty assignment but recorded"
  end

  # The evidence must belong to the run the gate was asked about.
  def test_rejects_a_run_from_another_workflow_run
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    _stdout, stderr, status = gate(run_dir, run_id: "9999")

    refute status.success?
    assert_includes stderr, "does not match the expected run id"
  end

  # The evidence must belong to the tested commit.
  def test_rejects_a_run_from_another_commit
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    _stdout, stderr, status = gate(run_dir, commit: "0" * 40)

    refute status.success?
    assert_includes stderr, "does not match the expected commit"
  end

  # A run that covered a different list than the manifest names is not the
  # run the caller asked for.
  def test_rejects_a_run_that_covered_a_different_list
    run_dir = write_run(files: [ "test/system/b_test.rb" ], shards: shards.merge(0 => [ "test/system/b_test.rb" ]))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "did not run the files it was assigned"
  end

  # A run directory that records the same shard twice cannot show that every
  # shard ran once.
  def test_rejects_a_run_directory_with_duplicate_shard_records
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    FileUtils.cp(File.join(run_dir, "shard-0.json"), File.join(run_dir, "shard-0-copy.json"))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "more than once"
  end

  # The same test recorded twice in one shard is not evidence of two
  # executions. It is a duplicate.
  def test_rejects_a_shard_that_recorded_the_same_test_twice
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    path = File.join(run_dir, "shard-0/tmp/test-results/system-shard-0/outcomes.jsonl")
    records = File.readlines(path).map { |line| JSON.parse(line) }
    duplicate = records[1].merge("execution_index" => 2)
    File.write(path, (records[0..1] + [ duplicate ] + records[2..]).map { |entry| JSON.generate(entry) }.join("\n") + "\n")

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "duplicate"
  end

  # A shard record whose file list is not the run's list cannot belong to
  # this run.
  def test_rejects_a_shard_that_is_assigned_a_file_outside_the_run
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    record = JSON.parse(File.read(File.join(run_dir, "shard-0.json")))
    record["files"] = [ "test/system/a_test.rb", "test/system/b_test.rb" ]
    File.write(File.join(run_dir, "shard-0.json"), JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "not in the expected list"
  end

  # A run directory with no shard records proves nothing.
  def test_rejects_a_run_directory_without_shard_records
    run_dir = File.join(@root, "empty")
    FileUtils.mkdir_p(run_dir)

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "bin/verify-system-run:"
  end

  # A run that fell back to the full suite covers everything. The gate
  # accepts it and reports that it was a fallback.
  def test_accepts_a_full_fallback_run_and_reports_it
    all_files = %w[test/system/a_test.rb test/system/b_test.rb test/system/c_test.rb]
    run_dir = write_run(files: all_files, shards: full_shards, mode: "full")

    stdout, stderr, status = gate(run_dir)

    assert status.success?, stderr
    assert_equal "full", JSON.parse(stdout).fetch("mode")
  end

  # A manifest the caller cannot trust must not gate anything.
  def test_rejects_an_invalid_manifest
    File.write(@manifest, "{ not json")

    _stdout, stderr, status = gate(write_run(files: [ "test/system/a_test.rb" ], shards: shards))

    refute status.success?
    assert_includes stderr, "bin/verify-system-run:"
  end

  # Missing and malformed arguments fail with a usage error.
  def test_rejects_missing_and_unknown_arguments
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    [ [], [ "--manifest", @manifest ], [ "--manifest", @manifest, "--commit", @commit,
      "--run-id", "4242", "--run-attempt", "1", "--repository", REPOSITORY, "--shards", "2" ],
      [ "--manifest", @manifest, "--commit", @commit, "--run-id", "4242", "--run-attempt", "1",
        "--repository", REPOSITORY, "--shards", "2", "--run-dir", run_dir, "--unknown" ],
      [ "--manifest", @manifest, "--commit", @commit, "--run-id", "4242", "--run-attempt", "1",
        "--repository", REPOSITORY, "--shards", "0", "--run-dir", run_dir ] ].each do |args|
      _stdout, stderr, status = cli(*args)

      refute status.success?, "expected failure for #{args.inspect}"
      assert_includes stderr, "bin/verify-system-run:"
    end
  end

  # A run that claims to be selected but names another manifest did not run
  # the list the caller vouches for.
  def test_rejects_a_selected_run_that_names_another_manifest
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    record = JSON.parse(File.read(File.join(run_dir, "shard-0.json")))
    record["manifest_checksum"] = "0" * 64
    File.write(File.join(run_dir, "shard-0.json"), JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "different manifest"
  end

  # A selected run that names no manifest did not prove which list it ran.
  def test_rejects_a_selected_run_that_names_no_manifest
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    record = JSON.parse(File.read(File.join(run_dir, "shard-0.json")))
    record["manifest_checksum"] = nil
    File.write(File.join(run_dir, "shard-0.json"), JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "different manifest"
  end

  # Separate matrix jobs write separate run directories. The gate combines
  # them into one decision when they describe the same run.
  def test_combines_the_run_directories_of_separate_shard_jobs
    first = write_run(files: [ "test/system/a_test.rb" ], shards: { 0 => [ "test/system/a_test.rb" ] },
      directory: "job-0", total: 2)
    second = write_run(files: [ "test/system/a_test.rb" ], shards: { 1 => [] }, directory: "job-1", total: 2)

    stdout, stderr, status = gate(first, run_dirs: [ first, second ])

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "complete", report.fetch("status")
    assert_equal 2, report.fetch("shards").size
  end

  # Two run directories from different runs cannot be combined into one
  # decision.
  def test_rejects_run_directories_from_different_runs
    first = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    second = write_run(files: [ "test/system/a_test.rb" ], shards: shards, directory: "second",
      run_id: "9999")

    _stdout, stderr, status = gate(first, run_dirs: [ first, second ])

    refute status.success?
    assert_includes stderr, "different run id"
  end

  # One shard that selected and another that fell back cannot be combined.
  def test_rejects_run_directories_that_disagree_about_the_mode
    first = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    second = write_run(files: [ "test/system/a_test.rb" ], shards: shards, directory: "second",
      mode: "full")

    _stdout, stderr, status = gate(first, run_dirs: [ first, second ])

    refute status.success?
    assert_includes stderr, "more than once"
  end

  # Every shard claiming an empty assignment must not let the run pass
  # without running a single test.
  def test_rejects_a_run_whose_every_shard_claims_an_empty_assignment
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    shards.each_key do |index|
      path = File.join(run_dir, "shard-#{index}.json")
      record = JSON.parse(File.read(path))
      record["files"] = []
      record["empty"] = true
      File.write(path, JSON.generate(record))
    end

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "did not run the files it was assigned"
  end

  # The same file assigned to two shards is not a partition.
  def test_rejects_a_file_assigned_to_two_shards
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards.merge(1 => [ "test/system/a_test.rb" ]))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "to 2 shards"
  end

  # A shard that drops the work of another shard does not cover the list.
  def test_rejects_a_shard_that_drops_another_shards_work
    run_dir = write_run(files: [ "test/system/a_test.rb", "test/system/b_test.rb" ], shards: {
      0 => [ "test/system/a_test.rb" ], 1 => [ "test/system/b_test.rb" ]
    }, total: 2)

    _stdout, stderr, status = gate(run_dir, shards: 2)

    refute status.success?
    assert_includes stderr, "did not run the files it was assigned"
  end

  # A run that claims fewer shards than the caller expects cannot drop the
  # other shards.
  def test_rejects_a_run_that_claims_fewer_shards_than_the_caller_expects
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: { 0 => [ "test/system/a_test.rb" ] },
      total: 1)

    _stdout, stderr, status = gate(run_dir, shards: 2)

    refute status.success?
    assert_includes stderr, "missing shard records"
  end

  # A run whose shard record claims a different shard total than the caller
  # expects is not evidence about this run.
  def test_rejects_a_run_that_claims_a_different_shard_total
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    _stdout, stderr, status = gate(run_dir, shards: 3)

    refute status.success?
    assert_includes stderr, "shard"
  end

  # Without the combined run document, a shard that disagrees about the mode
  # or the manifest must still be rejected.
  def test_rejects_shards_that_disagree_about_the_mode_without_a_run_document
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    File.delete(File.join(run_dir, "run.json"))
    path = File.join(run_dir, "shard-1.json")
    record = JSON.parse(File.read(path))
    record["mode"] = "full"
    record["manifest_checksum"] = "0" * 64
    File.write(path, JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "shard 1 names"
  end

  # Without the combined run document, a shard that disagrees about the file
  # list must still be rejected.
  def test_rejects_shards_that_disagree_about_the_file_list_without_a_run_document
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    File.delete(File.join(run_dir, "run.json"))
    path = File.join(run_dir, "shard-1.json")
    record = JSON.parse(File.read(path))
    record["run_files"] = [ "test/system/b_test.rb" ]
    record["files_digest"] = files_digest([ "test/system/b_test.rb" ])
    File.write(path, JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "shard 1 names"
  end

  # The shard count comes from the caller. A run cannot lower it.
  def test_rejects_a_run_that_lowers_the_expected_shard_count
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)
    shards.each_key do |index|
      path = File.join(run_dir, "shard-#{index}.json")
      record = JSON.parse(File.read(path))
      record["shard_total"] = 1
      File.write(path, JSON.generate(record))
    end

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "shard total"
  end

  # A full run that covered only part of the committed browser tests did not
  # run the full suite.
  def test_rejects_a_full_run_that_misses_committed_system_tests
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: { 0 => [ "test/system/a_test.rb" ] },
      mode: "full", total: 2)

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "did not run the files it was assigned"
  end

  # A full run whose shards disagree about the mode is not a full run.
  def test_rejects_a_full_run_whose_shards_disagree_about_the_mode
    run_dir = write_run(files: full_files, shards: full_shards, mode: "full")
    path = File.join(run_dir, "shard-1.json")
    record = JSON.parse(File.read(path))
    record["mode"] = "selected"
    File.write(path, JSON.generate(record))

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "shard 1 names"
  end

  # A selected run needs the trusted manifest. Without one the gate cannot
  # know what the run was asked to cover.
  def test_rejects_a_selected_run_without_a_manifest
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    _stdout, stderr, status = gate(run_dir, manifest: nil)

    refute status.success?
    assert_includes stderr, "needs the expected manifest"
  end

  # A full run is checked against the committed browser tests. The manifest
  # is never opened, so an unusable one does not stop the gate.
  def test_accepts_a_full_run_with_an_unusable_manifest
    run_dir = write_run(files: full_files, shards: full_shards, mode: "full")
    File.write(@manifest, "{ not json")

    stdout, stderr, status = gate(run_dir)

    assert status.success?, stderr
    assert_equal "full", JSON.parse(stdout).fetch("mode")
  end

  # A full run is checked against the committed browser tests. The manifest
  # is never opened, so it may name a file that does not exist.
  def test_accepts_a_full_run_with_a_missing_manifest
    run_dir = write_run(files: full_files, shards: full_shards, mode: "full")

    stdout, stderr, status = gate(run_dir, manifest: File.join(@root, "missing.json"))

    assert status.success?, stderr
    assert_equal "full", JSON.parse(stdout).fetch("mode")
  end

  # The same test may run in one shard only. Two shards that recorded it are
  # not evidence of two executions, even when each shard's assignment record
  # names different files.
  def test_rejects_a_test_that_ran_in_two_shards
    run_dir = write_run(files: [ "test/system/a_test.rb", "test/system/b_test.rb" ], shards: {
      0 => [ "test/system/a_test.rb" ], 1 => [ "test/system/b_test.rb" ]
    })
    write_outcomes(run_dir, 1, files: [ "test/system/a_test.rb" ], total: 2)

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "same test"
  end

  # A shard may only run the browser tests it was assigned. A result for
  # another browser test belongs to another shard.
  def test_rejects_a_shard_that_ran_another_shards_browser_test
    run_dir = write_run(files: [ "test/system/a_test.rb", "test/system/b_test.rb" ], shards: {
      0 => [ "test/system/a_test.rb" ], 1 => [ "test/system/b_test.rb" ]
    })
    write_outcomes(run_dir, 1, files: [ "test/system/a_test.rb" ], total: 2)

    _stdout, stderr, status = gate(run_dir)

    refute status.success?
    assert_includes stderr, "not assigned"
  end

  # The caller's identity must be usable before anything is read with it.
  def test_rejects_an_unusable_expected_identity
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards)

    [ { commit: "not-a-sha" }, { run_id: "" }, { repository: "" } ].each do |overrides|
      _stdout, stderr, status = gate(run_dir, **overrides)

      refute status.success?, "expected failure for #{overrides.inspect}"
      assert_includes stderr, "bin/verify-system-run:"
    end
  end

  # A browser suite may load a unit test file. That result is real
  # evidence of an execution, but it does not stand in for the browser
  # suite's own files.
  def test_accepts_a_shard_that_also_recorded_a_unit_test
    run_dir = write_run(files: [ "test/system/a_test.rb" ], shards: shards,
      results: { 0 => [ "test/system/a_test.rb", "test/a_test.rb" ] })

    stdout, stderr, status = gate(run_dir)

    assert status.success?, stderr
    assert_equal "complete", JSON.parse(stdout).fetch("status")
  end

  private
    # The manifest assigns one file to the first shard and leaves the second
    # shard empty.
    def shards
      { 0 => [ "test/system/a_test.rb" ], 1 => [] }
    end

    # The full committed list split across two shards.
    def full_shards
      { 0 => [ "test/system/a_test.rb", "test/system/c_test.rb" ], 1 => [ "test/system/b_test.rb" ] }
    end

    def full_files
      %w[test/system/a_test.rb test/system/b_test.rb test/system/c_test.rb]
    end

    def gate(run_dir, run_dirs: nil, shards: 2, run_id: "4242", commit: nil, manifest: :default, repository: REPOSITORY)
      dirs = run_dirs || [ run_dir ]
      args = [ "--commit", commit || @commit,
               "--run-id", run_id, "--run-attempt", "1", "--repository", repository,
               "--shards", shards.to_s ]
      path = manifest == :default ? @manifest : manifest
      args += [ "--manifest", path ] unless path.nil?
      args += dirs.flat_map { |dir| [ "--run-dir", dir ] }
      cli(*args)
    end

    # Writes a manifest naming one system test, verified against the commit.
    def write_manifest
      path = File.join(@root, "manifest.json")
      selection = JSON.parse(Open3.capture3(
        File.join(ROOT, "test/support/bin/select-affected-tests"), "--root", @work,
        "--base", @base, "--head", @commit, "--comparison", "push"
      ).first)
      script = <<~RUBY
        require "json"
        require_relative "#{File.join(ROOT, 'test/support/project')}"
        selection = JSON.parse(File.read(ARGV[0]))
        manifest = TestSieve::SystemManifest.build(policy: FixtureProject::POLICY, root: ARGV[1], selection: selection, commit: ARGV[2], shards: 2)
        puts JSON.generate(manifest)
      RUBY
      selection_path = File.join(@root, "selection.json")
      File.write(selection_path, JSON.generate(selection))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, selection_path, @work, @commit)
      raise stderr unless status.success?

      File.write(path, stdout)
      path
    end

    # The ownership rules the selector reads.
    def write_ownership
      owners = {}
      %w[a b c].each do |name|
        owners[name] = {
          "sources" => [ "app/#{name}.rb" ], "inputs" => [], "notes" => name,
          "tests" => { "unit" => [ "test/#{name}_test.rb" ], "learner" => [ "test/system/#{name}_test.rb" ] }
        }
      end
      manifest = { "version" => 1, "default" => "full_suite", "broad_changes" => [], "owners" => owners }
      write("config/test_ownership.yml", YAML.dump(manifest))
    end

    # Writes the records one run leaves behind: one per shard, plus the
    # combined run document.
    def write_run(files:, shards:, results: {}, exit_status: {}, mode: "selected", directory: "run",
      total: nil, run_id: "4242", outcomes: {})
      run_dir = File.join(@root, directory)
      FileUtils.mkdir_p(run_dir)
      total ||= shards.size
      checksum = mode == "selected" ? manifest_checksum : nil
      shards.each do |index, assigned|
        shard_results = results.fetch(index, assigned)
        write_outcomes(run_dir, index, files: shard_results, total:, run_id:, outcome: outcomes[index])
        record = {
          "shard_index" => index, "exit_status" => exit_status.fetch(index, 0),
          "duration_seconds" => 1.0, "files" => assigned, "empty" => assigned.empty?,
          "run_files" => files,
          "commit" => @commit, "run_id" => run_id, "run_attempt" => "1",
          "shard_total" => total, "files_digest" => files_digest(files),
          "mode" => mode, "manifest_checksum" => checksum,
          "outcomes" => "shard-#{index}/tmp/test-results/system-shard-#{index}/outcomes.jsonl"
        }
        File.write(File.join(run_dir, "shard-#{index}.json"), JSON.generate(record))
      end
      File.write(File.join(run_dir, "run.json"), JSON.pretty_generate({
        "commit" => @commit, "shard_total" => total, "mode" => mode,
        "manifest_checksum" => checksum,
        "files" => files, "files_digest" => files_digest(files),
        "run_id" => run_id, "run_attempt" => "1"
      }))
      run_dir
    end

    # Writes an outcome stream in the shape the telemetry reporter produces.
    def write_outcomes(run_dir, index, files:, total: 2, run_id: "4242", outcome: nil)
      path = File.join(run_dir, "shard-#{index}", "tmp/test-results/system-shard-#{index}/outcomes.jsonl")
      FileUtils.mkdir_p(File.dirname(path))
      metadata = {
        "suite" => "system-shard-#{index}", "shard" => "shard-#{index}-of-#{total}",
        "commit" => @commit, "dirty" => false, "workflow_run_id" => run_id,
        "workflow_run_attempt" => "1", "repository" => REPOSITORY,
        "seed" => 1, "runner" => "runner", "workflow" => "ci",
        "fixture_image" => "image", "browser" => { "name" => "chrome", "version" => "1",
          "driver" => "1", "selenium" => "1" }
      }
      records = [ record("run_start", metadata, index, total, run_id) ]
      files.each_with_index do |file, position|
        name = file.sub(%r{\Atest/}, "").tr("/", "_").sub(/_test\.rb\z/, "")
        result = {
          "test_id" => "SystemTest##{name}_thing",
          "test_class" => "SystemTest", "test_name" => "#{name}_thing",
          "file" => file, "line" => 3, "execution_index" => position + 1,
          "outcome" => outcome || "pass", "duration_seconds" => 0.1
        }
        if %w[fail error].include?(outcome)
          result["error_class"] = "Minitest::Assertion"
          result["error_message"] = "boom"
          result["backtrace"] = [ "test/system/a_test.rb:3" ]
        end
        records << record("test_result", metadata, index, total, run_id, result)
      end
      records << record("run_end", metadata, index, total, run_id, "completed" => true, "interrupted" => false)
      File.write(path, records.map { |entry| JSON.generate(entry) }.join("\n") + "\n")
    end

    def record(type, metadata, index, total, run_id, extra = {})
      identity = "#{run_id}/1/system-shard-#{index}/shard-#{index}-of-#{total}"
      {
        "schema_version" => 1, "type" => type,
        "run_id" => identity,
        "run_key" => "#{REPOSITORY}/#{identity}",
        "timestamp" => "2026-01-01T00:00:00Z", "metadata" => metadata
      }.merge(extra)
    end

    # The checksum of the manifest the caller vouches for.
    def manifest_checksum
      @manifest_checksum
    end

    def files_digest(files)
      require "digest"
      Digest::SHA256.hexdigest(JSON.generate(files.sort))
    end

    def write(path, content)
      absolute = File.join(@work, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
    end

    def git(*args)
      output, error, status = Open3.capture3("git", *args, chdir: @work)
      raise error unless status.success?

      output.strip
    end

    def cli(*args)
      Open3.capture3(BIN, "--root", @work, *args, chdir: @work)
    end
end

# frozen_string_literal: true

require "json"
require "open3"

require_relative "run_result"
require_relative "system_manifest"

module TestSieve
  # Checks that a browser-test run covered exactly the list it was asked to
  # cover.
  #
  # The gate answers one question: did every assigned file run, in the tested
  # commit, in the named workflow run? It does not approve skipping tests. A
  # verified manifest proves integrity; the gate proves execution.
  #
  # The caller supplies the shard count and the run identity. The gate never
  # infers them from the records it reads, because a record that claims to be
  # the only shard would otherwise decide what the run had to cover.
  #
  # The run's records decide whether the run was selected or a full fallback.
  # A selected run is checked against the trusted manifest. A full run is
  # checked against the committed browser tests, and the manifest is never
  # read: a fallback exists because the selection was unusable.
  #
  # A run may span several directories. Separate matrix jobs write separate
  # directories, and the gate combines them into one decision.
  class SystemRunGate
    class Invalid < StandardError; end

    COMMIT = /\A[0-9a-f]{40}\z/

    attr_reader :errors, :report

    def initialize(root:, manifest_path:, expected_commit:, run_id:, run_attempt:, repository:, shards:, run_dirs:, policy:, record_parser:)
      @policy, @record_parser = policy, record_parser
      @root = File.expand_path(root)
      @manifest_path = manifest_path
      @expected_commit = expected_commit
      @run_id = run_id
      @run_attempt = run_attempt
      @repository = repository
      @shards = shards
      @run_dirs = Array(run_dirs)
      @errors = []
    end

    # Verifies the run. Returns true when every required shard succeeded and
    # every assigned file produced a result.
    def call
      @errors = []
      verify_expected_identity
      result = read_result
      verify_mode(result)
      @report = build_report(result)
      @errors.empty?
    rescue Invalid => error
      @errors << error.message
      @report = { "status" => "failed", "errors" => @errors, "shards" => [] }
      false
    end

    private
      # The caller's identity must be usable before anything is read from it.
      def verify_expected_identity
        unless COMMIT.match?(@expected_commit.to_s)
          raise Invalid, "the expected commit must be a full commit sha"
        end
        unless @shards.is_a?(Integer) && @shards.positive?
          raise Invalid, "the expected shard count must be a positive integer"
        end
        if @run_id.to_s.strip.empty?
          raise Invalid, "the expected run id must not be empty"
        end
        raise Invalid, "the expected run attempt must not be empty" if @run_attempt.to_s.strip.empty?
        raise Invalid, "the expected repository must not be empty" if @repository.to_s.strip.empty?
      end

      def expected_identity
        {
          "repository" => @repository,
          "workflow_run_id" => @run_id,
          "workflow_run_attempt" => @run_attempt,
          "commit" => @expected_commit
        }
      end

      # The run's records, merged across the run directories. A separate
      # matrix job contributes the shard it ran.
      def read_result
        if @run_dirs.empty?
          raise Invalid, "no run directory was given"
        end

        result = RunResult.new(run_dirs: @run_dirs, expected: expected_identity, root: @root, shards: @shards,
          policy: @policy, record_parser: @record_parser)
        result.call
        @errors.concat(result.errors)
        result
      end

      # The records decide which of the two the run was. Every record must
      # agree.
      def verify_mode(result)
        case result.mode
        when "selected" then verify_selected(result)
        when "full" then verify_full(result)
        else @errors << "the run does not record whether it was selected or full"
        end
      end

      # A selected run must name the trusted manifest and cover exactly its
      # assignments.
      def verify_selected(result)
        manifest = verify_manifest
        return unless manifest

        total = manifest.dig("assignments", "total")
        unless total == @shards
          @errors << "the manifest assigns #{total} shards, but the run uses #{@shards}"
        end
        verify_assignments(result, expected_assignments(manifest.fetch("files").keys))
        verify_manifest_checksum(result, manifest)
      end

      # The trusted manifest the caller vouches for. It is verified against
      # the tested commit before it is compared with the run.
      def verify_manifest
        if @manifest_path.to_s.strip.empty?
          @errors << "a selected run needs the expected manifest"
          return nil
        end

        manifest = SystemManifest.from_file(root: @root, path: @manifest_path, expected_commit: @expected_commit, policy: @policy)
        manifest
      rescue SystemManifest::Invalid => error
        @errors << "the expected manifest is not valid: #{error.message}"
        nil
      end

      # A full run must have covered every committed browser test. The
      # manifest is not read: a fallback exists because the selection was
      # unusable.
      def verify_full(result)
        files = full_system_files
        verify_assignments(result, expected_assignments(files))
        return unless result.files && result.files.sort != files

        @errors << "the full run did not cover every committed system test"
      end

      # The files each shard must have run. Every file appears in exactly one
      # shard.
      def expected_assignments(files)
        shards = Array.new(@shards) { [] }
        files.sort.each_with_index { |file, index| shards[index % @shards] << file }
        shards
      end

      # The run's records must match the expectation exactly. A record that
      # claims a different assignment is a claim the gate does not accept.
      def verify_assignments(result, expected)
        result.shards.each do |shard|
          assigned = shard["files"].sort
          next if assigned == (expected[shard["index"]] || []).sort

          @errors << "shard #{shard['index']} did not run the files it was assigned"
        end
        expected.flatten.sort.each do |file|
          count = result.assigned.count(file)
          next if count == 1

          @errors << "the run assigned #{file} to #{count} shards"
        end
        (result.assigned.uniq - expected.flatten).each do |file|
          @errors << "the run assigned #{file}, which was not in the expected list"
        end
      end

      # A selected run must name the manifest it ran. A run that names
      # another manifest, or names none, did not run the list the caller
      # vouches for.
      def verify_manifest_checksum(result, manifest)
        return if result.manifest_checksum == manifest.fetch("checksum")

        @errors << "the run names a different manifest than the expected one"
      end

      # The committed system tests of the tested commit.
      def full_system_files
        @full_system_files ||= begin
          output, error, status = Open3.capture3("git", "ls-tree", "-r", "-z", @expected_commit,
            chdir: @root)
          raise Invalid, "cannot read the committed system tests: #{error.strip}" unless status.success?

          output.split("\0").filter_map { |entry| regular_system_test(entry) }.sort
        end
      end

      # The path of a committed system test that is a regular blob.
      def regular_system_test(entry)
        metadata, path = entry.split("\t", 2)
        return nil unless metadata.to_s.split(" ")[1] == "blob"
        return nil unless %w[ 100644 100755 ].include?(metadata.to_s.split(" ")[0])

        path if @policy.test?(path.to_s) && @policy.system?(path.to_s)
      end

      def build_report(result)
        {
          "status" => @errors.empty? ? "complete" : "failed",
          "mode" => result.mode,
          "commit" => @expected_commit,
          "run_id" => @run_id,
          "run_attempt" => @run_attempt,
          "shards_expected" => @shards,
          "files" => result.files || [],
          "shards" => result.shards || [],
          "errors" => @errors
        }
      end
  end
end

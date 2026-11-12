# frozen_string_literal: true

require "digest"
require "json"

require_relative "comparison"
require_relative "shard_evidence"

module TestSieve
  # Reads the records one browser-test run produced and checks that the run
  # covered exactly the list it was asked to cover.
  #
  # The shard count comes from the caller. The records never decide it. A
  # record that claims to be the only shard would otherwise decide what the
  # run had to cover.
  #
  # The runner writes one document per shard and one per run. The shard
  # document carries the shared run identity, so a separate matrix job can
  # hand its shard to an aggregate gate without a separate upload step.
  class RunResult
    class Invalid < StandardError; end

    MODES = %w[ selected full ].freeze

    attr_reader :run_dirs, :mode, :commit, :files, :run_id, :run_attempt,
      :manifest_checksum, :files_digest, :assigned

    # The verified shards of the run.
    def shards
      @verified_shards || []
    end

    def initialize(run_dirs:, expected:, root:, shards:, policy:, record_parser:)
      @policy, @record_parser = policy, record_parser
      @run_dirs = Array(run_dirs).map { |dir| File.expand_path(dir) }
      @expected = expected
      @root = File.expand_path(root)
      @shards = shards
      @errors = []
    end

    # Reads the run records and verifies them. Returns true when the run is
    # consistent and every shard proved its assignment.
    def call
      @errors = []
      @result_ids = {}
      @shard_records = shard_records
      read_run_records
      read_identity
      verify_identity
      verify_shards
      verify_no_duplicate_results_across_shards
      @errors.empty?
    end

    def errors
      @errors
    end

    # The digest of the resolved file list. Two runs that covered the same
    # files produce the same digest, whatever else they recorded.
    def self.files_digest(files)
      Digest::SHA256.hexdigest(JSON.generate(files.sort))
    end

    private
      def shard_records
        records = {}
        @run_dirs.each do |dir|
          shard_paths(dir).each { |path| collect_shard(records, path, dir) }
        end
        records
      end

      def collect_shard(records, path, dir)
        record = read_json(path)
        unless record.is_a?(Hash)
          @errors << "#{File.basename(path)} must contain a shard object"
          return
        end

        index = record["shard_index"]
        unless index.is_a?(Integer)
          @errors << "#{File.basename(path)} has no integer shard index"
          return
        end

        if records.key?(index)
          @errors << "the run records shard #{index} more than once"
          return
        end
        records[index] = [ record, dir ]
      end

      def shard_paths(dir)
        Dir.glob(File.join(dir, "shard-*.json")).sort
      end

      # The combined document the local multi-shard runner writes. It is
      # optional: a single matrix job's shard records carry the same
      # identity.
      def read_run_records
        @run_records = @run_dirs.filter_map do |dir|
          path = File.join(dir, "run.json")
          next unless File.exist?(path)

          record = read_json(path)
          unless record.is_a?(Hash)
            @errors << "the run document must be an object"
            next
          end
          record
        end
      end

      # The run identity comes from the shard records. Every shard of one run
      # must name the same run.
      def read_identity
        records = @shard_records.values.map(&:first)
        return if records.empty?

        @commit = records.first["commit"]
        @run_id = records.first["run_id"]
        @run_attempt = records.first["run_attempt"]
        @mode = records.first["mode"]
        @manifest_checksum = records.first["manifest_checksum"]
        @files_digest = records.first["files_digest"]
        @assigned = records.flat_map { |record| record["files"].is_a?(Array) ? record["files"] : [] }
        @files = run_files(records)
      end

      # The list the whole run covers. Every shard record names it, so a
      # single shard job hands the gate the same list as any other.
      def run_files(records)
        list = records.filter_map { |record| record["run_files"] }.first
        list.is_a?(Array) ? list : @assigned
      end

      def read_json(path)
        JSON.parse(File.binread(path), object_class: Comparison::UniqueObject)
      rescue JSON::ParserError => error
        @errors << "cannot read #{File.basename(path)}: #{error.message}"
        nil
      end

      def verify_identity
        if @shard_records.empty?
          @errors << "the run records no shard results"
          return
        end

        unless MODES.include?(@mode)
          @errors << "run mode must be selected or full"
        end
        if @commit != @expected["commit"]
          @errors << "run commit #{@commit.inspect} does not match the expected commit #{@expected['commit']}"
        end
        if @run_id != @expected["workflow_run_id"]
          @errors << "run id #{@run_id.inspect} does not match the expected run id #{@expected['workflow_run_id'].inspect}"
        end
        if @run_attempt != @expected["workflow_run_attempt"]
          @errors << "run attempt #{@run_attempt.inspect} does not match the expected attempt #{@expected['workflow_run_attempt'].inspect}"
        end
        if @files_digest != self.class.files_digest(@files)
          @errors << "run file list digest does not match the recorded list"
        end
        verify_uniform_records
        verify_run_records
      end

      # Every shard record must describe the same run: the same identity, the
      # same mode, the same manifest, and the same file list. A record that
      # disagrees is not evidence about this run.
      def verify_uniform_records
        @shard_records.each do |index, (record, _)|
          {
            "commit" => [ @commit, "a different commit" ],
            "run_id" => [ @run_id, "a different run id" ],
            "run_attempt" => [ @run_attempt, "a different run attempt" ],
            "mode" => [ @mode, "a different selected-or-full decision" ],
            "manifest_checksum" => [ @manifest_checksum, "a different manifest" ],
            "files_digest" => [ @files_digest, "a different file list" ],
            "run_files" => [ @files, "a different file list" ],
            "shard_total" => [ @shards, "a different shard total" ]
          }.each do |key, (expected, description)|
            next if record[key] == expected

            @errors << "shard #{index} names #{description} than the run"
          end
        end
      end

      def verify_run_records
        @run_records.compact.each { |record| verify_run_record(record) }
      end

      def verify_run_record(record)
        {
          "commit" => [ @commit, "a different commit" ],
          "run_id" => [ @run_id, "a different run id" ],
          "run_attempt" => [ @run_attempt, "a different run attempt" ],
          "mode" => [ @mode, "a different selected-or-full decision" ],
          "files_digest" => [ @files_digest, "a different file list" ],
          "files" => [ @files, "a different file list" ]
        }.each do |key, (expected, description)|
          next if record[key] == expected

          @errors << "the run document names #{description} than the shards"
        end
      end

      def verify_shards
        return if @shard_records.empty?

        expected_indexes = @shards.times.to_a
        missing = expected_indexes - @shard_records.keys
        unless missing.empty?
          @errors << "run is missing shard records for #{missing.join(', ')}"
        end
        extra = @shard_records.keys - expected_indexes
        unless extra.empty?
          @errors << "run records shards outside the shard count: #{extra.sort.join(', ')}"
        end

        @verified_shards = expected_indexes.filter_map { |index| verify_shard(index) }
      end

      def verify_shard(index)
        entry = @shard_records[index]
        return nil unless entry

        record, dir = entry
        files = record["files"]
        unless files.is_a?(Array) && files.all? { |file| file.is_a?(String) }
          @errors << "shard #{index} does not record its assigned files"
          return nil
        end
        exit_status = record["exit_status"]
        unless exit_status.is_a?(Integer)
          @errors << "shard #{index} does not record its exit status"
          exit_status = 1
        end
        empty = record["empty"]
        unless [ true, false ].include?(empty)
          @errors << "shard #{index} does not record whether its assignment was empty"
          empty = false
        end
        if empty != files.empty?
          @errors << "shard #{index} records an empty assignment that does not match its files"
        end

        evidence = ShardEvidence.new(
          shard_index: index, total: @shards, files:, exit_status:, empty:,
          outcomes: outcomes_path(record, dir), expected: @expected, inventory: inventory,
          policy: @policy, record_parser: @record_parser
        )
        unless evidence.call
          @errors.concat(evidence.errors)
        end
        @result_ids[index] = evidence.result_ids
        { "index" => index, "files" => files, "empty" => empty, "exit_status" => exit_status }
      end

      # The same test may run in only one shard. A test that ran in two
      # shards is not evidence of two executions.
      def verify_no_duplicate_results_across_shards
        seen = {}
        @result_ids.each do |index, ids|
          ids.each do |id|
            if seen.key?(id)
              @errors << "shards #{seen[id]} and #{index} recorded the same test #{id}"
            else
              seen[id] = index
            end
          end
        end
      end

      # The committed test files of the tested commit. A recorded result may
      # only claim a source that the tested commit contains.
      def inventory
        @inventory ||= begin
          commit = @commit || @expected["commit"]
          output, error, status = Open3.capture3("git", "ls-tree", "-r", "-z", commit,
            chdir: @root)
          raise Invalid, "cannot read the committed test files: #{error.strip}" unless status.success?

          output.split("\0").filter_map { |entry| regular_test_path(entry) }
        end
      end

      # The path of a committed test file that is a regular blob. A symlink
      # or a submodule is not a source a result may claim.
      def regular_test_path(entry)
        metadata, path = entry.split("\t", 2)
        return nil unless metadata.to_s.split(" ")[1] == "blob"
        return nil unless %w[ 100644 100755 ].include?(metadata.to_s.split(" ")[0])

        path if @policy.test?(path.to_s)
      end

      # The outcome stream the shard produced, if it recorded one. The path
      # is relative to the directory that holds the shard record.
      def outcomes_path(record, dir)
        path = record["outcomes"]
        return nil unless path.is_a?(String) && !path.empty?

        File.expand_path(path, dir)
      end
  end
end

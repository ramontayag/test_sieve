# frozen_string_literal: true

require "json"

require_relative "run_evidence"

module TestSelection
  # Verifies the execution evidence of one browser-test shard.
  #
  # A nonempty shard must prove that it executed at least one test from every
  # file it was assigned. A shard with an empty assignment must prove that it
  # executed nothing. The two cases are different contracts, so they are
  # checked differently.
  #
  # The nonempty case reuses TestSelection::RunEvidence, which owns the
  # outcome-stream format rules, the run identity checks, and the source
  # attribution rules. The empty case has no outcome stream to parse, so it
  # is checked from the recorded assignment and shard records.
  class ShardEvidence
    attr_reader :shard_index, :errors, :result_ids

    def initialize(shard_index:, total:, files:, exit_status:, empty:, outcomes:, expected:, policy:, record_parser:, inventory: [])
      @policy, @record_parser = policy, record_parser
      @shard_index = shard_index
      @total = total
      @files = files
      @exit_status = exit_status
      @empty = empty
      @outcomes = outcomes
      @expected = expected
      @inventory = inventory
      @errors = []
      @result_ids = []
    end

    # Verifies the shard. Returns true when the shard proves its assignment.
    def call
      if @empty
        verify_empty
      else
        verify_nonempty
      end
      @errors.empty?
    end

    private
      def verify_empty
        unless @exit_status.zero?
          @errors << "shard #{@shard_index} has an empty assignment but exited #{@exit_status}"
        end
        results = read_results
        unless results.empty?
          @errors << "shard #{@shard_index} has an empty assignment but recorded #{results.size} test results"
        end
        return if @files.empty?

        @errors << "shard #{@shard_index} is marked empty but is assigned #{@files.size} files"
      end

      def verify_nonempty
        unless @exit_status.zero?
          @errors << "shard #{@shard_index} exited #{@exit_status}"
        end
        results = read_results
        verify_file_coverage(results)
        verify_no_foreign_system_files(results)
        verify_no_duplicate_results(results)
        verify_no_failed_results(results)
      end

      # Reads the shard's outcome stream and returns its test results.
      def read_results
        @result_ids = []
        return [] if @outcomes.nil? || !File.exist?(@outcomes)

        content = File.binread(@outcomes)
        return [] if @empty && content.strip.empty?

        if @empty
          empty_results(content)
        else
          verified_results(content)
        end
      end

      def empty_results(content)
        verified_results(content, allow_empty: true)
      end

      def verified_results(content, allow_empty: false)
        evidence = RunEvidence.new(run: run_identity, expected: @expected, outcomes: content, inventory: @inventory,
          policy: @policy, record_parser: @record_parser, allow_empty:)
        results = evidence.call
        @result_ids = results.map { |result| result["test_id"] }
        results
      rescue Invalid, JSON::ParserError, ArgumentError => error
        @errors << "shard #{@shard_index}: #{error.message}"
        []
      end

      # The identity RunEvidence checks: the suite that executed the results
      # and the shard that ran them.
      def run_identity
        { "suite" => "system-shard-#{@shard_index}", "result_suite" => "system",
          "shard" => "shard-#{@shard_index}-of-#{@total}" }
      end

      # Every assigned file must have produced at least one result. A file
      # that produced none did not run.
      #
      # Only a result the system suite owns counts. A result another suite
      # executed is real evidence of an execution, but it does not show that
      # the system suite ran the assigned file.
      def verify_file_coverage(results)
        observed = owned_system_results(results).map { |result| result["file"] }.compact.uniq
        missing = @files - observed
        return if missing.empty?

        @errors << "shard #{@shard_index} has no recorded result for #{missing.sort.join(', ')}"
      end

      # A shard may only run the browser tests it was assigned. A result for
      # another browser test belongs to another shard. A test another suite
      # ran may still be recorded; it does not stand in for the browser
      # suite's own files.
      def verify_no_foreign_system_files(results)
        foreign = owned_system_results(results).map { |result| result["file"] }.compact.uniq - @files
        return if foreign.empty?

        @errors << "shard #{@shard_index} recorded results for browser tests it was not assigned: #{foreign.sort.join(', ')}"
      end

      def owned_system_results(results)
        results.select { |result| owned_by_system?(result) }
      end

      def owned_by_system?(result)
        result["source"] == "owned" && result["source_suite"] == "system" && result["execution_suite"] == "system"
      end

      def verify_no_duplicate_results(results)
        ids = results.map { |result| result["test_id"] }
        return if ids.uniq == ids

        @errors << "shard #{@shard_index} recorded duplicate test results"
      end

      # A recorded failure is a failed test, whatever the shard's exit status
      # claims.
      def verify_no_failed_results(results)
        failed = results.select { |result| %w[ fail error ].include?(result["outcome"]) }
        return if failed.empty?

        names = failed.map { |result| result["test_id"] }.uniq.sort
        @errors << "shard #{@shard_index} recorded failed tests: #{names.join(', ')}"
      end
  end
end

# frozen_string_literal: true

require_relative "source_attribution"

module TestSieve
  class RunEvidence
    def initialize(run:, expected:, outcomes:, policy:, record_parser:, inventory: [], allow_empty: false)
      @policy, @record_parser = policy, record_parser
      @minimum_records = allow_empty ? 2 : 3
      @run, @expected, @outcomes = run, expected, outcomes
      @inventory = inventory
    end

    def call
      raise Invalid, "truncated or empty outcome JSONL" unless @outcomes.end_with?("\n")
      records = @outcomes.lines.map { |line| parse_record(line) }
      verify_envelope(records)
      results = records[1...-1]
      verify_results(results)
      results.map { |result| result.merge("screenshot" => screenshot_evidence(result)).merge(attribution(result)) }
    end

    def compare_timings(timings, results)
      @timings = timings
      raise Invalid, "timing/outcome metadata disagree" unless @timings.is_a?(Hash) && @timings["metadata"] == results.first["metadata"]
      verify_timings(results)
    end

    private
      def parse_record(line)
        payload = JSON.parse(line, object_class: Comparison::UniqueObject)
        record = @record_parser.call(JSON.generate(payload))
        unless record.is_a?(Hash) && %w[ run_start test_result run_end ].include?(record["type"])
          raise Invalid, "unknown normalized record"
        end
        record
      end

      def verify_metadata(metadata)
        raise Invalid, "missing run metadata" unless metadata.is_a?(Hash)
        wanted = @expected.slice(*Comparison::IDENTITY).merge(@run.slice("suite", "shard")).merge("dirty" => false)
        wanted.each do |key, value|
          raise Invalid, "run metadata #{key} mismatch" unless metadata[key] == value
        end
      end

      def verify_envelope(records)
        verify_boundaries(records)
        records.each do |record|
          verify_metadata(record["metadata"])
          raise Invalid, "conflicting run metadata" unless record["metadata"] == records.first["metadata"]
          raise Invalid, "missing record timestamp" unless record["timestamp"].is_a?(String)
          Time.iso8601(record["timestamp"])
          verify_run_key(record)
        end
      end

      def verify_boundaries(records)
        types = records.map { |record| record["type"] }
        valid = records.size >= @minimum_records && types.first == "run_start" && types.last == "run_end" && types[1...-1].all? { |type| type == "test_result" }
        raise Invalid, "expected one start, test results, and one end" unless valid
        ending = records.last
        raise Invalid, "incomplete or interrupted run" unless ending["completed"] == true && ending["interrupted"] == false
      end

      def verify_run_key(record)
        identity = [ @expected["workflow_run_id"], @expected["workflow_run_attempt"], @run["suite"], @run["shard"] ].join("/")
        raise Invalid, "run_id mismatch" unless record["run_id"] == identity
        raise Invalid, "run_key mismatch" unless record["run_key"] == "#{@expected['repository']}/#{identity}"
      end

      def verify_results(results)
        ids = results.map { |result| result["test_id"] }
        raise Invalid, "duplicate test results" unless ids.uniq == ids
        results.each_with_index do |result, index|
          verify_test(result, "test_class")
          raise Invalid, "test identity mismatch" unless result["test_id"] == "#{result['test_class']}##{result['test_name']}"
          raise Invalid, "missing or conflicting execution index" unless result["execution_index"] == index + 1
          verify_outcome(result)
        end
      end

      def verify_outcome(result)
        raise Invalid, "unsupported test outcome" unless %w[ pass fail error skip ].include?(result["outcome"])
        verify_failure(result)
      end

      def verify_failure(result)
        return unless %w[ fail error ].include?(result["outcome"])
        %w[ error_class error_message ].each do |key|
          raise Invalid, "missing failure #{key}" unless result[key].is_a?(String) && !result[key].empty?
        end
        raise Invalid, "invalid failure backtrace" unless result["backtrace"].is_a?(Array) && result["backtrace"].all? { |line| line.is_a?(String) }
      end

      def verify_test(test, class_key)
        raise Invalid, "test must be an object" unless test.is_a?(Hash)
        [ class_key, "test_name" ].each do |key|
          raise Invalid, "missing test #{key}" unless test[key].is_a?(String) && !test[key].empty?
        end
        raise Invalid, "invalid source line" unless test["line"].is_a?(Integer) && test["line"].positive?
        verify_duration(test["duration_seconds"])
      end

      # Attributes a recorded result to a repository source file.
      #
      # A result whose source belongs to another suite, or whose source is
      # outside the repository, is still a real execution. It stays in the
      # report with that fact recorded. It cannot stand in for the suite that
      # owns the file, and it cannot satisfy coverage for any file.
      def attribution(result)
        SourceAttribution.new(
          file: result["file"],
          execution_suite: @run.fetch("result_suite", @run.fetch("suite")),
          inventory: @inventory, policy: @policy
        ).call
      end

      def verify_duration(value)
        raise Invalid, "invalid duration" unless value.is_a?(Numeric) && value.finite? && value >= 0
      end

      def verify_timings(results)
        raise Invalid, "timings must be an object" unless @timings.is_a?(Hash)
        verify_metadata(@timings["metadata"])
        raise Invalid, "timing suite mismatch" unless @timings["suite"] == @run["suite"]
        verify_duration(@timings["duration_seconds"])
        tests = @timings.fetch("tests")
        raise Invalid, "timing tests must be an array" unless tests.is_a?(Array)
        raise Invalid, "timing count mismatch" unless @timings["test_count"] == tests.size && tests.size == results.size
        compare_test_timings(tests, results)
      end

      def compare_test_timings(tests, results)
        tests.each { |test| verify_test(test, "class_name") }
        actual = tests.map { |test| test_signature(test, "class_name") }.sort
        wanted = results.map { |test| test_signature(test, "test_class") }.sort
        raise Invalid, "timing results disagree with outcomes" unless actual == wanted
      end

      def test_signature(test, class_key)
        [ test[class_key], test["test_name"], test["file"], test["line"], test["duration_seconds"] ]
      end

      def screenshot_evidence(result)
        evidence = result.values_at("error_class", "error_message", "backtrace").flatten.compact
        matches = evidence.grep(/screenshot|capybara.screenshot|\.diff\.png/i)
        { "association" => matches.empty? ? "unknown" : "result_failure", "evidence" => matches }
      end
  end
end

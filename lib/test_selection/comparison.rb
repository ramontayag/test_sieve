# frozen_string_literal: true

require "json"
require "digest"
require_relative "../test_ownership/selector"
require_relative "run_evidence"

module TestSelection
  class Invalid < StandardError; end

  class Comparison
    IDENTITY = %w[ repository workflow_run_id workflow_run_attempt commit ].freeze

    # JSON otherwise silently replaces conflicting keys with the last value.
    class UniqueObject < Hash
      def []=(key, value)
        raise Invalid, "duplicate JSON key: #{key}" if key?(key)
        super
      end
    end

    def initialize(root:, selection:, expected:, policy:, record_parser:)
      @policy, @record_parser = policy, record_parser
      @root, @selection_path, @expected_path = root, selection, expected
      @report = { "status" => "inconclusive", "reasons" => [], "artifacts" => [],
        "results" => %w[ unit system ].to_h { |suite| [ suite, { "selected" => [], "omitted" => [], "unowned" => [] } ] },
        "screenshot_coverage" => "Only explicit result failure evidence is associated; other screenshot associations are unknown.",
        "limits" => "Evidence consistency only; not method-inventory completeness, selection eligibility, or failure causation." }
    end

    def call
      selection = read_json(@selection_path)
      expected = read_json(@expected_path)
      verify_selection(selection, expected)
      verify_expected(expected)
      @report["selection"] = selection
      @report["expected_run"] = expected
      compare_runs(selection, expected)
      verify_file_coverage
      @report["status"] = "complete" if @report["reasons"].empty?
      @report
    rescue Invalid, JSON::ParserError, ArgumentError, KeyError, TypeError, SystemCallError, TestOwnership::Selector::Unavailable => error
      @report["reasons"] << error.message
      @report
    end

    private
      def read_artifact(path)
        raise Invalid, "artifact path must be a nonempty string" unless path.is_a?(String) && !path.empty?
        content = File.binread(path)
        @report["artifacts"] << { "path" => path, "sha256" => Digest::SHA256.hexdigest(content), "bytes" => content.bytesize }
        content
      end

      def read_json(path)
        JSON.parse(read_artifact(path), object_class: UniqueObject)
      end

      def verify_selection(selection, expected)
        raise Invalid, "selection and expected run must be objects" unless selection.is_a?(Hash) && expected.is_a?(Hash)
        raise Invalid, "tested commit differs from selection" unless expected.fetch("commit") == selection.fetch("source_sha")
        raise Invalid, "comparison must be pr, push, or manual" unless %w[ pr push manual ].include?(selection["comparison"])
        verify_commits(selection)
        verify_replay(selection)
        inventory = TestOwnership::Selector.new(policy: @policy, root: @root, base: selection["source_sha"], head: selection["source_sha"], comparison: "push").call
        @inventory = inventory.values_at("unit_files", "system_files").flatten
      end

      def verify_commits(selection)
        %w[ source_sha base_sha requested_base_sha ].each do |key|
          raise Invalid, "missing or invalid #{key}" unless selection[key].is_a?(String) && selection[key].match?(/\A[0-9a-f]{40}\z/)
        end
        raise Invalid, "ownership identity unavailable" unless selection["ownership_digest"] && selection["base_ownership_digest"]
      end

      def verify_replay(selection)
        comparison = selection.fetch("comparison") == "manual" ? "push" : selection.fetch("comparison")
        replay = TestOwnership::Selector.new(policy: @policy, root: @root, base: selection.fetch("requested_base_sha"),
          head: selection.fetch("source_sha"), comparison:).call
        replay.except("requested_base", "requested_head", "comparison").each do |key, value|
          raise Invalid, "selection #{key} differs from recomputed selection" unless selection[key] == value
        end
      end

      def verify_expected(expected)
        verify_identity(expected)
        shards = expected.fetch("system_shards")
        raise Invalid, "expected system shards must be a nonempty unique array" unless shards.is_a?(Array) && !shards.empty? && shards.uniq == shards
        verify_shards(shards)
        verify_runs(expected.fetch("runs"), shards)
      end

      def verify_identity(expected)
        IDENTITY.each do |key|
          value = expected[key]
          raise Invalid, "expected #{key} is required" unless value.is_a?(String) && !value.empty? && value != "unavailable"
        end
      end

      def verify_runs(runs, shards)
        verify_run_objects(runs)
        identities = runs.map { |run| [ run.fetch("result_suite", run.fetch("suite")), run.fetch("shard") ] }
        required = [ [ "unit", "unavailable" ] ] + shards.map { |shard| [ "system", shard ] }
        verify_run_identities(identities, required)
        verify_artifact_paths(runs)
      end

      def verify_run_objects(runs)
        valid = runs.is_a?(Array) && runs.all? { |run| run.is_a?(Hash) }
        raise Invalid, "runs must be an array of objects" unless valid
      end

      def verify_run_identities(identities, required)
        raise Invalid, "duplicate suite/shard evidence" unless identities.uniq == identities
        raise Invalid, "extra suite/shard evidence" unless (identities - required).empty?

        missing = required - identities
        return if missing.empty?

        @report["reasons"] << "missing suite/shard evidence: #{missing.map { |suite, shard| "#{suite}/#{shard}" }.join(', ')}"
      end

      def verify_artifact_paths(runs)
        paths = runs.flat_map { |run| [ run.fetch("outcomes"), run.fetch("timings") ] }
        raise Invalid, "artifact paths must be distinct strings" unless paths.all? { |path| path.is_a?(String) } && paths.uniq == paths
      end

      def verify_shards(shards)
        return if shards == [ "unavailable" ]
        required = shards.size.times.map { |index| "shard-#{index}-of-#{shards.size}" }
        raise Invalid, "expected system shards must enumerate the complete shard set" unless shards.sort == required.sort
      end

      def compare_runs(selection, expected)
        seen = {}
        expected.fetch("runs").sort_by { |run| [ run.fetch("result_suite", run.fetch("suite")), run["shard"] ] }.each do |run|
          compare_run(run, selection, expected, seen)
        end
        @report["results"].each_value do |groups|
          groups.each_value { |results| results.sort_by! { |result| [ result["file"], result["test_id"] ] } }
        end
      end

      # A file counts as covered when the suite that owns it ran a test from
      # that file. A result another suite executed, or a result with no
      # repository source, does not cover the file.
      def verify_file_coverage
        observed = @report["results"].values.flat_map { |groups| groups.values_at("selected", "omitted").flatten }
          .select { |result| result["source"] == "owned" && result["source_suite"] == result["execution_suite"] }
          .map { |result| result["file"] }
        missing = @inventory - observed
        @report["reasons"] << "missing test files: #{missing.sort.join(', ')}" unless missing.empty?
      end

      def compare_run(run, selection, expected, seen)
        outcomes = read_artifact(run.fetch("outcomes"))
        evidence = RunEvidence.new(run:, expected:, outcomes:, inventory: @inventory, policy: @policy, record_parser: @record_parser)
        records = evidence.call
        result_suite = run.fetch("result_suite", run.fetch("suite"))
        records.each do |record|
          key = [ result_suite, record["test_id"] ]
          if seen[key]
            reject_duplicate(run, key, record)
            next
          end
          seen[key] = true
          group = selection_group(selection, record)
          record["selection_group"] = group
          @report["results"][result_suite][group] << record
          track_anomaly(record)
        end
        compare_timings(run, evidence, records)
      rescue Invalid, JSON::ParserError, ArgumentError, KeyError, TypeError, SystemCallError => error
        @report["reasons"] << "#{run.fetch('result_suite', run.fetch('suite'))}/#{run['shard']}: #{error.message}"
      end

      # Rejected duplicates retain failure evidence but cannot establish coverage.
      def reject_duplicate(run, key, record)
        suite = run.fetch("result_suite", run.fetch("suite"))
        (@report["results"][suite]["rejected_duplicates"] ||= []) << record
        @report["reasons"] << "#{run.fetch('result_suite', run.fetch('suite'))}/#{run['shard']}: " \
          "duplicate test across shards: #{key.join('/')} (#{record['file']})"
      end

      # The selection decides by the file that owns the source. A result whose
      # source belongs to another suite is judged by that suite's file list,
      # while the report keeps the suite that executed it.
      def selection_group(selection, record)
        source_suite = record["source_suite"]
        return "unowned" if source_suite.nil?

        selection.fetch("#{source_suite}_files").include?(record["file"]) ? "selected" : "omitted"
      end

      # Results that cannot be attributed to a repository file are reported.
      # Cross-suite results remain visible with their execution identity, but
      # do not make a complete report inconclusive by themselves.
      def track_anomaly(record)
        if record["source"] == "unowned"
          @report["reasons"] << "unowned test source: #{record['file']} (#{record['test_id']})"
        end
      end

      def compare_timings(run, evidence, records)
        timing_path = run.fetch("timings")
        raise Invalid, timing_path if timing_path.start_with?("missing ")

        evidence.compare_timings(read_json(timing_path), records)
      end
  end
end

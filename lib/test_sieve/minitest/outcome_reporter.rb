# frozen_string_literal: true

require "minitest"
require "time"
require_relative "../telemetry/metadata"
require_relative "../telemetry/writer"

module TestSieve
  module Minitest
    class OutcomeReporter < ::Minitest::AbstractReporter
      attr_reader :output_path

      def initialize(output_path:, root: Dir.pwd, app_root: nil, metadata: nil)
        super()
        @output_path = output_path
        @root = File.expand_path(app_root || root)
        @writer = Telemetry::Writer.new(output_path: output_path)
        @metadata = metadata || Telemetry::Metadata.new(app_root: @root)
        @execution_index = 0
        @interrupted = false
        @recording_failed = false
      end

      def start
        append_run_record("run_start")
      rescue StandardError => error
        @recording_failed = true
        warn "TestSieve::Minitest::OutcomeReporter: could not write run start: #{error.class}: #{error.message}"
      end

      def record(result)
        @execution_index += 1
        append_run_record("test_result", result: result)
      rescue StandardError => error
        @recording_failed = true
        warn "TestSieve::Minitest::OutcomeReporter: could not record #{result.name}: #{error.class}: #{error.message}"
      end

      def report
        append_run_record("run_end", completed: !(@interrupted || @recording_failed), interrupted: @interrupted)
      rescue StandardError => error
        warn "TestSieve::Minitest::OutcomeReporter: could not write run end: #{error.class}: #{error.message}"
      end

      def interrupted!
        @interrupted = true
      end

      def passed?
        !@interrupted
      end

      private

      def append_run_record(type, result: nil, completed: nil, interrupted: nil)
        metadata = @metadata.run_metadata
        identity = [metadata["workflow_run_id"], metadata["workflow_run_attempt"], metadata["suite"], metadata["shard"]]
        payload = {
          "schema_version" => Telemetry::Record::SCHEMA_VERSION,
          "type" => type,
          "run_id" => identity.join("/"),
          "run_key" => [metadata["repository"], *identity].join("/"),
          "timestamp" => Time.now.utc.iso8601,
          "metadata" => metadata
        }
        payload["completed"] = completed unless completed.nil?
        payload["interrupted"] = interrupted unless interrupted.nil?
        payload.merge!(result_payload(result)) if result
        @writer.append(payload)
      end

      def result_payload(result)
        file, line = result.source_location
        payload = {
          "test_id" => "#{result.klass}##{result.name}",
          "test_class" => result.klass,
          "test_name" => result.name,
          "file" => relative_path(file),
          "line" => line,
          "execution_index" => @execution_index,
          "outcome" => outcome_for(result),
          "duration_seconds" => result.time
        }
        failure = result.failures.first
        if failure && !result.skipped?
          payload["error_class"] = failure.class.name
          payload["error_message"] = sanitize_message(failure.message)
          payload["backtrace"] = Array(failure.backtrace).map(&:to_s)
        end
        payload
      end

      def outcome_for(result)
        return "skip" if result.skipped?
        return "pass" if result.failures.empty?
        return "error" if result.failures.first.is_a?(::Minitest::UnexpectedError)

        result.failures.first.is_a?(::Minitest::Assertion) ? "fail" : "error"
      end

      def sanitize_message(message)
        message.to_s.gsub(%r{/[^\s:]+:\d+}, "<location>").gsub(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/, "<email>").slice(0, 2_000)
      end

      def relative_path(file)
        return file if file.nil?

        expanded = File.expand_path(file, @root)
        prefix = @root.end_with?("/") ? @root : "#{@root}/"
        expanded.start_with?(prefix) ? expanded.delete_prefix(prefix) : expanded
      end
    end
  end
end

# frozen_string_literal: true

require "minitest"
require "fileutils"
require "json"
require_relative "../telemetry/metadata"

module TestSieve
  module Minitest
    class TimingReporter < ::Minitest::AbstractReporter
      attr_reader :output_path, :suite_name, :root

      alias app_root root

      def initialize(output_path:, suite_name:, root: Dir.pwd, app_root: nil, metadata: nil)
        super()
        @output_path = output_path
        @suite_name = suite_name
        @root = File.expand_path(app_root || root)
        @metadata = metadata || Telemetry::Metadata.new(app_root: @root)
        @results = []
      end

      def start
        @start_time = ::Minitest.clock_time
        @run_metadata = @metadata.run_metadata
      end

      def record(result)
        @results << result
      end

      def report
        payload = {
          "suite" => @suite_name,
          "metadata" => @run_metadata,
          "duration_seconds" => @start_time ? ::Minitest.clock_time - @start_time : nil,
          "test_count" => @results.size,
          "tests" => sorted_tests
        }
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, JSON.pretty_generate(payload))
      rescue StandardError => error
        warn "TestSieve::Minitest::TimingReporter: could not write #{output_path} — #{error.class}: #{error.message}"
      end

      private

      def sorted_tests
        @results.map { |result| build_test_entry(result) }.sort_by do |entry|
          [-entry["duration_seconds"], entry["file"].to_s, entry["line"].to_i, entry["class_name"].to_s, entry["test_name"].to_s]
        end
      end

      def build_test_entry(result)
        file, line = result.source_location
        {
          "class_name" => result.klass,
          "test_name" => result.name,
          "file" => relative_path(file),
          "line" => line,
          "duration_seconds" => result.time
        }
      end

      def relative_path(file)
        return file if file.nil?

        expanded = File.expand_path(file, @root)
        prefix = @root.end_with?("/") ? @root : "#{@root}/"
        return "" if expanded == @root

        expanded.start_with?(prefix) ? expanded.delete_prefix(prefix) : expanded
      end
    end
  end
end

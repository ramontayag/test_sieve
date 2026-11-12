# frozen_string_literal: true

require "fileutils"
require_relative "record"

module TestSieve
  module Telemetry
    class Writer
      attr_reader :output_path

      def initialize(output_path:)
        @output_path = output_path
        @mutex = Mutex.new
      end

      def append(payload)
        record = Record.new(payload)
        line = record.to_jsonl
        @mutex.synchronize do
          FileUtils.mkdir_p(File.dirname(output_path))
          File.open(output_path, "a") do |file|
            file.write(line)
            file.write("\n")
            file.flush
          end
        end
        record
      end

      def records
        return [] unless File.exist?(output_path)

        File.readlines(output_path, chomp: true).reject(&:empty?).map { |line| Record.parse(line) }
      end
    end
  end
end

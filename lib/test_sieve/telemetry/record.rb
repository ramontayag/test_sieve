# frozen_string_literal: true

require "json"

module TestSieve
  module Telemetry
    SCHEMA_VERSION = 1

    class Record
      OUTCOMES = %w[pass fail error skip].freeze
      TYPES = %w[run_start test_result run_end].freeze
      SCHEMA_VERSION = 1

      attr_reader :payload

      def self.parse(line)
        payload = JSON.parse(line)
        raise ArgumentError, "record must be a JSON object" unless payload.is_a?(Hash)
        raise ArgumentError, "unsupported schema version" unless payload["schema_version"] == SCHEMA_VERSION
        raise ArgumentError, "unsupported record type" unless TYPES.include?(payload["type"])

        new(payload)
      rescue JSON::ParserError => error
        raise ArgumentError, "malformed JSON record: #{error.message}"
      end

      def initialize(payload)
        @payload = payload.transform_keys(&:to_s)
        validate!
      end

      def to_jsonl
        JSON.generate(payload)
      end

      private

      def validate!
        raise ArgumentError, "record type is required" if payload["type"].to_s.empty?
        return unless payload["type"] == "test_result"

        raise ArgumentError, "test outcome is required" unless OUTCOMES.include?(payload["outcome"])
        raise ArgumentError, "test identity is required" if payload["test_id"].to_s.empty?
      end
    end
  end
end

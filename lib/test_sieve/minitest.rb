# frozen_string_literal: true

begin
  require "minitest"
rescue LoadError => error
  raise unless error.path == "minitest"

  raise LoadError, "test_sieve/minitest requires Minitest. Add gem 'minitest' to your application's Gemfile."
end

require_relative "minitest/outcome_reporter"
require_relative "minitest/timing_reporter"

module TestSieve
  module Minitest
    module InterruptTracking
      def __run(...)
        super
      rescue Interrupt
        TestSieve::Minitest.interrupted!
        raise
      end

      def run_all_suites(...)
        super
      rescue Interrupt
        TestSieve::Minitest.interrupted!
        raise
      end

      def empty_run!(...)
        return false if TestSieve::Minitest.interrupted?

        super
      end
    end
    private_constant :InterruptTracking

    def self.install!(outcome_output: nil, timing_output: nil, suite: nil, root: Dir.pwd, metadata: nil)
      if outcome_output && timing_output && same_destination?(outcome_output, timing_output)
        raise ArgumentError, "outcomes and timings must use different files"
      end
      @configuration = {outcome_output: outcome_output, timing_output: timing_output, suite: suite, root: root, metadata: metadata}
      return unless outcome_output || timing_output
      return if @registered

      ::Minitest.register_plugin(self)
      @registered = true
      nil
    end

    def self.minitest_plugin_init(_options)
      outcome_output, timing_output, suite, root, metadata = @configuration.values_at(:outcome_output, :timing_output, :suite, :root, :metadata)
      return unless outcome_output || timing_output

      env = suite ? ENV.to_h.merge("TEST_SUITE_NAME" => suite) : ENV
      metadata ||= Telemetry::Metadata.new(app_root: root, env: env)
      @outcome_reporter = nil
      if outcome_output
        @outcome_reporter = OutcomeReporter.new(output_path: outcome_output, root: root, metadata: metadata)
        ::Minitest.reporter << @outcome_reporter
        ::Minitest.singleton_class.prepend(InterruptTracking) unless ::Minitest.singleton_class < InterruptTracking
      end
      if timing_output
        ::Minitest.reporter << TimingReporter.new(output_path: timing_output,
          suite_name: suite || metadata.run_metadata.fetch("suite"), root: root, metadata: metadata)
      end
    end

    def self.interrupted!
      @outcome_reporter&.interrupted!
    end

    def self.interrupted?
      @outcome_reporter ? !@outcome_reporter.passed? : false
    end

    def self.same_destination?(first, second)
      return true if File.exist?(first) && File.exist?(second) && File.identical?(first, second)

      destination(first) == destination(second)
    end
    private_class_method :same_destination?

    def self.destination(path)
      return File.realpath(path) if File.exist?(path) || File.symlink?(path)

      resolved = File.expand_path(File.join(destination(File.dirname(path)), File.basename(path)))
      File.exist?(resolved) || File.symlink?(resolved) ? File.realpath(resolved) : resolved
    end
    private_class_method :destination
  end
end

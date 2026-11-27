# frozen_string_literal: true

require "json"
require "minitest/test"

module TestSieve
  module Minitest
    # Diagnostic only. A call outside the sole runner thread has no known owner.
    class SerialCalls < ::Minitest::AbstractReporter
      class << self
        attr_reader :current

        def install!(output:, root:, commit:, targets:, workers:)
          return unless output
          @configuration = {output: output, root: root, commit: commit, targets: targets, workers: workers}
          return if @registered
          ::Minitest.register_plugin(self)
          @registered = true
        end

        def minitest_plugin_init(options)
          @current = new(**@configuration, seed: options[:seed])
          ::Minitest.reporter << @current
          ::Minitest::Test.prepend(Windows) unless ::Minitest::Test < Windows
        end
      end

      module Windows
        def run
          collector = SerialCalls.current
          collector&.enter(self)
          super
        ensure
          collector&.leave
        end
      end
      private_constant :Windows

      def initialize(output:, root:, commit:, targets:, workers:, seed:)
        super()
        @output, @root, @targets = output, root, targets
        @identity = {version: 1, commit: commit, pid: Process.pid, ruby: RUBY_VERSION, workers: workers, seed: seed}
        @runner = Thread.current
        @traces = []
      end

      def start
        @io = File.open(@output, File::WRONLY | File::CREAT | File::EXCL | File::APPEND, 0o600)
        @io.sync = true
        unless @identity[:commit].to_s.match?(/\A[0-9a-f]{40}\z/) && @identity[:workers].to_s == "1" &&
            ENV["TEST_SHARD_TOTAL"].to_s.empty? && ENV["TEST_SHARD_INDEX"].to_s.empty?
          emit("unsupported")
          return
        end
        prefix = File.realpath(@root) + File::SEPARATOR
        methods = @targets.call.uniq
        raise ArgumentError if methods.empty?
        methods.each do |method|
          raise ArgumentError unless method.is_a?(Method) || method.is_a?(UnboundMethod)
          file = File.realpath(method.source_location.first).delete_prefix(prefix)
          raise ArgumentError if file.start_with?(File::SEPARATOR)
          trace = TracePoint.new(:call) { observe(file) }
          @traces << trace
          trace.enable(target: method)
        end
        emit("start")
        @active = true
      rescue StandardError, LoadError
        unavailable
      end

      def enter(test)
        return unless @active
        return unsupported unless sole_runner? && !@id
        @id = "#{test.class}##{test.name}"
        @phase = "lifecycle"
        @body = TracePoint.new(:call, :return) do |event|
          @phase = event.event == :call ? "body" : "lifecycle" if sole_runner?
        end
        @body.enable(target: test.method(test.name))
        emit("test_start", test_id: @id)
      rescue StandardError
        unavailable
      end

      def leave
        return unless @active
        return unsupported unless sole_runner? && @id
        emit("test_end", test_id: @id)
        @body.disable
        @id = nil
      rescue StandardError
        unavailable
      end

      def report
        emit("end") if @active && sole_runner? && !@id
      rescue StandardError
        unavailable
      ensure
        stop
        begin
          @io&.close
        rescue IOError, SystemCallError
          warn "TestSieve: serial call evidence unavailable"
        end
      end

      private

      def observe(file)
        return unless @active
        return unsupported unless Process.pid == @identity[:pid]
        known = sole_runner? && @id
        emit("call", file: file, test_id: known || nil, phase: known ? @phase : "unknown",
          thread: Thread.current.object_id)
      rescue StandardError
        unavailable
      end

      def sole_runner?
        Process.pid == @identity[:pid] && Thread.current == @runner
      end

      def unsupported
        stop
        emit("unsupported", pid: Process.pid)
      end

      def unavailable
        stop
        warn "TestSieve: serial call evidence unavailable"
      end

      def stop
        @active = false
        @traces.each(&:disable)
        @body&.disable
      end

      def emit(type, **fields)
        @io.write(JSON.generate(@identity.merge(type: type).merge(fields)) + "\n")
      end
    end
  end
end

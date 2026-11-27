# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"

class SerialCallsTest < Minitest::Test
  def suite(workers: 1, fail_test: false, output: "events", extra: "")
    Dir.mktmpdir do |root|
      File.write("#{root}/suite.rb", <<~RUBY)
        gem "minitest", #{Gem.loaded_specs.fetch("minitest").version.to_s.inspect}
        require "minitest/autorun"
        require "test_sieve/minitest/serial_calls"
        def observed(value); end
        TestSieve::Minitest::SerialCalls.install!(output: #{output.inspect}, root: Dir.pwd,
          workers: #{workers}, commit: "a" * 40, targets: -> { [method(:observed)] })
        class Sample < Minitest::Test
          def setup; observed("private input"); end
          def test_saves
            observed("private input")
            Thread.new { observed("private input") }.join
            #{extra}
            assert #{!fail_test}
          end
        end
      RUBY
      log, status = Open3.capture2e({"RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "MT_NO_PLUGINS" => "1"}, RbConfig.ruby,
        "-I", File.expand_path("../lib", __dir__), "suite.rb", "--seed", "17", chdir: root)
      text = File.file?("#{root}/events") ? File.read("#{root}/events") : ""
      refute_includes text, root
      refute_includes text, "private input"
      yield text.lines.map { |line| JSON.parse(line) }, status, log
    end
  end

  def test_real_calls_distinguish_the_test_body_setup_and_an_unidentified_thread
    suite do |rows, status, log|
      assert status.success?, log
      assert_equal %w[start test_start call call call test_end end], rows.map { |r| r["type"] }
      calls = rows.select { |r| r["type"] == "call" }
      assert_equal [["Sample#test_saves", "lifecycle"], ["Sample#test_saves", "body"], [nil, "unknown"]],
        calls.map { |r| r.values_at("test_id", "phase") }
      assert_equal ["suite.rb"], calls.map { |r| r["file"] }.uniq
      assert_equal ["a" * 40, 17, 1], rows.first.values_at("commit", "seed", "workers")
    end
  end

  def test_unsupported_workers_do_not_run_tracing_or_hide_failures
    suite(workers: 2, fail_test: true) do |rows, status, log|
      refute status.success?, log
      assert_equal ["unsupported"], rows.map { |r| r["type"] }
      assert_includes log, "1 failures"
    end
  end

  def test_a_bad_output_path_does_not_fail_a_passing_suite
    suite(output: "suite.rb/events") do |rows, status, log|
      assert status.success?, log
      assert_empty rows
      assert_includes log, "serial call evidence unavailable"
    end
  end

  def test_forked_calls_invalidate_the_whole_file_even_if_the_parent_finishes
    skip unless Process.respond_to?(:fork)
    suite(extra: "Process.wait(fork { observed('private input'); exit! 0 })") do |rows, status, log|
      assert status.success?, log
      assert_equal ["unsupported"], rows.reject { |r| r["pid"] == rows.first["pid"] }.map { |r| r["type"] }
      assert_equal "end", rows.last.fetch("type")
    end
  end

  def test_an_interrupted_process_leaves_partial_evidence
    suite(extra: "exit! 43") do |rows, status, _log|
      assert_equal 43, status.exitstatus
      assert_equal "start", rows.first.fetch("type")
      refute_includes rows.map { |r| r.fetch("type") }, "end"
    end
  end
end

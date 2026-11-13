# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"

class MinitestInstallTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("minitest-install")
    @outcomes = File.join(@root, "results/outcomes.jsonl")
    @timings = File.join(@root, "results/timings.json")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_plugin_reports_real_pass_failure_error_and_skip_and_keeps_nonzero_exit
    output, status = run_suite(install: "outcome_output: #{@outcomes.inspect}, timing_output: #{@timings.inspect}, suite: 'custom', root: #{@root.inspect}")
    refute status.success?, output
    records = File.readlines(@outcomes).map { |line| JSON.parse(line) }
    assert_equal %w[run_start test_result test_result test_result test_result run_end], records.map { |record| record["type"] }
    assert_equal %w[error fail pass skip], records[1..4].map { |record| record["outcome"] }.sort
    assert_equal "custom", records.first.dig("metadata", "suite")
    assert_equal 123, records.first.dig("metadata", "seed")
    assert_equal "suite.rb", records[1]["file"]
    assert_equal true, records.last["completed"]
    timings = JSON.parse(File.read(@timings))
    assert_equal "custom", timings["suite"]
    assert_equal records.first["metadata"], timings["metadata"]
    assert_equal 4, timings["test_count"]
    assert timings["duration_seconds"] >= 0
  end

  def test_no_output_paths_means_no_reporters_or_automatic_environment_outputs
    output, status = run_suite(install: "", body: "def test_pass; assert true; end",
      env: {"TEST_OUTCOMES_OUTPUT" => @outcomes, "TEST_TIMING_OUTPUT" => @timings})
    assert status.success?, output
    assert_equal ["suite.rb"], Dir.children(@root)
  end

  def test_each_output_is_independently_optional
    [[:outcome_output, @outcomes], [:timing_output, @timings]].each do |key, path|
      output, status = run_suite(install: "#{key}: #{path.inspect}, root: #{@root.inspect}", body: "def test_pass; assert true; end")
      assert status.success?, output
      assert File.file?(path)
      FileUtils.remove_entry(File.dirname(path))
    end
  end

  def test_write_failures_do_not_hide_actual_test_failure_or_fail_a_passing_suite
    blocker = File.join(@root, "blocker")
    File.write(blocker, "not a directory")
    install = "outcome_output: #{File.join(blocker, "outcomes").inspect}, timing_output: #{File.join(blocker, "timings").inspect}"
    [true, false].each do |passing|
      output, status = run_suite(install: install, body: "def test_result; assert #{passing}; end")
      assert_equal passing, status.success?, output
      assert_includes output, "OutcomeReporter: could not write run start"
      assert_includes output, "TimingReporter: could not write"
    end
  end

  def test_install_twice_registers_only_one_pair_of_reporters
    args = "outcome_output: #{@outcomes.inspect}, timing_output: #{@timings.inspect}"
    output, status = run_suite(install: args, extra: "TestSieve::Minitest.install!(#{args})", body: "def test_pass; assert true; end")
    assert status.success?, output
    assert_equal 3, File.readlines(@outcomes).size
    assert_equal 1, JSON.parse(File.read(@timings))["test_count"]
  end

  def test_outcomes_and_timings_cannot_overwrite_the_same_destination
    FileUtils.mkdir_p(File.dirname(@outcomes))
    File.symlink(File.dirname(@outcomes), File.join(@root, "linked"))
    [@outcomes, "results/../results/outcomes.jsonl", "linked/outcomes.jsonl",
      "missing/../results/outcomes.jsonl", "missing/../linked/outcomes.jsonl"].each do |timing|
      output, status = run_suite(install: "outcome_output: #{@outcomes.inspect}, timing_output: #{timing.inspect}",
        body: "def test_pass; assert true; end")
      refute status.success?, output
      assert_includes output, "outcomes and timings must use different files"
      refute File.exist?(@outcomes)
    end
  end

  def test_sigint_marks_the_run_incomplete_when_minitest_catches_interrupt
    versions = Gem::Specification.find_all_by_name("minitest").map { |spec| spec.version.to_s }.uniq
      .select { |version| Gem::Version.new(version) >= Gem::Version.new("5.25") }
    versions.each do |version|
      output, status = run_suite(version: version, install: "outcome_output: #{@outcomes.inspect}",
        body: "def self.test_order; :alpha; end; def self.run_order; :alpha; end; def test_a_pass; assert true; end; def test_b_interrupt; Process.kill('INT', Process.pid); sleep 1; end")
      refute status.success?, "Minitest #{version}: #{output}"
      records = File.readlines(@outcomes).map { |line| JSON.parse(line) }
      assert_equal "run_start", records.first["type"], output
      assert_equal "run_end", records.last["type"], output
      assert_equal "pass", records[1]["outcome"], output
      assert_equal false, records.last["completed"], "Minitest #{version}: #{output}"
      assert_equal true, records.last["interrupted"], "Minitest #{version}: #{output}"
      FileUtils.remove_entry(File.dirname(@outcomes))
    end
  end

  def test_abrupt_exit_keeps_flushed_results_without_claiming_completion
    output, status = run_suite(install: "outcome_output: #{@outcomes.inspect}",
      body: "def self.test_order; :alpha; end; def self.run_order; :alpha; end; def test_a_pass; assert true; end; def test_b_abort; exit! 7; end")
    assert_equal 7, status.exitstatus, output
    records = File.readlines(@outcomes).map { |line| JSON.parse(line) }
    assert_equal %w[run_start test_result], records.map { |record| record["type"] }
    assert_equal "pass", records.last["outcome"]
  end

  def test_interrupting_the_first_test_cannot_exit_successfully
    output, status = run_suite(install: "outcome_output: #{@outcomes.inspect}",
      body: "def test_interrupt; Process.kill('INT', Process.pid); sleep 1; end")
    refute status.success?, output
    records = File.readlines(@outcomes).map { |line| JSON.parse(line) }
    assert_equal %w[run_start run_end], records.map { |record| record.fetch("type") }
    assert_equal false, records.last.fetch("completed")
    assert_equal true, records.last.fetch("interrupted")
  end

  def test_plugin_with_each_installed_supported_minitest_major
    [5, 6].each do |major|
      spec = Gem::Specification.find_all_by_name("minitest").select { |item| item.version.segments.first == major }.max_by(&:version)
      next unless spec

      output, status = run_suite(version: spec.version.to_s,
        install: "outcome_output: #{@outcomes.inspect}, timing_output: #{@timings.inspect}", body: "def test_pass; assert true; end")
      assert status.success?, "Minitest #{spec.version}: #{output}"
      assert File.file?(@outcomes), "Minitest #{spec.version}: #{output}"
      assert_equal "pass", JSON.parse(File.readlines(@outcomes)[1])["outcome"]
      assert_equal 1, JSON.parse(File.read(@timings))["test_count"]
      FileUtils.remove_entry(File.dirname(@outcomes))
    end
  end

  def test_optional_entrypoint_has_actionable_missing_dependency_error
    code = <<~RUBY
      module Kernel
        alias original_require require
        def require(path)
          if path == "minitest"
            error = LoadError.new("cannot load such file -- minitest")
            error.define_singleton_method(:path) { "minitest" }
            raise error
          end
          original_require(path)
        end
      end
      require "test_sieve/minitest"
    RUBY
    output, status = ruby("-e", code)
    refute status.success?
    assert_includes output, "Add gem 'minitest' to your application's Gemfile"
  end

  private

  def run_suite(install:, body: nil, extra: "", version: Gem.loaded_specs.fetch("minitest").version.to_s, env: {})
    body ||= <<~RUBY
      def test_pass; assert true; end
      def test_fail; flunk "failed person@example.invalid"; end
      def test_error; raise "boom"; end
      def test_skip; skip "later"; end
    RUBY
    File.write(File.join(@root, "suite.rb"), <<~RUBY)
      #{"gem 'minitest', #{version.inspect}" if version}
      require "minitest/autorun"
      require "test_sieve/minitest"
      TestSieve::Minitest.install!(#{install})
      #{extra}
      class ExampleTest < Minitest::Test
        #{body}
      end
    RUBY
    ruby(File.join(@root, "suite.rb"), "--seed", "123", env: env)
  end

  def ruby(*args, env: {})
    Open3.capture2e({"RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "MT_NO_PLUGINS" => "1"}.merge(env), RbConfig.ruby,
      "-I", File.expand_path("../lib", __dir__), *args, chdir: @root)
  end
end

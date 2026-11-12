# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "json"
require "yaml"

class ReadmeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_copying_the_map_and_reporter_selects_runs_and_records_tests
    Dir.mktmpdir("sieve-readme") do |root|
      @root = root
      readme = File.read(File.join(ROOT, "README.md"))
      maps = readme.scan(/```yaml\n(.*?)```/m).flatten
      ruby_examples = readme.scan(/```ruby\n(.*?)```/m).flatten
      reporter = ruby_examples.find { |code| code.include?("Minitest.install!") }
      policy = ruby_examples.find { |code| code.include?("Rails.policy(") }
      wrapper = ruby_examples.find { |code| code.include?("CLI.new(") }
      expected = readme.scan(/```json\n(.*?)```/m).flatten.map { |json| JSON.parse(json) }
      write("test_ownership.yml", maps.first)
      write("Gemfile.lock", "example lockfile\n")
      write("lib/shipping.rb", "# shipping\n")
      write("test/test_helper.rb", "require 'minitest/autorun'\n#{reporter}")
      write("config/test_sieve.rb", policy)
      write("script/test_affected.rb", wrapper)
      write_test("test/shipping_test.rb", "ShippingTest", "test_helper", "assert_equal 4, 2 + 2")
      write_test("test/system/checkout_test.rb", "CheckoutTest", "../test_helper", "assert true")
      write_test("test/unrelated_test.rb", "UnrelatedTest", "test_helper", "flunk 'unrelated failure'")
      write("bin/rails", <<~RUBY)
        abort "expected test command" unless ARGV.shift == "test"
        ARGV.each { |path| require File.expand_path(path) }
      RUBY
      write("bin/test", "#!/usr/bin/env ruby\nARGV.each { |path| require File.expand_path(path) }\n")
      FileUtils.chmod(0755, File.join(root, "bin/test"))
      git("init", "-q")
      git("config", "user.name", "README test")
      git("config", "user.email", "readme@example.invalid")
      base = commit
      write("lib/shipping.rb", "# changed shipping\n")
      commit

      assert_success(command("check"))
      selection = JSON.parse(assert_success(command("select", "--base", base)))
      expected.first.each { |key, value| assert_equal value, selection.fetch(key) }
      configured = JSON.parse(assert_success(command("select", "--config", "config/test_sieve.rb", "--base", base)))
      expected.first.each { |key, value| assert_equal value, configured.fetch(key) }
      env = { "RUBYLIB" => File.join(ROOT, "lib"), "TEST_OUTCOMES_OUTPUT" => nil,
        "TEST_TIMING_OUTPUT" => nil, "TEST_SUITE_NAME" => nil }
      assert_success(Open3.capture2e(env, RbConfig.ruby, "script/test_affected.rb",
        "--base", base, "--suite", "unit", chdir: root))

      outcomes = File.join(root, "..", "#{File.basename(root)}-outcomes.jsonl")
      timings = File.join(root, "..", "#{File.basename(root)}-timings.json")
      begin
        environment = { "TEST_OUTCOMES_OUTPUT" => outcomes, "TEST_TIMING_OUTPUT" => timings }
        assert_success(command("run", "--base", base, "--suite", "unit", environment: environment))
        records = File.readlines(outcomes).map { |line| JSON.parse(line) }
        assert_equal %w[run_start test_result run_end], records.map { |record| record.fetch("type") }
        assert_equal "test/shipping_test.rb", records[1].fetch("file")
        assert_equal "pass", records[1].fetch("outcome")
        assert_equal "unit", records[1].dig("metadata", "suite")
        assert_equal true, records.last.fetch("completed")
        assert_equal 1, JSON.parse(File.read(timings)).fetch("test_count")
      ensure
        FileUtils.rm_f([outcomes, timings])
      end

      write("lib/tax.rb", "# unmapped change\n")
      commit
      full = JSON.parse(assert_success(command("select", "--base", base)))
      assert_equal "full", full.fetch("mode")
      assert_includes full.fetch("unit_files"), "test/unrelated_test.rb"
      output, status = command("run", "--base", base, "--suite", "unit")
      refute status.success?, output
      assert_includes output, "unrelated failure"

      map = YAML.safe_load(maps.first)
      map.fetch("owners").merge!(YAML.safe_load(maps[1]))
      map.fetch("owners").fetch("shipping").merge!(YAML.safe_load(maps[2]))
      write("test_ownership.yml", YAML.dump(map))
      %w[lib/invoice.rb test/invoice_test.rb test/system/invoice_test.rb app/views/checkout/_shipping.html.erb test/fixtures/shipping_rates.yml].each do |path|
        write(path, "# example\n")
      end
      base = commit
      write("lib/shipping.rb", "# shipping changes affect invoices\n")
      commit
      dependent = JSON.parse(assert_success(command("select", "--base", base)))
      expected[1].each { |key, value| assert_equal value, dependent.fetch(key) }

      %w[app/views/checkout/_shipping.html.erb test/fixtures/shipping_rates.yml].each do |path|
        base = git("rev-parse", "HEAD").strip
        write(path, "# changed input\n")
        commit
        selection = JSON.parse(assert_success(command("select", "--base", base)))
        expected[1].each { |key, value| assert_equal value, selection.fetch(key) }
      end
    end
  end

  private

  def command(*args, environment: {})
    env = { "RUBYLIB" => File.join(ROOT, "lib"), "TEST_OUTCOMES_OUTPUT" => nil,
      "TEST_TIMING_OUTPUT" => nil, "TEST_SUITE_NAME" => nil }.merge(environment)
    Open3.capture2e(env, RbConfig.ruby, File.join(ROOT, "exe/test-sieve"), *args, chdir: @root)
  end

  def assert_success(result)
    output, status = result
    assert status.success?, output
    output
  end

  def write(path, contents)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), contents)
  end

  def write_test(path, klass, helper, assertion)
    write(path, "require_relative #{helper.inspect}\nclass #{klass} < Minitest::Test\n  def test_example\n    #{assertion}\n  end\nend\n")
  end

  def git(*args)
    output, status = Open3.capture2e("git", *args, chdir: @root)
    raise output unless status.success?
    output
  end

  def commit
    git("add", ".")
    git("commit", "-qm", "example change")
    git("rev-parse", "HEAD").strip
  end
end

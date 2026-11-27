# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"

class ShouldaDeclarationsTest < Minitest::Test
  def test_reports_the_matcher_declaration_in_both_reports
    Dir.mktmpdir do |root|
      File.write("#{root}/first.rb", <<~RUBY)
        class FirstTest < Minitest::Test
          extend Shoulda::Matchers::ActiveModel
          subject { Entry.new }
          should validate_presence_of(:title)
          def test_normal; assert true; end
          should "pass with a block" do
            assert true
          end
        end
      RUBY
      File.write("#{root}/second.rb", <<~RUBY)
        class SecondTest < Minitest::Test
          extend Shoulda::Matchers::ActiveModel
          subject { Entry.new }
          context "outer" do
            context "inner" do
              should validate_presence_of(:title)
            end
          end
        end
      RUBY
      # Two declarations produce the same Minitest ID. Neither can own it.
      %w[first second].each do |file|
        File.open("#{root}/#{file}.rb", "a") do |io|
          io.puts <<~RUBY
            class ReopenedTest < Minitest::Test
              extend Shoulda::Matchers::ActiveModel
              subject { Entry.new }
              should validate_presence_of(:title)
            end
          RUBY
        end
      end
      script = <<~RUBY
        require "minitest/autorun"
        require "active_model"
        require "shoulda-context"
        require "shoulda-matchers"
        require "test_sieve/minitest"
        TestSieve::Minitest.install!(outcome_output: "out.jsonl", timing_output: "time.json")
        class Entry
          include ActiveModel::Model
          attr_accessor :title
          validates :title, presence: true
        end
        require_relative "first"
        require_relative "second"
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-e", script, chdir: root)
      assert status.success?, output
      outcomes = File.readlines("#{root}/out.jsonl").map { |line| JSON.parse(line) }
      results = outcomes.select { |row| row["type"] == "test_result" }
      timings = JSON.parse(File.read("#{root}/time.json")).fetch("tests")
      [[results, "test_class"], [timings, "class_name"]].each do |rows, key|
        ambiguous = rows.select { |row| row[key] == "ReopenedTest" }
        assert_equal 1, ambiguous.size
        assert_match %r{/shoulda/context/context\.rb$}, ambiguous.first.fetch("file")
        refute ambiguous.first.key?("source_file")
        rows.reject! { |row| row[key] == "ReopenedTest" }
      end
      expected = [
        ["FirstTest", "first.rb", 4], ["FirstTest", "first.rb", 5], ["FirstTest", "first.rb", 6],
        ["SecondTest", "second.rb", 6]
      ]
      assert_equal expected, results.map { |r| r.values_at("test_class", "file", "line") }.sort
      assert_equal expected, timings.map { |r| r.values_at("class_name", "file", "line") }.sort
      assert_equal results.map { |r| r["test_id"] }.sort, timings.map { |r| "#{r['class_name']}##{r['test_name']}" }.sort
      [results, timings].each do |rows|
        rows.each do |row|
          if row["file"] == "first.rb" && row["line"] != 4
            refute row.key?("source_file")
          else
            assert_match %r{/shoulda/context/context\.rb$}, row.fetch("source_file")
            assert_operator row.fetch("source_line"), :>, 0
          end
        end
      end
    end
  end
end

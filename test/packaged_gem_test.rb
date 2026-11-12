# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "bundler"

class PackagedGemTest < Minitest::Test
  def test_installed_gem_runs_the_public_contract_outside_the_checkout
    root = File.expand_path("..", __dir__)
    Dir.mktmpdir("test-sieve-install") do |directory|
      artifact = File.join(directory, "test_sieve.gem")
      home = File.join(directory, "gems")
      Bundler.with_unbundled_env do
        run_command({}, root, "gem", "build", "test_sieve.gemspec", "--output", artifact)
        environment = { "GEM_HOME" => home, "GEM_PATH" => ([ home ] + Gem.path).join(File::PATH_SEPARATOR),
          "RUBYLIB" => nil, "RUBYOPT" => nil }
        run_command(environment, directory, "gem", "install", artifact, "--local", "--no-document")

        contract = File.read(File.join(__dir__, "public_api_test.rb"))
          .sub('require_relative "../lib/test_selection"', 'require "test_sieve"')
        script = <<~RUBY + contract
          require "test_sieve"
          installed = Gem.loaded_specs.fetch("test_sieve").full_gem_path
          abort "loaded from checkout" unless installed.start_with?(#{home.inspect} + "/")
          abort "wrong version" unless TestSelection::VERSION == "1.0.0"
        RUBY
        File.write(File.join(directory, "public_api_test.rb"), script)
        output = run_command(environment, directory, RbConfig.ruby, "public_api_test.rb")
        assert_match(/7 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, output)
      end
    end
  end

  private
    def run_command(environment, directory, *command)
      output, status = Open3.capture2e(environment, *command, chdir: directory)
      assert status.success?, "#{command.join(' ')}\n#{output}"
      output
    end
end

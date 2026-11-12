# frozen_string_literal: true

require "open3"
require "socket"

module TestSieve
  module Telemetry
    class Metadata
      UNAVAILABLE = "unavailable"

      def initialize(env: ENV, app_root: Dir.pwd, runner: nil, git_status: nil)
        @env = env
        @app_root = app_root
        @runner = runner
        @git_status = git_status
      end

      def run_metadata
        @run_metadata ||= {
          "suite" => presence(@env["TEST_SUITE_NAME"]) || UNAVAILABLE,
          "shard" => shard_metadata,
          "seed" => seed,
          "commit" => commit,
          "dirty" => dirty,
          "runner" => runner_identity,
          "workflow_run_id" => presence(@env["GITHUB_RUN_ID"]) || UNAVAILABLE,
          "workflow_run_attempt" => presence(@env["GITHUB_RUN_ATTEMPT"]) || UNAVAILABLE,
          "workflow" => presence(@env["GITHUB_WORKFLOW"]) || UNAVAILABLE,
          "repository" => presence(@env["GITHUB_REPOSITORY"]) || UNAVAILABLE,
          "browser" => browser_metadata,
          "fixture_image" => presence(@env["TEST_FIXTURE_IMAGE"]) || UNAVAILABLE
        }
      end

      private

      def presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end

      def shard_metadata
        total = presence(@env["TEST_SHARD_TOTAL"])
        index = presence(@env["TEST_SHARD_INDEX"])
        total && index ? "shard-#{index}-of-#{total}" : UNAVAILABLE
      end

      def seed
        value = presence(@env["TEST_ENV_NUMBER"]) || presence(@env["SEED"])
        return value.to_i if value

        defined?(::Minitest) && ::Minitest.respond_to?(:seed) ? ::Minitest.seed : UNAVAILABLE
      end

      def commit
        output, status = Open3.capture2("git", "rev-parse", "HEAD", chdir: @app_root, err: File::NULL)
        status.success? ? output.strip : UNAVAILABLE
      rescue StandardError
        UNAVAILABLE
      end

      def dirty
        return @git_status unless @git_status.nil?

        output, status = Open3.capture2("git", "status", "--porcelain", chdir: @app_root, err: File::NULL)
        status.success? ? !output.strip.empty? : UNAVAILABLE
      rescue StandardError
        UNAVAILABLE
      end

      def runner_identity
        return @runner if presence(@runner)

        presence(@env["GITHUB_RUNNER_NAME"]) || presence(@env["HOSTNAME"]) || Socket.gethostname
      rescue StandardError
        UNAVAILABLE
      end

      def browser_metadata
        return unavailable_browser unless @env["TEST_SUITE_NAME"].to_s.start_with?("system")

        {
          "name" => presence(@env["TEST_BROWSER_NAME"]) || UNAVAILABLE,
          "version" => presence(@env["TEST_BROWSER_VERSION"]) || UNAVAILABLE,
          "driver" => presence(@env["TEST_DRIVER_VERSION"]) || UNAVAILABLE,
          "selenium" => presence(@env["TEST_SELENIUM_VERSION"]) || Gem.loaded_specs["selenium-webdriver"]&.version&.to_s || UNAVAILABLE
        }
      end

      def unavailable_browser
        {"name" => UNAVAILABLE, "version" => UNAVAILABLE, "driver" => UNAVAILABLE, "selenium" => UNAVAILABLE}
      end
    end
  end
end

# frozen_string_literal: true

require "test_sieve"
require "rbconfig"

module TestSieve
  module Rails
    def self.policy(manifest_path: "test_ownership.yml", required_roles: %w[unit system],
      optional_roles: [], role_suites: { "unit" => "unit", "system" => "system" },
      rules: nil, identity: "test-sieve-rails-v1", test_pattern: "test/**/*_test.rb",
      system_pattern: "test/system/**/*_test.rb")
      Policy.new(manifest_path:, required_roles:, optional_roles:, role_suites:, identity:,
        test_pattern:, system_pattern:,
        rules: rules || [manifest_path, "config/test_sieve.rb", "Gemfile", "Gemfile.lock"])
    end

    def self.run(selection:, root: Dir.pwd, suite: "all", command: [RbConfig.ruby, "bin/rails", "test"])
      raise ArgumentError, "suite must be unit, system, or all" unless %w[unit system all].include?(suite)
      unless command.is_a?(Array) && !command.empty? && command.all? { |arg| arg.is_a?(String) && !arg.empty? && !arg.include?("\0") }
        raise ArgumentError, "command must be a nonempty array of arguments"
      end
      root = File.realpath(root)
      groups = validated_groups(selection, root)
      active_groups = groups.select { |name, files| !files.empty? && (suite == "all" || suite == name) }
      multiple_suites = active_groups.size > 1
      if multiple_suites && %w[TEST_OUTCOMES_OUTPUT TEST_TIMING_OUTPUT].any? { |key| ENV.key?(key) }
        raise ArgumentError, "reporter output paths cannot be shared across suites; run --suite unit and --suite system separately with separate output paths"
      end
      active_groups.each do |name, files|
        environment = { "TEST_SUITE_NAME" => multiple_suites ? name : ENV.fetch("TEST_SUITE_NAME", name) }
        system(environment, [command.first, command.first], *command.drop(1), *files, chdir: root, exception: false)
        status = $?
        return 127 unless status
        return status.exitstatus || 128 + status.termsig unless status.success?
      end
      0
    end

    def self.validated_groups(selection, root)
      unless selection.is_a?(Hash) && %w[selected full].include?(selection["mode"])
        raise ArgumentError, "selection must have a selected or full mode"
      end
      groups = %w[unit system].to_h do |suite|
        files = selection["#{suite}_files"]
        raise ArgumentError, "selection #{suite}_files must be an array" unless files.is_a?(Array)
        files.each { |path| validate_path!(path, root) }
        [suite, files]
      end
      files = groups.values.flatten
      raise ArgumentError, "selection contains no test files" if files.empty?
      raise ArgumentError, "selection contains duplicate test files" unless files.uniq == files
      groups
    end
    private_class_method :validated_groups

    def self.validate_path!(path, root)
      unless path.is_a?(String) && !path.empty? && !path.start_with?("-", "/") &&
          !path.match?(/[[:cntrl:]:\\*?\[\]{}]/) && !path.split("/").include?("..") &&
          Pathname.new(path).cleanpath.to_s == path
        raise ArgumentError, "unsafe test path #{path.inspect}"
      end
      absolute = File.join(root, path)
      unless File.file?(absolute) && File.realpath(absolute).start_with?("#{root}/")
        raise ArgumentError, "test file is missing or outside the repository: #{path.inspect}"
      end
    end
    private_class_method :validate_path!
  end
end

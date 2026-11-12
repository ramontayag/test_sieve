# frozen_string_literal: true

module TestSieve
  # Consumer configuration is data, so replay can check its exact identity.
  class Policy
    attr_reader :manifest_path, :test_pattern, :system_pattern, :required_roles, :optional_roles, :rules, :role_suites

    def initialize(manifest_path:, test_pattern:, system_pattern:, required_roles:, optional_roles:, role_suites:, rules:, identity:)
      @manifest_path = manifest_path
      @test_pattern = test_pattern
      @system_pattern = system_pattern
      @required_roles = required_roles
      @optional_roles = optional_roles
      @rules = rules
      @role_suites = role_suites
      @identity = identity
      roles = required_roles + optional_roles
      unless roles.sort == role_suites.keys.sort && role_suites.values.all? { |suite| %w[ unit system ].include?(suite) }
        raise ArgumentError, "every test role must name its unit or system suite"
      end
    end

    def test?(path)
      File.fnmatch?(test_pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end

    def system?(path)
      File.fnmatch?(system_pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end

    def suite_for(path)
      system?(path) ? "system" : "unit"
    end

    def digest
      Digest::SHA256.hexdigest(JSON.generate([ manifest_path, test_pattern, system_pattern,
        required_roles, optional_roles, role_suites.sort, rules, @identity ]))
    end
  end
end

# frozen_string_literal: true

require_relative "../../lib/test_sieve"

module FixtureProject
  POLICY = TestSieve::Policy.new(
    manifest_path: "config/test_ownership.yml",
    test_pattern: "test/**/*_test.rb", system_pattern: "test/system/**/*_test.rb",
    required_roles: %w[ unit learner ], optional_roles: %w[ admin review ],
    role_suites: { "unit" => "unit", "learner" => "system", "admin" => "system", "review" => "system" },
    identity: "fixture-policy-v1",
    rules: %w[ config/test_ownership.yml lib/test_sieve/ bin/check-test-ownership bin/select-affected-tests ]
  )
  RECORD_PARSER = ->(line) { JSON.parse(line) }
end

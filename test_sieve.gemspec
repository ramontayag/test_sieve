# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "test_sieve"
  spec.version = "1.0.0"
  spec.authors = [ "Ramon Tayag" ]
  spec.license = "MIT"
  spec.summary = "Select affected tests and verify execution evidence."
  spec.description = "Framework-neutral Git test selection, ownership validation, shard manifests, and execution evidence verification."
  spec.homepage = "https://github.com/ramontayag/test_sieve"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "docs/**/*.md"]
  spec.require_paths = [ "lib" ]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.add_dependency "json", ">= 3.1", "< 4"
  spec.add_dependency "psych", ">= 4", "< 6"
end

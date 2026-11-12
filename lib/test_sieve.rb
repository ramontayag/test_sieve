# frozen_string_literal: true

require "digest"
require "json"
require "time"

module TestSieve
  VERSION = "1.0.0"

  def self.engine_digest
    root = __dir__
    paths = Dir.glob("**/*.rb", base: root).sort
    Digest::SHA256.hexdigest(paths.map { |path| "#{path}\0#{File.binread(File.join(root, path))}\0" }.join)
  end
end

require_relative "test_sieve/policy"
require_relative "test_sieve/ownership_validator"
require_relative "test_sieve/selector"
require_relative "test_sieve/system_manifest"
require_relative "test_sieve/comparison"
require_relative "test_sieve/summary"
require_relative "test_sieve/run_result"
require_relative "test_sieve/system_run_gate"

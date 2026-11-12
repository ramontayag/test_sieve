# frozen_string_literal: true

require "digest"
require "json"
require "time"

module TestSelection
  VERSION = "1.0.0"

  def self.engine_digest
    root = __dir__
    paths = Dir.glob("**/*.rb", base: root).sort
    Digest::SHA256.hexdigest(paths.map { |path| "#{path}\0#{File.binread(File.join(root, path))}\0" }.join)
  end
end

require_relative "test_selection/policy"
require_relative "test_ownership/validator"
require_relative "test_ownership/selector"
require_relative "test_selection/system_manifest"
require_relative "test_selection/comparison"
require_relative "test_selection/summary"
require_relative "test_selection/run_result"
require_relative "test_selection/system_run_gate"

# frozen_string_literal: true

require_relative "../test_ownership/selector"

module TestSelection
  # Classifies the source file a recorded test result points at.
  #
  # Three cases exist, and they are different problems:
  #
  #   owned        The file is a repository test file in the tested commit. The
  #                result belongs to the suite that owns the file.
  #   cross_suite  The file is a repository test file, but another suite
  #                executed it. The result is real evidence of an execution. It
  #                is not evidence for the suite that owns the file.
  #   unowned      The file is outside the repository. The result cannot be
  #                attributed to any repository file, so it cannot satisfy file
  #                coverage.
  #
  # A path that tries to leave the repository through traversal, or that names
  # no test file at all, is rejected outright. It is not a source that the
  # repository owns, and it is not an outside path either.
  class SourceAttribution
    TRAVERSAL = %r{(?:\A|/)\.\.?(?:/|\z)}.freeze

    attr_reader :file, :source, :source_suite

    def initialize(file:, execution_suite:, inventory:, policy:)
      @policy = policy
      @file = file
      @execution_suite = execution_suite
      @inventory = inventory
    end

    # Returns a result hash describing the attribution. Raises Invalid when the
    # path cannot be used as evidence at all.
    def call
      raise Invalid, "test source path must be a nonempty string" unless file.is_a?(String) && !file.empty?
      raise Invalid, "unsafe test source path: #{file}" if unsafe?

      if repository_relative?
        raise Invalid, "test source path is not a test file: #{file}" unless test_file?

        owned_attribution
      else
        unowned_attribution
      end
    end

    private
      def unsafe?
        TRAVERSAL.match?(file) || file.match?(/[[:cntrl:]]/) || Pathname.new(file).cleanpath.to_s != file
      end

      def test_file?
        !file.match?(/[[:cntrl:]]/) && @policy.test?(file)
      end

      # A path inside the repository is recorded relative to the repository
      # root. A path outside it keeps its absolute form.
      def repository_relative?
        !file.start_with?("/")
      end

      def owned_attribution
        unless @inventory.include?(file)
          raise Invalid, "test source absent from tested commit: #{file}"
        end

        owning_suite = suite_for(file)
        { "file" => file, "source" => "owned", "source_suite" => owning_suite,
          "execution_suite" => @execution_suite, "cross_suite" => owning_suite != @execution_suite }
      end

      def unowned_attribution
        { "file" => file, "source" => "unowned", "source_suite" => nil,
          "execution_suite" => @execution_suite, "cross_suite" => false }
      end

      # The suite that owns a repository test file. The path decides the
      # owning suite, not the suite that happened to execute the result.
      def suite_for(path)
        @policy.suite_for(path)
      end
  end
end

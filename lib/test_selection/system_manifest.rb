# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require_relative "../test_ownership/selector"

module TestSelection
  # Builds and verifies the fixed list of system tests a runner consumes.
  #
  # The manifest binds one selection to one commit. It records the tested
  # commit, the selector identities that produced the selection, the content
  # checksum of every selected file, and the shard that runs each file.
  #
  # Validation recomputes the selection from the committed tree. A manifest
  # that disagrees with the repository is rejected.
  #
  # A checksum proves that bytes match. It does not prove who supplied them.
  # A valid manifest is not permission to skip a test.
  class SystemManifest
    class Invalid < StandardError; end

    VERSION = 1
    MANIFEST_KEYS = %w[ version commit selection files assignments checksum ].freeze
    SELECTION_KEYS = %w[ mode reasons comparison base_sha requested_base_sha source_sha
      ownership_digest base_ownership_digest rules_digest engine_version policy_digest system_files ].freeze

    # JSON otherwise silently replaces conflicting keys with the last value.
    class UniqueObject < Hash
      def []=(key, value)
        raise Invalid, "duplicate JSON key: #{key}" if key?(key)

        super
      end
    end

    attr_reader :root, :manifest

    def initialize(root:, policy:, manifest: nil)
      @policy = policy
      @root = File.expand_path(root)
      @manifest = manifest
    end

    # Builds a manifest from a selector report and the commit it describes.
    def self.build(root:, selection:, commit:, shards:, policy:)
      new(root:, policy:).build(selection:, commit:, shards:)
    end

    # Reads a manifest from a JSON file and validates it.
    def self.from_file(root:, path:, expected_commit:, policy:)
      manifest = parse_json(File.binread(path))
      new(root:, manifest:, policy:).validate(expected_commit:)
    end

    # Parses JSON and rejects duplicate keys. JSON otherwise keeps the last
    # value and hides a conflicting document.
    def self.parse_json(content)
      JSON.parse(content, object_class: UniqueObject)
    rescue JSON::ParserError => error
      raise Invalid, "invalid JSON: #{error.message}"
    end

    def build(selection:, commit:, shards:)
      check!(shards.is_a?(Integer) && shards.positive?, "shard total must be a positive integer")
      check!(commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/), "commit must be a full commit sha")
      check!(selection.is_a?(Hash), "selection must be an object")
      check!(selection["source_sha"] == commit, "selection does not describe commit #{commit}")

      files = selected_files(selection)
      check!(files.any?, "the manifest must contain at least one system test")

      body = {
        "version" => VERSION,
        "commit" => commit,
        "selection" => selection.slice(*SELECTION_KEYS),
        "files" => files.to_h { |path| [ path, checksum(path, commit) ] },
        "assignments" => { "total" => shards, "shards" => assign(files, shards) }
      }
      manifest = body.merge("checksum" => body_checksum(body))

      # The manifest is only usable when it verifies against the tree it
      # names. A selector report that omits an identity, drops a selected
      # file, or names a non-system file must not produce a manifest.
      self.class.new(root:, manifest:, policy: @policy).validate(expected_commit: commit)
    end

    # Verifies the manifest against the committed tree and the commit the
    # caller is about to run. Returns the verified manifest.
    def validate(expected_commit:)
      check!(@manifest.is_a?(Hash), "manifest must be an object")
      verify_keys(@manifest, MANIFEST_KEYS, "manifest")
      check!(@manifest["version"] == VERSION, "manifest version must be #{VERSION}")

      commit = @manifest["commit"]
      check!(commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/), "commit must be a full commit sha")
      check!(expected_commit.is_a?(String) && expected_commit.match?(/\A[0-9a-f]{40}\z/),
        "expected commit must be a full commit sha")
      check!(commit == expected_commit, "manifest commit #{commit} does not match the expected commit #{expected_commit}")

      selection = @manifest["selection"]
      check!(selection.is_a?(Hash), "selection must be an object")
      verify_keys(selection, SELECTION_KEYS, "selection")
      verify_selection_types(selection)
      check!(selection["source_sha"] == commit, "selection does not describe the tested commit")

      files = @manifest["files"]
      check!(files.is_a?(Hash) && files.any?, "the manifest must contain at least one system test")
      files.each { |path, digest| verify_file(path, digest, commit) }

      verify_selection(selection, commit)
      verify_file_list(files, selection)
      verify_assignments(files.keys)

      check!(@manifest["checksum"] == body_checksum(@manifest.slice(*MANIFEST_KEYS - [ "checksum" ])),
        "manifest checksum does not match its content")
      @manifest
    end

    # Returns the files each shard runs, in shard order.
    def assignments
      @manifest.dig("assignments", "shards")
    end

    private
      def check!(condition, message)
        raise Invalid, message unless condition
      end

      def verify_keys(value, required, label)
        missing = required - value.keys
        unknown = value.keys - required
        check!(missing.empty?, "#{label}: missing required keys #{missing.inspect}")
        check!(unknown.empty?, "#{label}: unknown keys #{unknown.inspect}")
      end

      # Returns a sorted list of strings. A list with any other type is
      # rejected before it reaches a comparison that would raise.
      def string_list!(value, label)
        check!(value.is_a?(Array), "#{label} must be a list")
        value.each do |item|
          check!(item.is_a?(String), "#{label} must contain only strings")
        end
        value
      end

      # The selector identities must have their expected types before the
      # manifest compares them. A value of the wrong type would otherwise
      # fail later with an unrelated message.
      def verify_selection_types(selection)
        check!(%w[ pr push ].include?(selection["comparison"]), "comparison must be pr or push")
        %w[ mode comparison source_sha base_sha requested_base_sha
          ownership_digest base_ownership_digest rules_digest engine_version policy_digest ].each do |key|
          check!(selection[key].is_a?(String), "selection #{key} must be a string")
        end
        check!(selection["reasons"].is_a?(Array), "selection reasons must be a list")
      end

      def selected_files(selection)
        files = string_list!(selection["system_files"], "selection system_files")
        files.uniq.sort
      end

      # Round-robin over the sorted selection. This matches the existing shard
      # runner, so a manifest and the runner agree on the split.
      def assign(files, shards)
        Array.new(shards) { |shard| files.each_with_index.filter_map { |path, index| path if index % shards == shard } }
      end

      def checksum(path, commit)
        Digest::SHA256.hexdigest(git("show", "#{commit}:#{path}"))
      end

      def verify_file(path, digest, commit)
        check!(path.is_a?(String) && !path.empty?, "each file path must be a nonempty string")
        check!(!path.match?(/[[:cntrl:]]/), "file path contains control characters")
        pathname = Pathname.new(path)
        check!(!pathname.absolute? && !path.split("/").include?("..") && pathname.cleanpath.to_s == path,
          "file path #{path.inspect} is not a canonical relative path")
        check!(@policy.test?(path) && @policy.system?(path),
          "file path #{path.inspect} must name a system test")
        check!(digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/),
          "file checksum for #{path.inspect} must be a sha256 digest")
        check!(regular_file?(commit, path), "file path #{path.inspect} must be a regular file in the tested commit")
        check!(digest == checksum(path, commit), "file checksum for #{path.inspect} does not match the committed content")
      end

      def regular_file?(commit, path)
        entry = git("ls-tree", commit, "--", path)
        metadata = entry.split("\t", 2).first.to_s.split(" ")
        metadata[1] == "blob" && %w[ 100644 100755 ].include?(metadata[0])
      end

      # Recomputes the selection from the committed tree and compares it with
      # the selection recorded in the manifest.
      def verify_selection(selection, commit)
        recomputed = recompute_selection(selection, commit)
        SELECTION_KEYS.each do |key|
          next if key == "system_files"

          check!(selection[key] == recomputed[key], "selection #{key} differs from the recomputed selection")
        end
        check!(selection["system_files"] == recomputed["system_files"],
          "selection system_files differ from the recomputed selection")
      end

      def recompute_selection(selection, commit)
        TestOwnership::Selector.new(policy: @policy, root: @root, base: selection["requested_base_sha"],
          head: commit, comparison: selection["comparison"]).call
      rescue TestOwnership::Selector::Unavailable => error
        raise Invalid, "the selection could not be recomputed: #{error.message}"
      end

      # The manifest must list exactly the files the selection chose.
      def verify_file_list(files, selection)
        listed = files.keys.sort
        selected = string_list!(selection["system_files"], "selection system_files").sort
        missing = selected - listed
        extra = listed - selected
        check!(missing.empty?, "the manifest is missing selected file #{missing.first.inspect}")
        check!(extra.empty?, "the manifest lists file #{extra.first.inspect}, which the selection did not choose")
      end

      def verify_assignments(files)
        assignments = @manifest["assignments"]
        check!(assignments.is_a?(Hash), "assignments must be an object")
        verify_keys(assignments, %w[ shards total ], "assignments")
        total = assignments["total"]
        check!(total.is_a?(Integer) && total.positive?, "shard total must be a positive integer")
        shards = assignments["shards"]
        check!(shards.is_a?(Array) && shards.size == total, "the manifest must name every shard")
        shards.each { |shard| string_list!(shard, "each shard assignment") }

        assigned = shards.flatten
        check!(assigned.uniq == assigned, "each file must be assigned to exactly one shard, and appear exactly once")
        check!(assigned.sort == files.sort, "the shard assignment does not cover the selected files exactly once")
        check!(shards == assign(files.sort, total), "the shard assignment differs from the deterministic assignment")
      end

      def body_checksum(body)
        Digest::SHA256.hexdigest(JSON.generate(canonical(body)))
      end

      # Sorts object keys so that the checksum does not depend on key order.
      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end

      def git(*args)
        output, error, status = Open3.capture3("git", *args, chdir: @root)
        raise Invalid, error.strip unless status.success?

        output
      end
  end
end

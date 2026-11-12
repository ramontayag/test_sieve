# frozen_string_literal: true

require "digest"
require "open3"
require_relative "ownership_validator"

module TestSieve
  class Selector
    class Unavailable < StandardError; end

    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    def self.rules_digest
      TestSieve.engine_digest
    end

    def initialize(root:, base:, head:, comparison:, policy:)
      @policy = policy
      @root, @base, @head, @comparison = root, base, head, comparison
      @reasons = []
      @affected = []
    end

    def call
      @head_sha = resolve(@head)
      @head_files = files_at(@head_sha)
      @tests = @head_files.select { |path| @policy.test?(path) }.sort
      raise Unavailable, "tested commit contains no test files" if @tests.empty?
      head_policy, head_digest = policy_at(@head_sha, @head_files, "head")
      base_policy, base_digest = load_base_policy
      changed = changed_paths
      @reasons << "ownership_changed" if head_digest != base_digest
      inspect_paths(changed, [ base_policy, head_policy ].compact)
      @reasons << "empty_diff" if changed.empty?
      selected = selected_tests(head_policy)
      @reasons << "empty_selection" if selected.empty?
      report(changed, selected, head_digest, base_digest)
    end

    private
      def git(*args)
        output, error, status = Open3.capture3("git", *args, chdir: @root)
        raise Unavailable, error.strip unless status.success?
        output
      end

      def resolve(ref)
        git("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}").strip
      end

      def files_at(sha)
        git("ls-tree", "-rz", "--full-tree", sha).split("\0").filter_map do |entry|
          regular_file(entry)
        end
      end

      def regular_file(entry)
        metadata, path = entry.split("\t", 2)
        mode, type, = metadata.split(" ")
        regular = type == "blob" && %w[ 100644 100755 ].include?(mode)
        if @policy.test?(path)
          raise Unavailable, "unsafe test inventory path #{path.inspect}" unless regular && safe_path?(path)
        end
        path if regular
      end

      def policy_at(sha, files, label)
        raise OwnershipValidator::Invalid, "missing regular manifest" unless files.include?(@policy.manifest_path)
        content = git("show", "#{sha}:#{@policy.manifest_path}")
        digest = Digest::SHA256.hexdigest(content)
        [ OwnershipValidator.new(content:, files:, policy: @policy).call, digest ]
      rescue OwnershipValidator::Invalid, Unavailable
        @reasons << "#{label}_policy_invalid"
        [ nil, digest ]
      end

      def load_base_policy
        @requested_base_sha = resolve(@base)
        @base_sha = if @comparison == "pr"
          git("merge-base", @requested_base_sha, @head_sha).strip
        else
          @requested_base_sha
        end
        policy_at(@base_sha, files_at(@base_sha), "base")
      rescue Unavailable
        @reasons << "base_unavailable"
        [ nil, nil ]
      end

      def changed_paths
        return [] unless @base_sha

        # Disabling rename detection exposes both endpoints as deletion/addition.
        git("diff", "--name-only", "--no-renames", "--no-ext-diff", "--no-textconv", "-z", @base_sha, @head_sha, "--").split("\0").uniq.sort
      rescue Unavailable
        @reasons << "diff_unavailable"
        []
      end

      def safe_path?(path)
        !path.match?(/[[:cntrl:]]/) && !Pathname.new(path).absolute? &&
          !path.split("/").include?("..") && Pathname.new(path).cleanpath.to_s == path
      end

      def inspect_paths(paths, policies)
        paths.each { |path| inspect_path(path, policies) }
        expand_consumers(policies)
      end

      def inspect_path(path, policies)
        @reasons << "unsafe_path:#{path.inspect}" unless safe_path?(path)
        @reasons << "ownership_rules_changed" if ownership_rule?(path)
        owners = policies.flat_map { |policy| owners_for(path, policy) }.uniq
        @reasons << "unknown_path:#{path}" if owners.empty?
        @affected.concat(owners)
      end

      def ownership_rule?(path)
        @policy.rules.any? { |rule| path == rule || (rule.end_with?("/") && path.start_with?(rule)) }
      end

      def owners_for(path, policy)
        policy["broad_changes"].each do |rule|
          if File.fnmatch?(rule["pattern"], path, GLOB_FLAGS)
            @reasons << "broad_path:#{path}:#{rule['reason']}"
          end
        end
        policy["owners"].filter_map do |name, owner|
          name if (owner["sources"] + owner["inputs"] + owner["tests"].values.flatten).include?(path)
        end
      end

      def expand_consumers(policies)
        @affected.uniq!
        loop do
          consumers = policies.flat_map { |policy| consumer_names(policy) }
          added = consumers.uniq - @affected
          break if added.empty?
          @affected.concat(added)
        end
      end

      def consumer_names(policy)
        policy["owners"].filter_map do |name, owner|
          name unless (owner.fetch("depends_on", []) & @affected).empty?
        end
      end

      def selected_tests(policy)
        return [] unless policy

        @affected.flat_map do |name|
          policy["owners"].fetch(name, {}).fetch("tests", {}).values.flatten
        end.uniq.sort & @tests
      end

      def report(changed, selected, head_digest, base_digest)
        full = @reasons.any?
        system, unit = (full ? @tests : selected).partition { |path| @policy.system?(path) }
        {
          "mode" => full ? "full" : "selected", "reasons" => @reasons.uniq.sort,
          "comparison" => @comparison, "requested_base" => @base, "requested_head" => @head,
          "requested_base_sha" => @requested_base_sha, "base_sha" => @base_sha, "source_sha" => @head_sha,
          "ownership_digest" => head_digest, "base_ownership_digest" => base_digest,
          "rules_digest" => self.class.rules_digest,
          "engine_version" => TestSieve::VERSION, "policy_digest" => @policy.digest,
          "changed_paths" => changed, "affected_owners" => @affected.sort,
          "unit_files" => unit, "system_files" => system
        }
      end
  end
end

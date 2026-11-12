# frozen_string_literal: true

require "pathname"
require "yaml"
require "set"

module TestSieve
  class OwnershipValidator
    class Invalid < StandardError; end

    def initialize(policy:, root: nil, manifest_path: nil, content: nil, files: nil)
      @policy = policy
      @root = File.realpath(root) if root
      @manifest_path = manifest_path
      @content = content
      @files = files&.to_set
    end

    def call
      manifest = load_manifest
      mapping!(manifest, %w[ version default broad_changes owners ], "manifest")
      check!(manifest["version"] == 1, "version must be 1")
      check!(manifest["default"] == "full_suite", "default must be full_suite")
      validate_broad_changes(manifest["broad_changes"])
      validate_owners(manifest["owners"])
      manifest.merge("tests" => inventory(manifest["owners"]))
    rescue Psych::Exception, SystemCallError => error
      raise Invalid, error.message
    end

    private
      def check!(condition, message)
        raise Invalid, message unless condition
      end

      def load_manifest
        content = @content || File.read(@manifest_path)
        stream = Psych.parse_stream(content)
        check!(stream.children.size == 1, "manifest must contain a single YAML document")
        check_yaml_keys!(stream)
        YAML.safe_load(content, aliases: false)
      end

      # Inspect before loading: YAML otherwise silently replaces duplicate keys.
      def check_yaml_keys!(node)
        if node.is_a?(Psych::Nodes::Mapping)
          keys = node.children.each_slice(2).map(&:first)
          check!(keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) }, "YAML keys must be scalar values")
          names = keys.map(&:value)
          check!(names.uniq == names, "duplicate YAML key")
        end
        (node.children || []).each { |child| check_yaml_keys!(child) }
      end

      def mapping!(value, required, label, optional: [])
        check!(value.is_a?(Hash), "#{label} must be a mapping")
        missing = required - value.keys
        unknown = value.keys - required - optional
        check!(missing.empty?, "#{label}: missing required keys #{missing.inspect}")
        check!(unknown.empty?, "#{label}: unknown keys #{unknown.inspect}")
      end

      def list!(value, label, empty: false)
        check!(value.is_a?(Array), "#{label} must be a list")
        check!(empty || !value.empty?, "#{label} must not be empty")
        check!(value.uniq == value, "#{label} contains repeated entries")
      end

      def text!(value, label)
        check!(value.is_a?(String) && !value.strip.empty?, "#{label} must be a nonempty string")
      end

      def validate_broad_changes(rules)
        list!(rules, "broad_changes", empty: true)
        rules.each_with_index do |rule, index|
          label = "broad_changes[#{index}]"
          mapping!(rule, %w[ pattern reason ], label)
          text!(rule["reason"], "#{label}.reason")
          pattern = rule["pattern"]
          relative_path!(pattern, "#{label}.pattern")
          matches = matching_files(pattern).any?
          check!(matches, "#{label}: pattern #{pattern.inspect} matches no file")
        end
      end

      def validate_owners(owners)
        check!(owners.is_a?(Hash), "owners must be a mapping")
        owners.each do |name, owner|
          text!(name, "owner name")
          check!(name != "full_suite", "owner name full_suite is reserved")
          label = "owners.#{name}"
          mapping!(owner, %w[ sources inputs tests notes ], label, optional: %w[ depends_on ])
          text!(owner["notes"], "#{label}.notes")
          paths!(owner["sources"], "#{label}.sources")
          paths!(owner["inputs"], "#{label}.inputs", empty: true)
          check!((owner["sources"] & owner["inputs"]).empty?, "#{label}: sources and inputs overlap")
          validate_tests(owner["tests"], "#{label}.tests")
          validate_dependencies(owner.fetch("depends_on", []), owners, label)
        end
      end

      def validate_dependencies(dependencies, owners, label)
        list!(dependencies, "#{label}.depends_on", empty: true)
        dependencies.each do |name|
          text!(name, "#{label}.depends_on")
          check!(owners.key?(name), "#{label}.depends_on: unknown owner #{name.inspect}")
        end
      end

      def matching_files(pattern)
        if @files
          @files.select { |path| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        else
          Dir.glob(pattern, base: @root).select { |path| File.file?(File.join(@root, path)) }
        end
      end

      def paths!(paths, label, empty: false)
        list!(paths, label, empty:)
        paths.each do |path|
          relative_path!(path, label)
          check!(!path.match?(/[*?\[\]{}]/), "#{label}: #{path.inspect} must be an exact path")
          file!(path, label)
        end
      end

      def file!(path, label)
        if @files
          check!(@files.include?(path), "#{label}: #{path.inspect} does not exist as a file")
        else
          absolute = File.join(@root, path)
          check!(File.file?(absolute), "#{label}: #{path.inspect} does not exist as a file")
          check!(File.realpath(absolute).start_with?("#{@root}/"), "#{label}: #{path.inspect} leaves the repository")
        end
      end

      def relative_path!(path, label)
        text!(path, label)
        check!(!path.match?(/[[:cntrl:]]/), "#{label}: invalid path")
        pathname = Pathname.new(path)
        check!(!pathname.absolute?, "#{label}: #{path.inspect} must be relative")
        check!(!path.split("/").include?(".."), "#{label}: #{path.inspect} contains parent traversal")
        check!(pathname.cleanpath.to_s == path, "#{label}: #{path.inspect} must be canonical")
      end

      def validate_tests(tests, label)
        mapping!(tests, @policy.required_roles, label, optional: @policy.optional_roles)
        tests.each do |role, files|
          paths!(files, "#{label}.#{role}")
          files.each do |path|
            check!(@policy.test?(path), "#{label}: #{path.inspect} must name a #{@policy.test_pattern} file")
            system_test = @policy.system?(path)
            check!(system_test == (@policy.role_suites.fetch(role) == "system"), "#{label}.#{role}: #{path.inspect} has the wrong test role")
          end
        end
      end

      def inventory(owners)
        owned = Hash.new { |hash, path| hash[path] = [] }
        owners.each do |name, owner|
          owner["tests"].values.flatten.uniq.each { |path| owned[path] << name }
        end
        matching_files(@policy.test_pattern).sort.map do |path|
          [ path, owned.fetch(path, [ "full_suite" ]).sort ]
        end.to_h
      end
  end
end

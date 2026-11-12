# frozen_string_literal: true

require "optparse"
require "test_sieve/rails"

module TestSieve
  class CLI
    def initialize(policy: nil, root: Dir.pwd, out: $stdout, err: $stderr, command: nil)
      @policy, @root, @out, @err, @command = policy, root, out, err, command
    end

    def call(argv)
      args = argv.dup
      options = { root: @root, head: "HEAD", comparison: "pr", suite: "all" }
      parser = option_parser(options)
      parser.parse!(args)
      if options[:help]
        @out.puts parser
        return 0
      end
      action = args.shift
      raise OptionParser::InvalidArgument, "expected select, check, or run" unless %w[select check run].include?(action)
      raise OptionParser::InvalidArgument, args.join(" ") unless args.empty?
      validate_options!(action, options)
      root = File.realpath(options[:root])
      policy = load_policy(options, root)
      if action == "check"
        manifest_path = File.expand_path(options.fetch(:manifest, policy.manifest_path), root)
        result = OwnershipValidator.new(root:, manifest_path:, policy:).call
        inventory = result.fetch("tests")
        raise ArgumentError, "repository contains no test files" if inventory.empty?
        if options[:json]
          @out.puts JSON.pretty_generate(result)
        else
          default_count = inventory.count { |_, owners| owners.include?("full_suite") }
          @out.puts "Ownership valid: #{inventory.size} test files (#{default_count} full_suite default)"
        end
        return 0
      end
      verify_refs!(root, options)
      selection = Selector.new(root:, policy:, **options.slice(:base, :head, :comparison)).call
      return output_selection(selection, options, root) if action == "select"

      verify_checkout!(root, selection)
      @err.puts "test-sieve: #{selection.fetch('mode')} (#{selection.fetch('reasons').join(', ')}); " \
        "#{selection.fetch('unit_files').size} unit, #{selection.fetch('system_files').size} system files"
      run_options = { selection:, root:, suite: options[:suite] }
      run_options[:command] = @command if @command
      Rails.run(**run_options)
    rescue OptionParser::ParseError, Selector::Unavailable, OwnershipValidator::Invalid,
        ArgumentError, SystemCallError, SyntaxError => error
      @err.puts "test-sieve: #{error.message}"
      1
    end

    private

    def option_parser(options)
      OptionParser.new do |parser|
        parser.banner = "Usage: test-sieve select|check|run [options]\nSelect/run require --base REF. Config files execute trusted Ruby and must return TestSieve::Policy.\nNo config file is loaded automatically."
        parser.on("--base REF") { |value| options[:base] = value }
        parser.on("--head REF") { |value| options[:head] = value }
        parser.on("--comparison MODE", %w[pr push]) { |value| options[:comparison] = value }
        parser.on("--root DIR") { |value| options[:root] = value }
        parser.on("--config FILE", "Execute a trusted Ruby policy file") { |value| options[:config] = value }
        parser.on("--manifest FILE") { |value| options[:manifest] = value }
        parser.on("--json", "check only; print the complete validated inventory") { options[:json] = true }
        parser.on("--suite SUITE", %w[unit system all], "run only") { |value| options[:suite] = value; options[:suite_given] = true }
        parser.on("--output FILE", "select only; relative to root") { |value| options[:output] = value }
        parser.on("-h", "--help") { options[:help] = true }
      end
    end

    def validate_options!(action, options)
      raise OptionParser::MissingArgument, "--base" if action != "check" && !options[:base]
      raise OptionParser::InvalidArgument, "--suite is for run only" if action != "run" && options[:suite_given]
      raise OptionParser::InvalidArgument, "--output is for select only" if action != "select" && options[:output]
      raise OptionParser::InvalidArgument, "--json is for check only" if action != "check" && options[:json]
      raise ArgumentError, "--config cannot replace the supplied policy" if @policy && options[:config]
      if action != "check" && options[:manifest] && (@policy || options[:config])
        raise ArgumentError, "--manifest cannot replace a configured policy; change manifest_path in the policy instead"
      end
    end

    def load_policy(options, root)
      return @policy if @policy
      return Rails.policy(manifest_path: options.fetch(:manifest, "test_ownership.yml")) unless options[:config]

      filename = File.expand_path(options[:config], root)
      policy = eval(File.read(filename), TOPLEVEL_BINDING, filename)
      raise ArgumentError, "config must return TestSieve::Policy" unless policy.is_a?(Policy)
      policy
    end

    def verify_refs!(root, options)
      %i[base head].each do |key|
        ref = options.fetch(key)
        raise ArgumentError, "unsafe #{key} ref" if ref.empty? || ref.start_with?("-") || ref.match?(/[[:cntrl:]]/)
        _, error, status = Open3.capture3("git", "rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}", chdir: root)
        raise Selector::Unavailable, "#{key} ref unavailable: #{error.strip}" unless status.success?
      end
    end

    def output_selection(selection, options, root)
      json = JSON.pretty_generate(selection) + "\n"
      options[:output] ? File.write(File.expand_path(options[:output], root), json) : @out.write(json)
      0
    end

    def verify_checkout!(root, selection)
      head, error, status = Open3.capture3("git", "rev-parse", "--verify", "HEAD", chdir: root)
      raise Selector::Unavailable, error.strip unless status.success?
      unless head.strip == selection.fetch("source_sha")
        raise ArgumentError, "selected --head is not the current checkout; check out the selected commit before running tests"
      end
      changes, error, status = Open3.capture3("git", "status", "--porcelain", "-z", "--untracked-files=all", chdir: root)
      raise Selector::Unavailable, error.strip unless status.success?
      unless changes.empty?
        raise ArgumentError, "commit changes and remove or commit untracked files before running selected tests"
      end
    end
  end
end

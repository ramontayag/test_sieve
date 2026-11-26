# frozen_string_literal: true

module TestSieve
  # A loaded feature proves loading, not execution. Accept this evidence only
  # for a file that solely delegates discovery to one inventoried test source.
  class DiscoveryEntry
    REQUIRE = %r{\Arequire_relative[ \t]+(['"])((?:\.\./)*(?:[\w-]+/)*[\w-]+(?:\.rb)?)\1\z}

    def initialize(root:, commit:, inventory:, policy:, suite:)
      @root, @commit, @inventory, @policy, @suite = root, commit, inventory, policy, suite
    end

    def target(entry)
      unless @inventory.include?(entry) && @policy.suite_for(entry) == @suite
        raise Invalid, "unknown or wrong-suite discovery entry: #{entry.inspect}"
      end
      blob, status = Open3.capture2("git", "show", "#{@commit}:#{entry}", chdir: @root)
      raise Invalid, "cannot read discovery entry: #{entry}" unless status.success?
      raise Invalid, "unsupported discovery entry: #{entry}" if blob.include?("\0") || !blob.valid_encoding?
      code = blob.lines.map { |line| line.chomp.gsub(/\A[ \t]+|[ \t]+\z/, "") }.reject { |line| line.empty? || line.start_with?("#") }
      match = REQUIRE.match(code.first.to_s) if code.size == 1
      raise Invalid, "unsupported discovery entry: #{entry}" unless match
      relative = match[2].delete_suffix(".rb") + ".rb"
      target = Pathname.new(entry).dirname.join(relative).cleanpath.to_s
      unless target != entry && @inventory.include?(target) && @policy.suite_for(target) == @suite
        raise Invalid, "unknown or wrong-suite discovery target: #{target}"
      end
      target
    end
  end
end

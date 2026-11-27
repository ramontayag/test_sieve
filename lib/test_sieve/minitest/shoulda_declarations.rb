# frozen_string_literal: true

module TestSieve
  module Minitest
    module ShouldaDeclarations
      def self.install
        return unless defined?(::Shoulda::Context::Context) && Gem.loaded_specs["shoulda-context"]&.version.to_s == "2.0.0"

        context = ::Shoulda::Context::Context
        context.prepend(Hooks) unless context < Hooks
      end

      # Shoulda 2.0 builds nested contexts later. Follow the actual should hash
      # through that build, then use the symbol returned by its define_method.
      module Hooks
        def should(*args, &block)
          previous_size = shoulds.size
          result = super
          if !block && shoulds.size == previous_size + 1
            gem_dir = Gem.loaded_specs.fetch("shoulda-context").full_gem_path + "/"
            caller_frame = caller_locations.find { |frame| !frame.absolute_path.to_s.start_with?(gem_dir) }
            if caller_frame&.absolute_path
              (@test_sieve_declarations ||= {}.compare_by_identity)[shoulds.last] =
                [caller_frame.absolute_path, caller_frame.lineno]
            end
          end
          result
        end

        def create_test_from_should_hash(should)
          name = super
          location = @test_sieve_declarations&.delete(should)
          if location && name.is_a?(Symbol)
            ShouldaDeclarations.record(test_unit_class, name, location)
          end
          name
        end
      end
      private_constant :Hooks

      def self.record(klass, name, location)
        key = [klass.name, name.to_s]
        @declarations ||= {}
        @declarations[key] = @declarations.key?(key) ? nil : [klass.instance_method(name), location]
      end

      def self.for(result)
        method, location = @declarations&.fetch([result.klass, result.name], nil)
        return unless method && method.source_location == result.source_location
        return unless Object.const_get(result.klass).instance_method(result.name) == method

        location
      rescue NameError
        nil
      end
    end
  end
end

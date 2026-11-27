# frozen_string_literal: true

require_relative "shoulda_declarations"

module TestSieve
  module Minitest
    module ResultLocation
      private

      def result_location(result)
        source, source_line = result.source_location
        declaration = ShouldaDeclarations.for(result)
        return {"file" => relative_path(source), "line" => source_line} unless declaration

        file, line = declaration
        {"file" => relative_path(file), "line" => line,
          "source_file" => relative_path(source), "source_line" => source_line}
      end
    end
  end
end

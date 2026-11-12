# frozen_string_literal: true

module TestSelection
  class Summary
    def initialize(report)
      @report = report
    end

    def to_markdown
      lines = [ "## Test selection comparison", "", "Status: **#{@report.fetch('status', 'inconclusive')}**", "" ]
      selection = @report["selection"]
      if selection
        lines << "- Comparison: `#{selection['comparison']}`"
        lines << "- Base commit: `#{selection['base_sha']}`"
        lines << "- Tested commit: `#{selection['source_sha']}`"
        lines << ""
      end
      lines << "This report is evidence only. It does not approve selective test execution." << ""
      lines.concat(reasons)
      lines << ""
      lines.concat(suite_rows)
      lines.join("\n")
    end

    private
      def reasons
        Array(@report["reasons"]).map { |reason| "- Reason: #{reason}" }
      end

      def suite_rows
        results = @report.fetch("results", {})
        return [] if results.empty?

        [ "| Suite | Group | Results | Failures/errors |", "| --- | --- | ---: | ---: |" ] +
          results.flat_map do |suite, groups|
            groups.map do |group, records|
              failures = records.count { |record| %w[ fail error ].include?(record["outcome"]) }
              "| #{suite} | #{group} | #{records.size} | #{failures} |"
            end
          end
      end
  end
end

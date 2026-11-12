# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require_relative "../support/project"

class CheckTestOwnershipTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "test/support/bin/check-test-ownership")
  SOURCE = "app/services/fragment.rb"
  INPUT = "test/fixtures/source.txt"
  UNIT = "test/services/fragment_test.rb"
  LEARNER = "test/system/fragment_test.rb"

  def setup
    @root = Dir.mktmpdir("test-ownership")
    [ SOURCE, INPUT, UNIT, LEARNER ].each { |path| write(path) }
    @manifest = {
      "version" => 1, "default" => "full_suite",
      "broad_changes" => [ { "pattern" => "test/fixtures/**/*", "reason" => "Shared inputs" } ],
      "owners" => { "fragment" => {
        "sources" => [ SOURCE ], "inputs" => [ INPUT ], "notes" => "Fragment consumers",
        "tests" => { "unit" => [ UNIT ], "learner" => [ LEARNER ] }
      } }
    }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_inventory_includes_shared_owners_and_unclassified_new_files
    @manifest["owners"]["other"] = Marshal.load(Marshal.dump(owner))
    write("test/services/new_test.rb")
    write("app/services/new.rb")
    result = validate

    assert_equal({
      UNIT => %w[ fragment other ], "test/services/new_test.rb" => [ "full_suite" ],
      LEARNER => %w[ fragment other ]
    }, result.fetch("tests"))
    assert_equal result["tests"].keys.sort, result["tests"].keys
    assert_equal [ SOURCE ], result["owners"]["fragment"]["sources"]
    assert_equal "full_suite", result["default"]
  end

  def test_broad_rules_remain_visible_when_they_overlap_owned_sources_and_tests
    [ SOURCE, UNIT, "test/**/*" ].each do |pattern|
      @manifest["broad_changes"] << { "pattern" => pattern, "reason" => "Broad coverage takes precedence" }
    end
    owner["tests"]["admin"] = [ LEARNER ]
    owner["tests"]["review"] = [ LEARNER ]
    result = validate

    assert_equal @manifest["broad_changes"], result["broad_changes"]
    assert_equal [ "fragment" ], result["tests"][LEARNER]
    assert_equal [ LEARNER ], result["owners"]["fragment"]["tests"]["review"]
  end

  def test_explicitly_empty_ownership_keeps_every_test_on_the_default
    @manifest["owners"] = {}
    @manifest["broad_changes"] = []
    assert_equal({ UNIT => [ "full_suite" ], LEARNER => [ "full_suite" ] }, validate["tests"])
  end

  def test_committed_inventory_does_not_consult_local_files
    owner["depends_on"] = [ "fragment" ]
    files = [ SOURCE, INPUT, UNIT, LEARNER, "test/committed_test.rb" ]
    File.delete(File.join(@root, SOURCE))
    write("test/local_test.rb")
    result = TestSieve::OwnershipValidator.new(policy: FixtureProject::POLICY, content: YAML.dump(@manifest), files:).call
    assert_equal [ "fragment" ], result["owners"]["fragment"]["depends_on"]
    assert_equal [ UNIT, LEARNER, "test/committed_test.rb" ].sort, result["tests"].keys
  end

  def test_committed_inventory_rejects_a_reference_only_present_locally
    error = assert_raises(TestSieve::OwnershipValidator::Invalid) do
      TestSieve::OwnershipValidator.new(policy: FixtureProject::POLICY, content: YAML.dump(@manifest), files: [ INPUT, UNIT, LEARNER ]).call
    end
    assert_includes error.message, "does not exist"
  end

  def test_dependency_references_must_name_existing_owners
    owner["depends_on"] = [ "missing" ]
    assert_invalid("unknown owner")
    owner["depends_on"] = [ "fragment", "fragment" ]
    assert_invalid("repeated entries")
    owner["depends_on"] = "fragment"
    assert_invalid("must be a list")
  end

  {
    "unsupported version" => [ ->(m) { m["version"] = 2 }, "version" ],
    "unsafe default" => [ ->(m) { m["default"] = "narrow" }, "default" ],
    "unknown top-level key" => [ ->(m) { m["typo"] = true }, "unknown keys" ],
    "non-mapping owners" => [ ->(m) { m["owners"] = [] }, "mapping" ],
    "non-list broad rules" => [ ->(m) { m["broad_changes"] = {} }, "list" ],
    "stale broad pattern" => [ ->(m) { m["broad_changes"][0]["pattern"] = "missing/**/*" }, "matches no file" ],
    "unexplained broad rule" => [ ->(m) { m["broad_changes"][0]["reason"] = "" }, "reason" ]
  }.each do |name, (change, message)|
    define_method("test_rejects_#{name.tr(' -', '_')}") do
      change.call(@manifest)
      assert_invalid(message)
    end
  end

  %w[ version default broad_changes owners ].each do |key|
    define_method("test_rejects_missing_#{key}") do
      @manifest.delete(key)
      assert_invalid("missing required keys")
    end
  end

  {
    "empty sources" => [ ->(o) { o["sources"] = [] }, "sources" ],
    "missing inputs" => [ ->(o) { o.delete("inputs") }, "missing required keys" ],
    "missing notes" => [ ->(o) { o["notes"] = nil }, "notes" ],
    "unknown owner field" => [ ->(o) { o["typo"] = true }, "unknown keys" ],
    "no test coverage" => [ ->(o) { o["tests"] = {} }, "missing required keys" ],
    "empty unit coverage" => [ ->(o) { o["tests"]["unit"] = [] }, "empty" ],
    "missing learner coverage" => [ ->(o) { o["tests"].delete("learner") }, "missing required keys" ],
    "unknown role" => [ ->(o) { o["tests"]["typo"] = [ UNIT ] }, "unknown keys" ],
    "browser test as unit" => [ ->(o) { o["tests"]["unit"] = [ LEARNER ] }, "wrong test role" ],
    "unit test as learner" => [ ->(o) { o["tests"]["learner"] = [ UNIT ] }, "wrong test role" ],
    "non-test reference" => [ ->(o) { o["tests"]["unit"] = [ SOURCE ] }, "must name a test" ],
    "duplicate reference" => [ ->(o) { o["sources"] *= 2 }, "repeated entries" ],
    "source and input overlap" => [ ->(o) { o["inputs"] = [ SOURCE ] }, "overlap" ]
  }.each do |name, (change, message)|
    define_method("test_rejects_#{name.tr(' ', '_')}") do
      change.call(owner)
      assert_invalid(message)
    end
  end

  [ "", 42, "full_suite" ].each do |name|
    define_method("test_rejects_owner_name_#{name.inspect}") do
      @manifest["owners"] = { name => owner }
      assert_invalid("owner name")
    end
  end

  [ "../outside.rb", "/outside.rb", "app/services/*", "app/services", "app/./services/fragment.rb",
    "app//services/fragment.rb", "app/services/missing.rb" ].each_with_index do |path, index|
    define_method("test_rejects_invalid_source_reference_#{index}") do
      owner["sources"] = [ path ]
      assert_invalid("sources")
    end
  end

  def test_noncanonical_test_cannot_satisfy_unit_coverage
    owner["tests"]["unit"] = [ "test/./system/fragment_test.rb" ]
    assert_invalid("canonical")
  end

  def test_deleted_source_and_renamed_test_require_manifest_updates
    File.delete(File.join(@root, SOURCE))
    assert_invalid("does not exist")
    write(SOURCE)
    File.rename(File.join(@root, UNIT), File.join(@root, "test/services/renamed_test.rb"))
    assert_invalid("does not exist")
    owner["tests"]["unit"] = [ "test/services/renamed_test.rb" ]
    assert_equal [ "fragment" ], validate["tests"]["test/services/renamed_test.rb"]
  end

  def test_deleted_input_is_not_silently_dropped
    @manifest["broad_changes"] = []
    File.delete(File.join(@root, INPUT))
    assert_invalid("inputs")
  end

  [ "", "null", "scalar", "- item", "version: [", "---\nversion: 1\n---\nversion: 2" ].each_with_index do |yaml, index|
    define_method("test_rejects_invalid_yaml_document_#{index}") do
      assert_raises(TestSieve::OwnershipValidator::Invalid) { validate(yaml:) }
    end
  end

  [ "version: 1", "  fragment:", "    sources:", "      unit:" ].each_with_index do |line, index|
    define_method("test_rejects_duplicate_yaml_key_at_depth_#{index}") do
      yaml = YAML.dump(@manifest)
      assert_includes yaml, line
      # The invalid first value must not be hidden by a later valid value.
      yaml = yaml.sub(line, "#{line.split(':').first}: null\n#{line}")
      error = assert_raises(TestSieve::OwnershipValidator::Invalid) { validate(yaml:) }
      assert_includes error.message, "duplicate"
    end
  end

  def test_cli_accepts_an_alternate_manifest_and_reports_json
    write("config/alternate.yml", YAML.dump(@manifest))
    stdout, stderr, status = cli("--root", @root, "--manifest", "config/alternate.yml", "--json")
    assert status.success?, stderr
    assert_equal({ UNIT => [ "fragment" ], LEARNER => [ "fragment" ] }, JSON.parse(stdout)["tests"])
  end

  def test_cli_fails_visibly_without_a_manifest_or_with_invalid_arguments
    [ [ "--root", @root ], [ "--unknown" ], [ "unexpected" ] ].each do |args|
      stdout, stderr, status = cli(*args)
      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "bin/check-test-ownership:"
    end
  end

  private
    def owner
      @manifest["owners"].fetch("fragment")
    end

    def write(path, content = "")
      absolute = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
      absolute
    end

    def validate(yaml: YAML.dump(@manifest))
      path = write("config/test_ownership.yml", yaml)
      TestSieve::OwnershipValidator.new(policy: FixtureProject::POLICY, root: @root, manifest_path: path).call
    end

    def assert_invalid(message)
      error = assert_raises(TestSieve::OwnershipValidator::Invalid) { validate }
      assert_includes error.message, message
    end

    def cli(*args)
      Open3.capture3(BIN, *args, chdir: ROOT)
    end
end

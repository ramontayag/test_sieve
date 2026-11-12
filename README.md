# Test Sieve

Run the tests affected by a code change. Run the full suite when the change
cannot be safely narrowed down.

Test Sieve is a Ruby library for adding selective test runs to your own tooling.
You describe which tests cover each part of your app. Test Sieve compares Git
commits and returns the files to run, including tests for dependent features.
Your existing test runner executes them.

For example, a change to shipping-price calculation might need its unit tests
and the checkout browser tests, but not every browser test in your app. A change
to an unmapped file runs the full suite instead.

## How does it know which tests to run?

Git can tell you which files changed. It cannot tell you which tests cover those
files. Your **map** supplies that connection.

Suppose `lib/shipping.rb` calculates shipping prices. A unit test checks the
calculation, and a checkout browser test checks the price customers see. Map
both tests to the shipping code. When that code changes, Test Sieve selects both
test files; your existing runner executes them.

The process has three steps:

1. **Map code to tests.** List the source files, shared inputs, and tests for each
   feature in a versioned YAML file. Declare dependencies between features when
   a change to one needs tests from another.
2. **Identify affected tests.** Test Sieve compares two commits to find changed
   files, then uses the map to select their tests. It also includes tests for
   features that depend on the changed code.
3. **Run those tests.** Pass the returned file paths to your test runner. If Test
   Sieve cannot safely narrow the change, it returns the full test inventory
   instead, with reasons explaining why.

The map is your statement of coverage, not coverage that Test Sieve discovers.
It does not infer dependencies from AI, static analysis, or previous test runs.
If you leave a real dependency out of an otherwise valid map, it can miss tests.
Review the map as carefully as the code it describes.

## Is it a fit for my app?

Use Test Sieve when your suite is slow, you can identify meaningful boundaries
between features, and you control the scripts that run your tests.

The gem provides the selection and verification logic. It does **not** include a
ready-made CLI, Rails integration, GitHub Action, test runner, or framework
reporter. You write a small adapter for your project. Selection returns file
paths, so you can pass them to the runner you already use.

There is no dependency on Rails or Minitest at runtime. Execution verification
has a specific result format and needs a reporter or adapter that produces it.

## Install

Requires Ruby 3.2+ and Git. The gem is available from GitHub; it is not published
on RubyGems yet.

Add it to your Gemfile:

```ruby
gem "test_sieve", github: "ramontayag/test_sieve", branch: "master"
```

Run `bundle install` and commit `Gemfile.lock` to keep the same revision in local
development and CI. You can also use `ref:` to pin a specific commit.

## Select tests in your app

This example maps shipping code to a unit test and a checkout system test.
Replace these paths with real, tracked files in your repository.

### 1. Map code to tests

First, tell Test Sieve which tests need to run when shipping code changes.
Create `test_ownership.yml`:

```yaml
version: 1
default: full_suite
broad_changes:
  - pattern: Gemfile.lock
    reason: Dependency changes can affect the whole app.
owners:
  shipping:
    sources:
      - lib/shipping.rb
    inputs: []
    tests:
      unit:
        - test/shipping_test.rb
      system:
        - test/system/checkout_test.rb
    notes: Shipping prices are also checked through checkout.
```

Here, `shipping` groups one source file with the two tests that cover it. The
map calls this group an **owner**: a named part of your app, not a person.

- `sources` lists the code the tests cover.
- `inputs` lists other files that affect the feature, such as templates or
  fixtures. This example has none.
- `tests` lists the test files to select when a source or input changes.
- `default: full_suite` means an unmapped change needs the full suite.
- `broad_changes` lists changes that always need the full suite. Updating
  dependencies can affect any feature, so this example includes `Gemfile.lock`.

Source, input, and test entries are exact paths. `broad_changes` accepts glob
patterns; each pattern must match a tracked file.

To include a feature whenever another feature changes, add
`depends_on: [other_owner_name]` to its owner entry. Test Sieve follows those
relationships through all declared consumers.

### 2. Connect the map to your test inventory

The map describes coverage. Test Sieve also needs to know where to find all your
tests, so it can return the full suite when selection is not safe. A **policy**
provides those paths and the rules for reading your map.

Save this adapter as `script/select_tests.rb`. It accepts two Git revisions and
prints the selection as JSON; it does not execute tests.

```ruby
require "test_sieve"

policy = TestSieve::Policy.new(
  manifest_path: "test_ownership.yml",
  test_pattern: "test/**/*_test.rb",
  system_pattern: "test/system/**/*_test.rb",
  required_roles: %w[unit system],
  optional_roles: [],
  role_suites: { "unit" => "unit", "system" => "system" },
  rules: ["test_ownership.yml", "script/select_tests.rb"],
  identity: "my-app-selection-v1"
)

selection = TestSieve::Selector.new(
  root: Dir.pwd,
  base: ARGV.fetch(0),
  head: ARGV.fetch(1),
  comparison: "pr",
  policy: policy
).call

puts JSON.pretty_generate(selection)
```

In this policy, `test_pattern` finds the full inventory, and `system_pattern`
identifies its system tests. `required_roles` requires every owner to declare
both unit and system coverage. The `role_suites` mapping puts those tests into
the result's `unit_files` and `system_files` lists. Your runner decides how to
execute each list.

The `rules` paths identify files that control selection. Changing the map or
adapter must not silently authorize skipping tests under different rules.

### 3. Find the tests affected by your change

Now use the map to answer: “Which tests should run for this change?” Test Sieve
needs a before and an after revision to discover which files changed. It reads
the map at both revisions rather than relying only on your working copy.

Commit the map and script before using them as a comparison base. Make and commit
a change to `lib/shipping.rb`, then run from your repository root:

```sh
bundle exec ruby script/select_tests.rb origin/master HEAD
```

Use your own base branch in place of `origin/master`. Pull-request comparison
uses its merge base with `HEAD`; `comparison: "push"` compares the two commits
directly. The required commits must exist locally. Uncommitted edits are not part
of the comparison.

If shipping is the only changed, mapped feature, the result includes:

```json
{
  "mode": "selected",
  "reasons": [],
  "affected_owners": ["shipping"],
  "unit_files": ["test/shipping_test.rb"],
  "system_files": ["test/system/checkout_test.rb"]
}
```

Read the result as follows:

- `mode: "selected"` means Test Sieve could narrow the run using your map.
- `affected_owners` identifies the features affected by the changed files.
- `unit_files` and `system_files` are the test files your runner should execute.

This is an excerpt; the full result also identifies the compared commits and
selection rules.

### 4. Run the selected test files

Pass `unit_files` and `system_files` to your existing test commands. For the
shipping change above, run `test/shipping_test.rb` with your unit-test command
and `test/system/checkout_test.rb` with your system-test command. Test Sieve
selects whole files, not individual test methods.

If the result is `mode: "full"`, run all the returned files, not just tests for
the feature you expected to change. For example, an edit to an unmapped file
cannot be connected to tests through your map, so Test Sieve returns the full
inventory. The `reasons` field explains that decision.

## Introduce selection without losing coverage

Before using selection to skip tests, inspect its decisions on real changes.
Keep your existing full-suite command unchanged. Run the selection script as an
additional step and save its JSON output:

```sh
bundle exec ruby script/select_tests.rb origin/master HEAD > /tmp/test-sieve-selection.json
cat /tmp/test-sieve-selection.json
```

Use your own base branch in place of `origin/master`. Then run your normal full
suite, regardless of which files the JSON lists. At this stage, you are only
checking the proposed selection, not using it to control the test run.

For the shipping example, check that the output includes both the shipping unit
test and the checkout system test. For changes to shared code, check that the
output includes tests for every feature that depends on it. If an expected test
is missing, correct the map before relying on selection. A passing full suite
does not prove that the proposed selection includes every test you need.

In CI, keep the full-suite job and add a step that runs the selection script.
Print the JSON in the job log or upload it as an artifact so reviewers can inspect
the decision alongside the change. Test Sieve does not publish it for you.

Once you trust the map, change your adapter to pass the returned file lists to
your test commands instead of always running the full suite. Measure the time
saved in your own CI; fewer selected files do not guarantee a faster pipeline.

The selector returns `mode: "full"` for unknown paths, broad changes, changed or
invalid maps, and other conditions that prevent a reliable selection. In that
case, the returned file lists contain the full test inventory. It also explains
the fallback in `reasons`.

If Test Sieve cannot establish a usable inventory, it raises an error. Your CI
adapter must then run its normal full-suite command or fail the job. Never treat
a selection error as an empty successful test run.

## Parallel runs and execution verification

Once selection works, `TestSieve::SystemManifest` can divide the selected
system-test files across a fixed number of jobs. `TestSieve::SystemRunGate`
checks the resulting execution records against that manifest and the expected
commit and run identity. Missing jobs, duplicate execution, and incomplete
results cannot count as a complete run. Jobs assigned no files still need an
explicit record.

This requires your runner to write shard records and normalized test outcomes.
See [execution verification](docs/execution-verification.md) for the API and
record format. The [public API tests](test/public_api_test.rb) contain a complete
four-job example, including empty assignments and rejected evidence.

## Contributing

Bug reports and pull requests are welcome. For selection bugs, include a small
reproduction with the ownership map, changed paths, and expected test files.

To run the library tests and built-gem installation check:

```sh
bundle install
bin/test
```

The tests need no application, database, browser, or Docker.

## Background

Test Sieve was extracted from [Quizzard](https://github.com/ramontayag/quizzard/tree/e8b54f72e63f70646f2cd3a168153e57240c4623/tools/test_selection).
Load the gem with `require "test_sieve"`. Its public API lives under `TestSieve`.

## License

Test Sieve is available under the [MIT License](LICENSE.txt).

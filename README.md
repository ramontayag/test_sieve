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

## How it works

1. **Map code to tests.** Keep a versioned YAML file listing source files, shared
   inputs, and the tests that cover them.
2. **Compare two commits.** Test Sieve reads the changed paths and the mapping at
   both revisions. It includes dependent features when you declare them.
3. **Run the returned files.** The result contains either the affected tests or
   the full inventory, with reasons explaining the decision.
4. **Optionally verify a parallel run.** Assign selected system tests to fixed
   jobs and check that every assigned file produced execution evidence.

Selection is based on your explicit mapping. Test Sieve does not infer coverage
from AI, static analysis, or previous test runs. A mapping can be valid and still
miss a real dependency; reviewing that mapping remains part of using the tool.

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

### 1. Add an ownership map

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

An **owner** is a named part of your app, not a person. Source, input, and test
entries are exact paths. `inputs` can list templates, fixtures, or other files
that affect the feature. `broad_changes` accepts glob patterns that force a full
run; each pattern must match a tracked file.

To include a feature whenever another feature changes, add
`depends_on: [other_owner_name]` to its owner entry. Test Sieve follows those
relationships through all declared consumers.

### 2. Add a selection script

Save this as `script/select_tests.rb`:

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

The policy tells Test Sieve where to find tests and which coverage roles every
owner must declare. The result groups files into `unit` and `system` suites.
Those are format labels; your runner decides how to execute each group.

### 3. Compare committed changes

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

This is an excerpt; the full result also identifies the compared commits and
selection rules. Pass `unit_files` and `system_files` to your existing test
commands. Test Sieve selects whole files, not individual test methods.

## Introduce selection without losing coverage

Start by reporting what Test Sieve **would** select while still running your full
suite. Review the map and check changes that affect shared code before using the
selection to skip tests. Measure the time saved in your own CI; fewer selected
files do not guarantee a faster pipeline.

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

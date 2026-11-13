# Test Sieve

Run the tests affected by a code change. Run the full suite when the change
cannot be safely narrowed down.

Map your code to tests, then use the included commands to select and run them.
The Rails adapter runs your existing test runner. The Minitest adapter records
outcomes and timings without replacing your normal test output.

## Get started

Requires Ruby 3.2+ and Git. This example selects tests for a change to shipping
code. Replace the example paths with real, tracked files in your app.

### 1. Install

Add this to your Gemfile:

```ruby
gem "test_sieve", github: "ramontayag/test_sieve", branch: "master"
```

Run `bundle install`. The gem is available from GitHub, not RubyGems yet.
Commit `Gemfile.lock` to keep the same revision locally and in CI. You can also
use `ref:` to pin a specific commit.

### 2. Copy the map and edit the paths

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
      - lib/shipping.rb # Replace with your source file.
    inputs: []
    tests:
      unit:
        - test/shipping_test.rb # Replace with its unit test.
      system:
        - test/system/checkout_test.rb # Replace with its system test.
    notes: Shipping prices are also checked through checkout.
```

This tells Test Sieve: “When this code changes, run these tests.”

### 3. Check your map

```sh
bundle exec test-sieve check
```

The command checks that the paths exist and every owner declares the required
test roles. It does not run tests. By default, Test Sieve finds tests under
`test/**/*_test.rb` and system tests under `test/system/**/*_test.rb`.
For other layouts, [configure the adapter](#configure-the-adapter).

### 4. Make a change and see which tests it needs

Commit the setup **before** the change you want to test, then save that starting
commit:

```sh
git add Gemfile Gemfile.lock test_ownership.yml
git commit -m "Configure selective test runs"
base=$(git rev-parse HEAD)
```

Edit your mapped source file. Then commit the change and run from your repository
root, in the same shell:

```sh
git add lib/shipping.rb # Replace with the source file you changed.
git commit -m "Update shipping prices"
bundle exec test-sieve select --base "$base"
```

For a change only to `lib/shipping.rb`, the output includes:

```json
{
  "mode": "selected",
  "reasons": [],
  "affected_owners": ["shipping"],
  "unit_files": ["test/shipping_test.rb"],
  "system_files": ["test/system/checkout_test.rb"]
}
```

You have a selection: shipping's unit test and the checkout browser test, not
every test in your app. The full JSON also identifies the compared commits and
selection rules.

For a pull request, use your base branch instead of `$base`:

```sh
# Replace origin/master with your base branch.
bundle exec test-sieve select --base origin/master
```

Both revisions must exist locally. Uncommitted edits are not included.

### 5. Inspect the selection before using it to skip tests

Save and read the result:

```sh
bundle exec test-sieve select --base "$base" --output /tmp/test-sieve-selection.json
cat /tmp/test-sieve-selection.json
```

Keep running your usual full-suite command while you check the proposed
selections on real changes. For this example, do the lists include both shipping
and checkout tests? If an expected test is missing, correct the map.

### 6. Run the affected tests

When you are ready to use selection, run:

```sh
bundle exec test-sieve run --base "$base" --suite unit
bundle exec test-sieve run --base "$base" --suite system
```

The Rails adapter invokes `bin/rails test` with the explicit files for each
suite, including system-test files. If selection requires a full run, it passes
the full inventory for that suite. If the suite has no selected files, it does
not start Rails. Test failures return a nonzero exit status.

`run` requires a clean checkout at the selected head commit. Commit your changes
first; a selection based on committed code must not skip tests for unsaved code.
`select` and `check` can still run while your checkout has changes.

In CI, keep your full-suite job while trying this out. Add the selection command
as a separate step and print its JSON in the log or upload it as an artifact.
Test Sieve does not publish a report for you.

## Record outcomes and timings

Add this after `require "rails/test_help"` in a Rails app's `test/test_helper.rb`.
For plain Minitest, add it after `require "minitest/autorun"` instead. The adapter
supports Minitest 5 (5.25.4 or newer) and Minitest 6:

```ruby
require "test_sieve/minitest"

TestSieve::Minitest.install!(
  outcome_output: ENV["TEST_OUTCOMES_OUTPUT"], # JSONL: start, each result, and end.
  timing_output: ENV["TEST_TIMING_OUTPUT"], # JSON: per-test and total durations.
  suite: ENV.fetch("TEST_SUITE_NAME", "unit"), # Set to system for browser tests.
  root: Dir.pwd # Use Rails.root.to_s if tests can start outside the app root.
)
```

Commit the test-helper setup before your next code-change comparison. No files
are written unless you supply an output path. Try a recorded unit run:

```sh
TEST_OUTCOMES_OUTPUT=/tmp/unit-outcomes.jsonl \
TEST_TIMING_OUTPUT=/tmp/unit-timings.json \
  bundle exec test-sieve run --base "$base" --suite unit
```

The Rails adapter sets `TEST_SUITE_NAME` for the child process. Outcomes include
pass, fail, error, and skip results, in execution order. Completed test records
survive a later crash. Timings list tests slowest first. GitHub Actions run,
attempt, and repository metadata are included when its environment variables
are present; nothing is uploaded automatically.

Use a fresh outcomes path for each run: the JSONL file is append-only. Use
separate paths for unit and system runs so their identities and timings stay
separate. Without explicit paths, you can run both suites with
`bundle exec test-sieve run --base "$base"`.

For plain Minitest without Rails, install the same reporter and run your usual
command with `TEST_SUITE_NAME=unit` and the output variables shown above.

## Configure the adapter

The default Rails layout needs no Ruby configuration. For different test paths
or coverage roles, create `config/test_sieve.rb`:

```ruby
require "test_sieve/rails"

TestSieve::Rails.policy(
  manifest_path: "test_ownership.yml", # Change if you keep the map elsewhere.
  test_pattern: "test/**/*_test.rb", # Change to match all your test files.
  system_pattern: "test/system/**/*_test.rb" # Change to match your system tests.
)
```

Pass it explicitly:

```sh
bundle exec test-sieve select --config config/test_sieve.rb --base "$base"
bundle exec test-sieve run --config config/test_sieve.rb --base "$base" --suite unit
```

Commit configuration changes before the code change you want to compare.
Configuration files execute Ruby and must return a `TestSieve::Policy`; only
load files you trust. Test Sieve does not load a configuration file automatically.

If your project wraps Rails in another command, create `script/test_affected.rb`:

```ruby
require "test_sieve/cli"

exit TestSieve::CLI.new(
  command: ["bin/test"] # Replace with your runner's argument array; no shell strings.
).call(["run", *ARGV])
```

Commit the script, then invoke it with the same options as the built-in command:

```sh
# Replace origin/master with your base branch.
bundle exec ruby script/test_affected.rb --base origin/master --suite unit
```

The CLI checks that the selection matches a clean checkout before invoking your
runner. Add `--config config/test_sieve.rb` if you use a custom policy.

## More examples

### Include tests for a dependent feature

Suppose invoices use the shipping calculation. Add this under `owners` alongside
`shipping`, using real source and test paths:

```yaml
  invoicing:
    sources:
      - lib/invoice.rb # Replace with the dependent feature's source file.
    inputs: []
    depends_on: [shipping] # Name the owner this feature depends on.
    tests:
      unit:
        - test/invoice_test.rb # Replace with its unit test.
      system:
        - test/system/invoice_test.rb # Replace with its system test.
    notes: Invoices include the calculated shipping price.
```

Commit the updated map before making the source change you want to compare.
Now a change to shipping selects both features' tests:

```json
{
  "mode": "selected",
  "affected_owners": ["invoicing", "shipping"],
  "unit_files": ["test/invoice_test.rb", "test/shipping_test.rb"],
  "system_files": ["test/system/checkout_test.rb", "test/system/invoice_test.rb"]
}
```

The direction matters: invoicing depends on shipping. A shipping change needs
invoice tests; an invoice-only change does not need shipping tests.

### Select tests when a template or fixture changes

Add other files that affect shipping to its `inputs` list:

```yaml
    inputs:
      - app/views/checkout/_shipping.html.erb # Replace with your template.
      - test/fixtures/shipping_rates.yml # Replace with your fixture.
```

After committing the updated map, a change to either input selects the shipping
unit and checkout system tests, just like a change to `lib/shipping.rb`.

### Run everything for unknown or broad changes

With the getting-started map:

| Change | Result |
| --- | --- |
| `lib/shipping.rb` | Shipping unit test and checkout system test |
| An unmapped file, such as `lib/tax.rb` | Full test inventory |
| `Gemfile.lock` | Full test inventory, as declared in `broad_changes` |
| The ownership map itself | Full test inventory |

For a full run, the result contains `mode: "full"`, the full file lists, and
`reasons` explaining why selection could not narrow the change.

## Understand how selection works

Git identifies which files changed. Your map connects those files to tests.
Test Sieve reads the map at both revisions and follows declared dependencies to
include tests for affected features. Your runner executes the returned files.

### The map describes coverage

The map calls each named feature an **owner**: a part of your app, not a person.
In the examples above, `shipping` and `invoicing` are owners.

- `sources` lists the code the tests cover.
- `inputs` lists other files that affect the feature, such as templates or
  fixtures. Changes to these files also select the feature's tests.
- `tests` lists the test files to select when a source or input changes.
- `depends_on` names other owners this feature uses. Test Sieve follows these
  relationships through all declared consumers.
- `default: full_suite` means an unmapped change needs the full suite.
- `broad_changes` lists changes that always need the full suite.

Source, input, and test entries are exact paths. `broad_changes` accepts glob
patterns; each pattern must match a tracked file.

The map is your statement of coverage, not coverage that Test Sieve discovers.
It does not infer dependencies from AI, static analysis, or previous test runs.
If you leave a real dependency out of an otherwise valid map, it can miss tests.
A passing full suite does not prove that the proposed selection includes every
test you need. Review the map as carefully as the code it describes.

### The policy describes your test inventory

The **policy** tells Test Sieve where to find all your tests and how to read the
map. The Rails adapter supplies defaults that you can override:

- `test_pattern` finds the full inventory.
- `system_pattern` identifies its system tests.
- `required_roles` requires every owner to declare unit and system coverage.
- `role_suites` assigns those roles to the result's unit and system file lists.
- `rules` identifies the files that control selection. Changing these files
  must not silently authorize skipping tests under different rules.

### The comparison identifies the change

By default, Test Sieve compares the merge base of `--base` and `--head` with the
head revision. This finds the changes introduced by a branch. `--head` defaults
to `HEAD`. Use `--comparison push` to compare the supplied commits directly.

### Full runs and errors need different handling

The selector returns `mode: "full"` for unknown paths, broad changes, changed or
invalid maps, and other conditions that prevent a reliable selection. The
returned file lists contain the full test inventory.

If Test Sieve cannot establish a usable inventory, it raises an error. Your CI
adapter must then run its normal full-suite command or fail the job. Never treat
a selection error as an empty successful test run.

Measure the time saved in your own CI; fewer selected files do not guarantee a
faster pipeline.

## Is it a fit for my app?

Use Test Sieve when your suite is slow, you can identify meaningful boundaries
between features, and you control the scripts that run your tests.

The gem includes selection commands, a Rails runner adapter, and optional
Minitest reporters. It does not include a hosted service or GitHub Action.
Your project owns its coverage map, CI approval rules, and artifact uploads.

The core Ruby API works without Rails or Minitest. The Minitest adapter uses the
Minitest installed by your app; load it only in tests. Other frameworks can use
the selection API and their own runner.

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

# Test Sieve

Run the tests affected by a code change. Run the full suite when the change
cannot be safely narrowed down.

Map your code to tests, compare a change, and pass the selected files to your
existing runner. Test Sieve is a Ruby library, not a test runner or ready-made CI
integration.

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
      - lib/shipping.rb
    inputs: []
    tests:
      unit:
        - test/shipping_test.rb
      system:
        - test/system/checkout_test.rb
    notes: Shipping prices are also checked through checkout.
```

Replace `lib/shipping.rb` with a source file in your app. Replace the two test
paths with its unit and system tests. This tells Test Sieve: “When this code
changes, run these tests.”

### 3. Copy the selection script

Create `script/select_tests.rb`:

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

Change `test_pattern` and `system_pattern` if your tests use a different directory
layout. This script prints which tests to run; it does not execute them.

### 4. Make a change and see which tests it needs

Commit the map and script **before** the change you want to test. To try it
locally, save that starting commit:

```sh
base=$(git rev-parse HEAD)
```

Edit your mapped source file and commit the change. Then run from your repository
root, in the same shell:

```sh
bundle exec ruby script/select_tests.rb "$base" HEAD
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
bundle exec ruby script/select_tests.rb origin/master HEAD
```

Replace `origin/master` with your own base branch. Both revisions must exist
locally. Uncommitted edits are not included.

### 5. Inspect the selection before using it to skip tests

Save and read the result:

```sh
bundle exec ruby script/select_tests.rb "$base" HEAD > /tmp/test-sieve-selection.json
cat /tmp/test-sieve-selection.json
```

Keep running your usual full-suite command while you check the proposed
selections on real changes. For this example, do the lists include both shipping
and checkout tests? If an expected test is missing, correct the map.

When you are ready to use selection, pass `unit_files` to your unit-test command
and `system_files` to your system-test command. Test Sieve selects whole files,
not individual test methods. If `mode` is `full`, run all the returned files.

In CI, keep your full-suite job while trying this out. Add the selection command
as a separate step and print its JSON in the log or upload it as an artifact.
Test Sieve does not publish a report for you.

## More examples

### Include tests for a dependent feature

Suppose invoices use the shipping calculation. Add this under `owners` alongside
`shipping`, using real source and test paths:

```yaml
  invoicing:
    sources:
      - lib/invoice.rb
    inputs: []
    depends_on: [shipping]
    tests:
      unit:
        - test/invoice_test.rb
      system:
        - test/system/invoice_test.rb
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
      - app/views/checkout/_shipping.html.erb
      - test/fixtures/shipping_rates.yml
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
map. In the script above:

- `test_pattern` finds the full inventory.
- `system_pattern` identifies its system tests.
- `required_roles` requires every owner to declare unit and system coverage.
- `role_suites` assigns those roles to the result's unit and system file lists.
- `rules` identifies the files that control selection. Changing these files
  must not silently authorize skipping tests under different rules.

### The comparison identifies the change

With `comparison: "pr"`, Test Sieve compares the merge base of the supplied
revisions with the head revision. This finds the changes introduced by a branch.
Use `comparison: "push"` to compare the two supplied commits directly instead.

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

The gem provides selection and verification logic. It does **not** include a
ready-made CLI, Rails integration, GitHub Action, test runner, or framework
reporter. You write a small adapter for your project. There is no dependency on
Rails or Minitest at runtime.

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

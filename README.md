# Test Sieve

Select affected test files from a Git repository, build a fixed manifest, and
verify that a run executed every assigned file. Validate ownership maps and
reject incomplete or conflicting execution evidence.

The Ruby interface is framework-neutral. Supply your own runner, reporter, and
record parser. No runner or framework reporter is bundled. The gem does not
approve skipping tests.

## Installation

Requires Ruby 3.2+ and Git. Install from GitHub with Bundler:

```ruby
gem "test_sieve", github: "ramontayag/test_sieve", branch: "master"
```

Run `bundle install`, then load the public interface:

```ruby
require "test_sieve"
```

The gem preserves the `TestSelection` and `TestOwnership` namespaces and the
`require "test_selection"` entrypoint. RubyGems publication is planned later.

## Test

Requires Ruby, Git, and the dependencies in `Gemfile`:

```sh
bundle install
bin/test
```

The suite includes a built-gem installation test. It builds and installs the gem
in a temporary directory, then runs the public API contract outside the checkout.
CI runs the same suite on Ruby 3.2 and 3.4 without Rails or Docker.

## Configure a consumer

```ruby
require "test_sieve"

policy = TestSelection::Policy.new(
  manifest_path: "ownership.yml",
  test_pattern: "checks/**/*.spec",
  system_pattern: "checks/acceptance/**/*.spec",
  required_roles: %w[ fast acceptance ],
  optional_roles: [],
  role_suites: { "fast" => "unit", "acceptance" => "system" },
  rules: [ "ownership.yml" ],
  identity: "my-consumer-v1"
)

selection = TestOwnership::Selector.new(
  root: repository, base: base_commit, head: tested_commit,
  comparison: "push", policy: policy
).call

manifest = TestSelection::SystemManifest.build(
  root: repository, selection: selection, commit: tested_commit,
  shards: 4, policy: policy
)
```

`unit` and `system` are the result contract's two suite labels. The consumer maps
its own coverage roles and test paths to them. The manifest assigns whole system
test files across any positive job count. Consumers may restrict supported counts
in their execution adapters.

The ownership document names exact source, input, and test paths, dependency
edges, and broad-change rules. The consumer supplies it at each compared commit.
Unknown or broad changes require the full inventory. Unsafe or unavailable
inventories fail instead of returning an empty selection.

## Verify execution

Write the manifest as JSON. Run the assigned files using the consumer's runner,
then pass the resulting run directories and caller-owned expectations:

```ruby
gate = TestSelection::SystemRunGate.new(
  root: repository, manifest_path: manifest_path,
  expected_commit: tested_commit, run_id: "local-run", run_attempt: "1",
  repository: "example/project", shards: 4, run_dirs: result_directories,
  policy: policy, record_parser: ->(line) { JSON.parse(line) }
)

raise gate.errors.join("; ") unless gate.call
puts JSON.generate(gate.report)
```

The parser converts each JSON record into the normalized result hash below.
Quizzard supplies its own parser; the package does not load Rails or the
application's reporter. Parsers must preserve records and conflicts rather than
discarding unknown data. The package checks the normalized records again.

### Normalized records

An outcome stream is newline-terminated JSONL: one `run_start`, zero or more
`test_result` records, and one `run_end`. Nonempty assignments require results.

Every record includes:

- `type`, an ISO-8601 `timestamp`, `run_id`, and `run_key`.
- `metadata`: `repository`, `workflow_run_id`, `workflow_run_attempt`, `commit`,
  `dirty: false`, `suite`, and `shard`.
- For job N of M, suite is `system-shard-N` and shard is `shard-N-of-M`.
- `run_id` joins the run ID, attempt, suite, and shard with `/`; `run_key`
  prefixes that value with the repository and `/`.

The `workflow_*` field names describe the wire format. Callers supply their
values explicitly; the package reads no workflow environment variables.

Each `test_result` includes `test_class`, `test_name`, `test_id` (class plus `#`
plus name), `file`, positive source `line`, sequential one-based
`execution_index`, nonnegative finite `duration_seconds`, and `outcome`
(`pass`, `fail`, `error`, or `skip`). Failures and errors also include
`error_class`, `error_message`, and a string-array `backtrace`.

The end record requires `completed: true` and `interrupted: false`. Run metadata
must agree across every record. Source attribution uses the supplied policy and
committed inventory. Results from another suite cannot cover an assigned file.

Each `shard-N.json` records `shard_index`, `shard_total`, `commit`, `run_id`,
`run_attempt`, `mode`, `manifest_checksum`, `run_files`, `files_digest`, `files`,
`empty`, `exit_status`, and the `outcomes` filename. Empty jobs still require an
explicit shard record. The caller supplies the required job count; the records
cannot reduce it.

See `test/public_api_test.rb` for a complete runnable producer and verifier,
including empty jobs, malformed evidence, and stale identities.

## Identity and trust

- `rules_digest` hashes the package library code; `engine_version` records the
  package version.
- `policy_digest` hashes explicit policy settings and the consumer's `identity`.
  Include adapter/parser changes in that identity.
- Ownership-map digests identify the policy documents at both commits.
- Source SHAs identify the comparison and tested source.

Replaying a manifest compares these values with current inputs. Old reports are
not refreshed by packaging or by changing a version label. A valid manifest is
not proof that its author, comparison base, or selection approval is trusted.
The consumer owns those decisions.

## Provenance

Extracted from Quizzard's
[`tools/test_selection` at e8b54f72](https://github.com/ramontayag/quizzard/tree/e8b54f72e63f70646f2cd3a168153e57240c4623/tools/test_selection).
The extraction preserves the library behavior and generic tests.

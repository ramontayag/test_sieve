# Verify a parallel test run

Execution verification checks that the files assigned to each job actually ran
and that their results belong to the expected commit and CI run. It does not
prove that your ownership map covers every dependency or approve skipping tests.

Start with the map from the [getting-started example](../README.md#get-started).
Save the selection for your comparison:

```sh
# Replace origin/master with your base branch.
bundle exec test-sieve select --base origin/master --output /tmp/selection.json
```

## Build a manifest

```ruby
require "test_sieve/rails"

policy = TestSieve::Rails.policy # Use the same policy as your selection command.
selection = JSON.parse(File.read("/tmp/selection.json"))
manifest = TestSieve::SystemManifest.build(
  root: repository,
  selection: selection,
  commit: tested_commit,
  shards: 4,
  policy: policy
)
File.write(manifest_path, JSON.pretty_generate(manifest))
```

`repository` is the checkout path, `tested_commit` is the selected commit SHA,
and `manifest_path` is where your runner reads the manifest. The manifest assigns
whole system-test files across any positive job count. Read each job's files from
`manifest.fetch("assignments").fetch("shards")`.

Your runner executes those files and writes the records described below.

## Verify results

```ruby
gate = TestSieve::SystemRunGate.new(
  root: repository, manifest_path: manifest_path,
  expected_commit: tested_commit, run_id: "local-run", run_attempt: "1",
  repository: "example/project", shards: 4, run_dirs: result_directories,
  policy: policy, record_parser: ->(line) { JSON.parse(line) }
)

raise gate.errors.join("; ") unless gate.call
puts JSON.generate(gate.report)
```

`result_directories` contains the directories holding the shard records and
outcome files. Supply the expected commit, run, attempt, repository, and job count
from your CI context, rather than trusting values in the result files.

The parser converts each outcome line into a normalized result hash. If your
reporter writes another format, supply an adapter here. Preserve unknown records
and conflicts so verification can reject them rather than silently discard them.

## Outcome records

An outcome file is newline-terminated JSONL: one `run_start`, zero or more
`test_result` records, and one `run_end`. Nonempty assignments require results.

Every record includes:

- `type`, an ISO-8601 `timestamp`, `run_id`, and `run_key`.
- `metadata`: `repository`, `workflow_run_id`, `workflow_run_attempt`, `commit`,
  `dirty: false`, `suite`, and `shard`.
- For zero-based job N of M, suite is `system-shard-N` and shard is `shard-N-of-M`.
- `run_id` joins the run ID, attempt, suite, and shard with `/`; `run_key`
  prefixes that value with the repository and `/`.

The `workflow_*` field names are part of the format, not a GitHub Actions
dependency. The optional Minitest adapter reads GitHub Actions environment
variables to populate them. Other CI systems can supply a metadata object whose
`run_metadata` method returns the same fields.

The [Minitest adapter](../README.md#record-outcomes-and-timings) writes these
outcome records. Set `TEST_SUITE_NAME=system-shard-N`, `TEST_SHARD_INDEX=N`, and
`TEST_SHARD_TOTAL=M` for each shard. Use a separate outcome path for each shard.
The adapter writes outcomes and timings; your CI runner still writes the shard
records described below.

Each `test_result` includes `test_class`, `test_name`, `test_id` (class plus `#`
plus name), `file`, positive source `line`, sequential one-based
`execution_index`, nonnegative finite `duration_seconds`, and `outcome`
(`pass`, `fail`, `error`, or `skip`). Failures and errors also include
`error_class`, `error_message`, and a string-array `backtrace`.

The end record requires `completed: true` and `interrupted: false`. Run metadata
must agree across every record. Results from another suite cannot cover an
assigned file.

## Shard records

Each `shard-N.json` records `shard_index`, `shard_total`, `commit`, `run_id`,
`run_attempt`, `mode`, `manifest_checksum`, `run_files`, `files_digest`, `files`,
`empty`, `exit_status`, and the `outcomes` filename. Empty jobs still require an
explicit shard record. Records cannot reduce the caller's required job count.

Use the [public API tests](../test/public_api_test.rb) as a runnable example of
the complete record format and verification behavior.

## Reject stale manifests

Manifests identify the engine, policy, ownership map, and tested source:

- `rules_digest` hashes the library code; `engine_version` records its version.
- `policy_digest` hashes policy settings and the consumer's `identity`. Include
  adapter and parser changes in that identity when they affect interpretation.
- Ownership-map digests identify the documents at both commits.
- Source SHAs identify the comparison and tested source.

Replay checks these values against current inputs. Changing a version label or
repackaging the gem does not renew old evidence. The caller remains responsible
for trusting the comparison base and deciding when selective execution is allowed.

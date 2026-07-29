# Architecture

## Design goals

Meow separates ebook structure, translation, job orchestration, persistence,
and presentation. EPUB is the first codec, but the domain layer does not
require every ebook format to expose pages or use ZIP.

The application processes translation units incrementally. It never builds a
whole-book translation request or keeps all translated text in memory.

```mermaid
flowchart LR
    UI["macOS UI"] --> Jobs["JobController"]
    Jobs --> Codec["EbookCodec / EbookSession"]
    Jobs --> Engine["TranslationEngine"]
    Codec --> Workspace["Per-job workspace"]
    Engine --> DeepSeek["DeepSeek Chat API"]
    Engine --> Codex["OpenAI Responses API"]
    Jobs --> History["Persistent job history"]
```

## Ebook codec boundary

`EbookCodec` owns format recognition, unpacking, and workspace restoration.
`EbookSession` exposes a stream of semantic `TranslationUnit` values, records
completed translations, and repacks the output.

No API assumes that an ebook has stable pages. A unit is normally a paragraph,
heading, list item, table cell, or other block-level element. Inline formatting
splits a unit into stable fragments so an AI model receives the full unit while
Meow can preserve the original markup.

## EPUB fidelity model

Unpacking writes each ZIP entry to disk and records entry order, compression,
mode, OPF metadata, and XHTML resource order. The source XHTML remains
unchanged during translation.

The XHTML segmenter records:

- resource path;
- semantic block type;
- source character offsets;
- SHA-256 source hashes;
- ordered fragment identifiers.

Translations are appended to `translations.jsonl`. Repacking re-segments the
original XHTML, checks every source hash, XML-escapes translated text, and
applies replacements from the highest offset to the lowest. Replacements
therefore cannot shift offsets that have not been applied yet.

The repacker always emits `mimetype` first with no compression. Every untouched
entry is copied from its unpacked payload. OPF IDs, XHTML IDs, attributes,
links, media paths, CSS, fonts, and images are not regenerated.

This is semantic and payload fidelity, not binary ZIP identity. Compression
streams and ZIP metadata may differ after repacking, while every decompressed
untouched entry remains byte-identical.

## Translation boundary

`TranslationEngine` is the only public model boundary:

```dart
abstract interface class TranslationEngine {
  String get id;
  Stream<TranslationEvent> translate(TranslationRequest request);
  void close();
}
```

Model-specific HTTP clients are implementation details. A request contains a
bounded `TranslationChunk`, normally one unit, plus a cancellation token. An
engine can emit token deltas, a validated completion, a failure, or
cancellation. HTTP headers must arrive within 30 seconds, and an established
stream may be idle for at most 90 seconds. Abandoning a job cancels the active
request and closes its HTTP client.

The model receives source data as structured JSON. The prompt marks ebook text
as untrusted and requires exact unit and fragment identifiers. Completed JSON
is validated before it reaches the EPUB session.

## Jobs and recovery

Each source file creates one `TranslationJob` with a unique workspace. Jobs
persist total, completed, and failed unit identifiers. A successful unit is
flushed to the translation transcript and job history before the next unit
starts.

```text
queued -> unpacking -> translating -> repacking -> completed
                         |
                         +-> waitingForAction -> queued
                                      |
                                      +-> abandoned
```

If the app closes during work, the job is restored as `waitingForAction`.
Retrying reopens the existing workspace, skips completed units, and uses the
current configuration for the same provider. Abandoning removes the temporary
workspace after in-flight work stops.

Active workspaces live in Application Support rather than the purgeable cache.
If a workspace is nevertheless missing or damaged, Meow clears all persisted
unit progress before translating again. On every restore it verifies that each
persisted completion identifier is present in the translation transcript; it
never trusts job progress without its overlay record. Completed and abandoned
workspaces are deleted, including legacy cache locations.

`abandoned` is a monotonic terminal state. Repository updates reject stale
worker snapshots that attempt to replace it, and the controller reloads the
current job after asynchronous translation and repacking operations.

The source file and output directory are stored as macOS security-scoped
bookmarks. Meow resolves and starts access only while unpacking or repacking,
then releases it. This lets a queued or retried job recover sandbox access
after relaunch. Legacy jobs without bookmarks ask the user to add the book
again.

Output names are reserved with an exclusive hidden lock. Repacking writes to a
hidden staging file on the same filesystem as the destination, while the final
`.epub` path remains absent. A complete ZIP is atomically renamed into place.
The reservation path is persisted so startup can remove interrupted staging,
locks, or unpublished output before retrying. Concurrent books with the same
basename receive different numbered paths.

Remembered output paths are usable only with a matching security-scoped
bookmark. A legacy configuration without one leaves the field empty and asks
the user to choose the folder again.

## Storage

- `config.json`: last-used options and provider configuration.
- `jobs.json`: provider, security-scoped bookmarks, persistent job history,
  and unit states. It never contains API keys or model configuration.
- `workspaces/<job-id>`: persistent in-progress source copy, unpacked entries,
  manifest, transcript, and patched XHTML. Removed at terminal completion or
  abandonment.

Configuration and job files are written atomically with mode `0600` on macOS
and Linux. Job writes are serialized from immutable snapshots so concurrent
workers cannot share a temporary rename target. API keys are read from the
current `config.json` only when a job runs; authorization headers are never
written to job history or translation transcripts.

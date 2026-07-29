# Testing

## Deterministic suite

Run formatting, static analysis, and deterministic tests:

```sh
mise run check
```

The generated EPUB fixture covers:

- OPF metadata and spine discovery;
- streaming translation unit extraction;
- stable unit identifiers;
- inline markup fragmentation;
- XML entity decoding and encoding;
- workspace restoration;
- no-op repacking;
- translated text replacement;
- plain-text model responses and program-owned unit association;
- bilingual original-block preservation and identifier-free translated clones;
- named XHTML entity decoding without double-escaping;
- untouched binary resource preservation;
- `mimetype` order and compression;
- ZIP path traversal rejection.

The deterministic suite also covers credential-free job serialization,
legacy job migration, serialized concurrent history writes, private history
permissions, atomic output filename reservation, stalled-request
cancellation, SSE idle timeouts, missing-workspace progress reset, monotonic
cancel state, interrupted-output recovery, terminal workspace cleanup, and
legacy output-folder migration. Recovery regressions also cover cross-job
output ownership, interrupted JSONL tail repair, and migration of unfinished
legacy cache workspaces without retranslating completed units.

## Real-book suite

The real EPUB suite is opt-in because books must not be checked into the
repository:

```sh
MEOW_TEST_EPUB="/absolute/path/to/book.epub" mise run test-real
```

It compares every decompressed archive entry after an unpack/no-op-repack
round trip. ZIP files are not expected to be binary-identical because a new
central directory and compression streams are generated.

## Build verification

```sh
mise run build
```

This checks plugin registration, macOS entitlements, CocoaPods integration, and
release compilation in addition to Dart analysis.

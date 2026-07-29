# Meow

<p align="center">
  <img src="assets/icon/meow-icon-master.png" width="180" alt="Meow app icon">
</p>

Meow is a native-feeling macOS application for translating DRM-free EPUB,
MOBI, and AZW3 ebooks with AI.

The application unpacks an EPUB into an isolated job workspace, streams small
translation units to a configured engine, stores translations as an overlay,
and rebuilds a new EPUB without changing the source package in place.

## Current capabilities

- Drag and drop one or more EPUB, MOBI, or AZW3 files.
- Remember the output directory, target language, model provider, and whether
  to keep the original text above each translation.
- Run multiple persistent jobs with progress and failure history.
- Retry unfinished translation units or abandon a job.
- Pause and resume jobs without retranslating completed units.
- Retry only failed units, or explicitly clear and retranslate the whole book.
- Inspect persistent, redacted, real-time logs for every job.
- Convert MOBI/AZW3 through a local Calibre installation and optionally export
  back to the source format.
- Restore sandbox file access across launches with security-scoped bookmarks.
- Stream DeepSeek and OpenAI-compatible Chat Completions with cancellation
  and bounded timeouts, or run a locally authenticated Codex CLI process.
- Send one plain-text unit per model request and keep response formatting,
  identifiers, and transcript JSON under program control.
- Store model configuration, including API keys, in a plain JSON file.
- Notify on completion and reveal the output in Finder.
- Preserve EPUB paths, package identifiers, original element identifiers,
  attributes, links, styles, and non-text resources. Bilingual translated
  clones omit `id` and `xml:id` attributes to avoid duplicate identifiers.
- Verify no-op EPUB round trips against both generated fixtures and opt-in real
  books.

## Translation engines and languages

- **Codex CLI** runs the locally installed `codex` executable with
  `codex exec --model <model>`. It uses the local Codex login, not an API key.
- **OpenAI Compatible API** uses the streaming
  `POST /v1/chat/completions` protocol with a custom base URL, model, and key.
- **DeepSeek** is a preconfigured OpenAI-compatible provider.

The interface follows the current system locale and falls back to English.
English, Simplified and Traditional Chinese, Japanese, Korean, German, French,
Spanish, Portuguese, and Russian locales are recognized.

## Requirements

- macOS
- [mise](https://mise.jdx.dev/)

MOBI and AZW3 support requires
[Calibre](https://calibre-ebook.com/download_osx):

```bash
brew install --cask calibre
```

## Install with Homebrew

The app is not Apple-notarized. The Homebrew cask clears the macOS quarantine
attribute after installation:

```bash
brew tap jjyr/tap
brew install --cask meow
```

Upgrade to the latest release with:

```bash
brew upgrade --cask meow
```

The repository pins Flutter 3.38.9 in `mise.toml`.

```sh
mise trust
mise install
mise run bootstrap
mise run check
mise run run
```

To build the application:

```sh
mise run build:mac
```

## Real EPUB integration test

Real books are never committed to the repository. Point the opt-in test at a
local DRM-free EPUB:

```sh
MEOW_TEST_EPUB="/absolute/path/to/book.epub" mise run test-real
```

The test unpacks and repacks the book without translations, then verifies:

- archive entry order and names;
- decompressed bytes for every entry;
- the package identifier;
- translation unit discovery;
- the required first, uncompressed `mimetype` entry.

## Local data

Meow stores configuration and job history in the macOS Application Support
directory. API keys intentionally use plain-text `config.json` with owner-only
file permissions. `jobs.json` contains no credentials; a job stores only its
provider and resolves the current model configuration when it runs.
Translation transcripts contain unit identifiers, source text, and translated
text.

In-progress EPUB workspaces live below the Application Support directory so
macOS cannot purge resumable translations:

```text
workspaces/<job-id>/
```

Each job uses a separate directory so concurrent jobs cannot overwrite one
another. Meow removes the workspace when the job completes or is abandoned.
Final EPUBs are first built in a hidden destination-local staging file and
then atomically published.

See [Architecture](docs/architecture.md) and [Testing](docs/testing.md) for
implementation details.

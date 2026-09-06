# HS03 — Plain Java core, ITCH reader and synthetic oracle

> Status: complete 2026-09-04 (as-built below). Prerequisites: HS01.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §4 and §5.2.

## Outcome and anchors

kzen-sample-plugin/pom.xml and its Java sample sources; create core and adapter Maven modules.

## Work

1. Read the sample's local guide if present. Split the Maven project into a zero-kzen Java core and a thin adapter. Preserve the cities sample logic for HS21; do not retire its existing entry point until the replacement is runnable.
2. Read the official ITCH 5.0 specification. Implement strict length-prefixed framing over raw/gzip input, closeable iteration and a sealed message-record family. Keep wire decoding separate from analytical state.
3. Add a seeded synthetic writer and independently specified expected events/results: equal timestamps, multiple locates, locate-zero events, execution-with-price/printability, replacements, full/partial fills, cancels/deletes, non-displayed/cross trades and breaks.
4. Define the named comparison result precisely as a fixture metric (per-symbol trade-event count and shares, correcting eligible prior events for breaks). Record whether non-printable executions count; use the analysis's all-E/C/P/Q event metric consistently, without calling it official exchange volume.
5. Cover truncation, bad lengths, unknown message types, invalid references and failed opening without leaking handles. Read the Nasdaq download terms for D2; never add real feed data to git.

## Verification and exit criteria

Run Maven core tests on Java 25. Prove the core dependency tree has no kzen artifact. Golden expected bytes/events must supplement writer-reader round trips so a shared encoding bug cannot pass. Demonstrate streaming decode with bounded live wire objects.

## Handoff

Record module/artifact names and parser policy. The core and fixture unlock HS04; reader adapters remain HS21.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-04. `kzen-sample-plugin` is now a two-module Maven reactor (`packaging pom`):

| Module | Artifact | Content |
|---|---|---|
| `kzen-sample-core` | `tech.kzen.sample.plugin:kzen-sample-core` (+ `tests` jar) | plain Java 25, **no kzen or Kotlin dependency** — an enforcer `bannedDependencies` rule on `tech.kzen.*` and `org.jetbrains.kotlin` fails the build if one ever arrives; `dependency:tree` shows only `junit-jupiter:6.1.1:test` and its platform |
| `kzen-sample-adapter` | `tech.kzen.sample.plugin:kzen-sample-adapter` | the existing world-cities `ReportDefiner` sources and `META-INF/kzen/plugins.yaml`, `git mv`-ed unchanged (retired in HS21 once the Job route runs); depends on the core, `kzen-auto-plugin 0.30.0-SNAPSHOT`, Guava; `-parameters`; `copy-dependencies` → `target/lib/` (22 jars incl. the core), manifest `Class-Path: lib/…` |

**Core API** (package `tech.kzen.sample.itch`):
- `message.ItchMessage` — sealed interface, one record per ITCH 5.0 kind (`S R H Y L V W K J h A/F E C X D U P Q B I N O`),
  each with `ItchHeader(ordinal, stockLocate, trackingNumber, timestampNanos)`; `ordinal` is the zero-based feed position
  (the equal-timestamp tie-breaker), not a wire field. Prices stay raw fixed-point (`priceScale4` / `priceScale8`); alpha
  fields are right-trimmed except single-character codes; `Side` is an enum; `AddOrder.attribution == null` means `A`, else `F`.
- `wire.ItchLayout` — offsets and the exact length of every type, shared by `ItchDecoder` and `ItchEncoder` (round-trip cannot
  hide a layout slip); `ItchFrameInput` — strict `[2-byte length][message]` framing over raw or gzip input (magic-byte
  detection), one reusable frame buffer; `ItchCursor` — `Iterator<ItchMessage> & AutoCloseable`, decodes one message per pull
  and closes the stream itself before any decode/framing failure propagates; `ItchReader(Path)` — `Iterable`, `open()`,
  `forEach` (closes), `stream()` (`onClose`).
- Parser policy: unknown type, wrong length for the type, bad printable flag, zero length prefix, partial prefix and partial
  message are all `ItchFormatException`s naming the feed ordinal; the feed may end only on a frame boundary.
- `analysis.SymbolCatalog` — locate → symbol from Stock Directory (locate 0 and re-announcement with a different symbol are
  errors); `analysis.TradeVolumeFold` → `SymbolTradeSummary(symbol, tradeEvents, shares)`, **the named comparison result**:
  per symbol, printed trade events = `E`, printable `C`, `P`, `Q` with shares > 0, minus `B` breaks resolved by match number.
  `E`/`C` are attributed through the message's Stock Locate. **Decision:** non-printable `C` and zero-share `Q` are remembered
  but not counted (a later `B` naming them is a no-op, an unknown match number is a named failure); the KDoc states this is a
  fixture metric, not exchange volume.

**Oracle (core test tree, shipped as the `tests` jar for the adapter):** `synth.SyntheticItchDay.generate(seed[, randomOrdersPerSymbol])`
writes the real binary format (`writeTo(path, gzip)`) and tallies `expectedTrades()` in its own bookkeeping as it emits.
The scripted prefix covers: start/system/market events and MWCB at locate 0, four directoried symbols (one never trades),
two adds at one timestamp and MSFT/GOOG interleaved at identical timestamps, partial then full fill, a `U` replace chain,
partial cancel and delete, an attributed `F` add, printable and non-printable `C`, a `P` non-displayed trade, `B` breaks of
a `C` and of a `P`, an opening cross and a zero-share halted cross; the seeded tail (default 400 orders per symbol,
3 symbols) adds random lifecycles. Hand-computed scripted result: AAPL 3 events / 130 shares, MSFT 2 / 1250, GOOG 1 / 10.

**Verification (`mvn -B package`, JDK temurin-25.0.4.1, Maven 3.9.9): BUILD SUCCESS, 12 tests, 0 failures.** `GoldenBytesTest`
holds hand-authored hex for 13 messages straight from the specification tables (two of my first hand values were wrong and
the encoder was right — `002dcaa8`, `00000041314cf000`); it checks encoder and decoder separately plus unknown type /
wrong length / bad flag. `ItchReaderTest`: raw and gzip round trip of the full synthetic day (message and ordinal equality,
`encodedLength == file size`), truncation named by ordinal with the file deletable afterwards on Windows (no leaked handle),
partial prefix / zero length / unknown type named, missing file → `NoSuchFileException`, and streaming proof (after three
messages of a 3 000-order feed fewer than half the bytes are consumed). `TradeVolumeFoldTest`: fold == generator tally on
the seeded day, the hand-computed scripted result, unknown locate / unknown match named, break of a non-printable is a no-op.

**D2 — Nasdaq terms:** the sample directory `https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/` (checked 2026-09-04) lists gzip day
files (3.5–17.9 GB, 2019 → 2026-06-12) with MD5 sums and **carries no terms-of-use, licence or disclaimer text**. The download
step in HS06 records source/date/fingerprint and the README (HS21/HS25) must tell the user they are fetching Nasdaq sample
data under whatever terms Nasdaq attaches to it; no feed file is committed (`target/` is gitignored; downloads live outside
the repo).

**Not changed, surfaced:** the root `dependency-reduced-pom.xml` is a stale artefact of the retired shade packaging;
`README.md` still describes the single-module layout (rewritten in HS21/HS25). Staged by explicit path: the three POMs and
every new core file; the adapter sources show as renames.

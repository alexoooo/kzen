# HS21 — ITCH and cities Job reader adapters

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS06, HS11, HS13 and HS18; HS12 diagnostics implementation available.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §5.2 adapter routes and §7 cities decision.

## Outcome and anchors

Sample adapter module; BlockingReaderCapability, ReaderProbeCapability, FormatAuthoringCapability and service metadata.

## Work

1. Implement the Java ITCH reader adapter over the core, including config decode/validate/canonicalize/encode, required content, bounded shape inspection, symbol/message/time filters and flat typed projection.
2. Add bounded probe/authoring support through existing automatic-format mechanisms. Compressed content must use the reader/content contract correctly; never infer binary framing from an extension alone.
3. Re-cut cities as the simple BlockingReaderCapability sample, retaining its useful parsing logic. Once this replacement runs, retire the sample ReportDefiner and the pending plugins.yaml/legacy loader path from HS12.
4. Package unshaded adapter/core/dependencies as an installable jar set, preserving META-INF/services and notation resources. Inspect current packaging rather than assuming the old sample still shades.
5. Confirm public Java implementation uses no Continuation signatures and the core still has no kzen imports/dependencies.

## Verification and exit criteria

Run reader contract/config tests and tiny binary fixtures through the actual File worker. Verify automatic detection, explicit configuration, malformed/truncated content, gzip handling, correct static columns and closure. Run cities through its new Job route before removing the old one.

## Handoff

Record install layout and sample commands. E2/E3 external acceptance is still HS22; no real data enters the repository.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 across kzen-sample-plugin (the adapter, rewritten), kzen-auto (four host defects the real
plugin surfaced, and the legacy retirement) and kzen-lib (two Java-facing conveniences). Order: kzen-lib
published, `:kzen-auto-plugin` + `:kzen-auto-common` published, the sample built with Maven offline, then the
whole chain — kzen-lib `build`, kzen-auto `build` + `publishToMavenLocal`, kzen-project `build`. No release-train
version changed; no real feed data entered any repository.

**ITCH reader (Work 1–2).** `ItchReaderCapability` (`BlockingReaderCapability` + `BlockingReaderProbe` +
`FormatAuthoringCapability`, identity `tech.kzen.sample/itch-5/1`) over the core's `ItchFrameInput` /
`ItchDecoder`: `ItchReadConfig` (symbols, message types, a nanosecond time-of-day window) decodes, validates by
name, canonicalizes (sorted, upper-cased) and encodes; required content is sequential bytes; `ItchDataCursor`
frames, learns the day's locate → symbol catalog from the stock directory as it streams, applies the filters and
projects each message to the static 14-column `ItchRow` literal record (ordinal, type, timestamp, locate, stock,
order reference, side, shares, price, match number, …). Inspection frames up to the record limit so a malformed
feed fails by name (`ItchFormatException`); the probe decodes a bounded number of frames from the sample and
matches on framing only — a `.itch` name over text is `Rejected("does not frame")`, never a match. The
authoring capability materializes a configured `ItchFormat` graph object from a resolved read. `ItchFormat`
(archetype `ItchFormat`, object `ItchDay` in the bundled `sample-formats.yaml`) declares the `itch` /
`nasdaq_itch50` extensions and reads a `.gz` source through the host's gzip content coding (the reader only ever
sees inflated bytes). `BlockingReaderProbe` (kzen-auto-plugin) is the blocking bridge for `probe`, as
`BlockingReaderCapability` is for open / inspect.

**Cities re-cut (Work 3).** `WorldCitiesReaderCapability` is the minimal sample: no configuration, ISO-8859-1
lines, the header row skipped, each line a typed `WcpRow` literal (empty numbers null), content-based detection
on the exact header row (`ContentSignature`; a `.txt` name alone never matches, and the format declares no
extension so plain text stays plain text). The old `WorldCitiesPopProcessorDefiner`, the `pipeline/*` stages,
the passthrough events and `META-INF/kzen/plugins.yaml` are deleted; the useful parsing lives on in `WcpRow.parse`
(Guava dropped — the adapter now has no third-party runtime dependency).

**Legacy path retired (Work 3, HS12's pending check).** kzen-auto: `LegacyPluginJar`,
`PluginReportDefinitionRepository` (+ its test and `plugin-cache-test.yaml`) and `MultiDefinitionRepository` are
deleted; `KzenAutoContext.definitionRepository` is the `HostReportDefinitionRepository` over the built-in
definers; the Plugin document lost its `jarPath` attribute (archetype, `PluginConventions`, the JS legacy-jar
editor) — a stale `jarPath:` line in an old document is ignored. Reports take the host's definers only; plugins
extend Jobs through the runtime's scopes.

**Packaging (Work 4).** The adapter's pom takes `kzen-auto-plugin` at `provided` scope, so `mvn clean package`
yields the adapter jar plus `target/lib/kzen-sample-core-*.jar` and nothing of the host's (a copied kzen jar would
shadow the host's classes); the jar carries `META-INF/kzen/plugin.yaml` (`id: kzen-sample`, `version: 0.0.1`,
`spi: 1`), `META-INF/services/tech.kzen.auto.plugin.api.data.ReaderCapability` (both readers) and
`notation/auto-jvm/kzen-sample-plugin/sample-formats.yaml`. Install = copy those jars into one folder under
`--plugin.root=`; the README records the layout and commands. (`clean` matters: `copy-dependencies` and the jar
task never remove what an earlier build left in `target/`.)

**Signatures (Work 5).** `javap` over every public adapter class shows no `kotlin.coroutines.Continuation`;
the core has no `tech.kzen` import (the enforcer already forbids the dependency).

**Four host defects the real plugin found, fixed in kzen-auto.** (1) `ReaderCapabilityRegistry` keyed probes by
the bare `compatibility` string, so the first external probing reader with `"1"` collided with the built-in
delimited reader at boot ("Duplicate reader probe capability 1") — probes are keyed by full identity, and the
detection cache key likewise (`ReaderCapabilityRegistryTest`: two probing readers may share the tag). (2) A
plugin's format class was `Unknown` to the graph: the scope's `ReflectiveClassMirror` serves `@Reflect` classes
only — the sample's Java formats are annotated, and the rule is documented (with `-parameters`, the typealias and
`@JvmOverloads` findings) in `docs/architecture.md` § 8 and an AGENTS gotcha. (3) Automatic detection decoded
the sample as text before any probe ran, so a binary feed could never match ("Input is not valid UTF-8 or
Windows-1252"): `AutomaticFormatResolver.decodeSample` keeps the text failure on `DecodedDetectionSample`
instead of throwing when no encoding was demanded, every eligible probe still sees the bytes with no character
view, and the failure surfaces only if nothing structured matched (`ConfiguredFormatExtensibilityTest`: binary
sample matched; unclaimed binary still fails in the decoder's words). (4) The cities header row tied with the
built-in delimited reader's structural match (`ContentStrong` both) and fell back to plain text — new
`ReaderProbeStrength.ContentSignature` tier between `ContentStrong` and `ExtensionValidated`
(`contributedSignatureOutranksTheBuiltInDelimitedGuess`). kzen-lib gained `RecordLiteral.of(Map)` (`@JvmStatic`)
and `@JvmOverloads` on `DataContract`, since Java can call neither `recordOf(vararg Pair)` comfortably nor a
defaulted Kotlin constructor.

**Verification.** Sample: `mvn -o -B clean package` — core 31 tests, adapter 10 (`ItchReaderCapabilityTest`:
config round trip, every message projected raw and inflated, symbol / type / time filters, bounded inspection
and malformed content by name, probe match / no-match / rejected; `WorldCitiesReaderCapabilityTest`: empty
config, typed rows with null population and ISO-8859-1 accents, malformed rows by name, bounded inspection with
the static columns, header-only probe). Through the actual File worker: my own kzen-auto on port 18090 (temp
module, work and plugin roots; the built jar with the JS bundle) with the installed jar set — the runtime logged
`Plugin scope 'kzen-sample' … 2 readers, 1 documents`; three Jobs `File → Preview` over a synthetic ITCH day
(124 messages, `SyntheticItchDay` from the core's test jar) as `.itch`, as `.itch.gz`, and over a hand-written
cities excerpt: each File card resolved "Automatic → NASDAQ ITCH 5.0 day · file contents" / "Automatic → World
cities population · file contents", and the runs delivered `emitted=124` / 124 typed rows with the 14 static
columns (both codings), and 4 city rows with `Population` null for the blank field and `Montréal` intact.
kzen-auto: `ReaderCapabilityRegistryTest` (9), `ConfiguredFormatExtensibilityTest` (4), the detection suites,
`:kzen-auto-jvm:pluginUniverseTest` (every boot class green). Full chain: kzen-lib `build` (595 JVM tests, 0
failures); kzen-auto `./gradlew build` green — 1058 kzen-auto-jvm tests and 116 kzen-auto-plugin tests, 0 failures (a first pass tripped the plugin module's allocation guard `FlatRecordValueAccessTest` while a Maven build ran alongside; it passes alone and in the clean re-run); kzen-auto published; kzen-project `build` green. New files staged by explicit path in
kzen-sample-plugin (adapter sources, resources, tests) and kzen-auto (`BlockingReaderProbe`); deletions staged.

**Handoff.** Install layout: `<plugin root>/kzen-sample/{kzen-sample-adapter-*.jar, kzen-sample-core-*.jar}`,
boot with `--plugin.root=<plugin root>`; sample commands in the sample README. E2/E3 external acceptance
(the compatibility kit over this very plugin directory, analytical Workers, bundled Jobs) is HS22. Caveat: a
Job's run cannot start while another document's finished run is still the active trace — clear traces first
(a UI habit, not a plugin matter).

# Business state — where a ledger lives, and how a domain app sits on kzen

> **Status: analysis. Nothing here is built.** Written 2026-08-26 from the question "if I built a small-business
> tax management / automation application on top of kzen, how would I integrate state — and what are the
> cross-platform distribution options?" It assumes the data-source arc as landed
> ([`2026-08-20_job-data-source.md`](2026-08-20_job-data-source.md)), the structural-data proposal
> ([`2026-08-25_structural-data.md`](2026-08-25_structural-data.md)) and the extension-point decisions
> ([`2026-08-21_extension-points.md`](2026-08-21_extension-points.md)) and does not revisit any of them; where a
> decision below depends on one of theirs it cites it. Per CC-20 no line numbers are cited; anchors are class /
> file / doc-section names. Decisions are collected in **§9** as `BS*`; everything not listed there is a proposal.

## 1. The question, restated

kzen has two kinds of state today: **notation** (YAML documents, the whole graph in memory, CQRS commands and
events, format-preserving deparse) and a smaller tier of **server-owned files** (compiled code, report runs, Job
worker output, all catalogued by `ManagedStorageRegistry`). A tax / bookkeeping application adds a third kind:
**business records** — journal entries and postings, invoices, inventory movements and cost layers, filings —
which are high-volume, transactional, queried by aggregate, and must be auditable for years.

The user's instinct is that a relational database fits that third kind. This document agrees, says *which*
database and *why*, and — the part that is actually specific to kzen — says where the line between notation and
database falls, which existing seams the database plugs into, and which seams do not exist yet.

## 2. Why the ledger is not notation

Notation is design-time configuration. The properties that make it good at that are the ones that make it wrong
for records:

- **Whole graph in memory, re-digested per edit.** `DirectGraphStore` caches the `GraphDefinitionAttempt` by the
  notation's content digest; every `NotationCommand` yields a new `GraphNotation` and, on next observation, a new
  define. Fifty thousand postings would make every UI edit re-digest fifty thousand objects.
- **Document-granular persistence.** `YamlNotationParser.unparseDocument` re-emits the changed object's text
  segment inside its document; a document is the write unit. A ledger's write unit is a posting.
- **No query.** `GraphNotation.firstAttribute` and inheritance-chain lookups are the access model. There is no
  aggregate, no range scan, no join — a trial balance would be a full traversal in Kotlin.
- **A hand-rolled YAML dialect.** `util/yaml/YamlParser.kt` is not a general-purpose serializer; its quoting and
  escaping rules are tuned for authored configuration, not for bulk data.

None of this is a defect. It is the same reason kzen already keeps report runs and Job output *outside* notation
under `WorkUtils` roots. The ledger is one more thing that is neither notation nor a scratch file.

## 3. The split — what goes where

| Tier | Contents for a tax app | Why it belongs there |
|---|---|---|
| **Notation** (`main/` documents, CQRS) | Chart of accounts; tax rules, rates, jurisdictions and their effective dates; entity / fiscal-year configuration; report templates; Data schemas for bank / receipt imports; the automation Jobs and Scripts themselves | Authored by the user, low volume, benefits from undo, diffability, rename-as-refactor, and the Notation → Definition → Instance model. Everything a bookkeeper would want to *review as a document* |
| **Relational DB** (one file per project) | Journal, postings, documents (invoices, receipts, bills), parties, inventory items and movements, cost layers, reconciliation state, filings and their computed figures | Transactional, high volume, aggregate queries, referential integrity, years of retention |
| **Managed storage** (`ManagedStorageRegistry`) | The DB file itself (registered *display-only*, non-deletable); imported source documents (PDF / image attachments) as a budgeted area; export bundles | Disk stays centrally accountable — the § 6 convention in kzen-auto `docs/architecture.md` |
| **Run / trace** (in-memory engine projection) | An import run's progress and diagnostics | Already how every Logic works; nothing new |

The boundary rule, stated once: **if a user would edit it in a document editor, it is notation; if a user would
see it in a table or a total, it is a row.** A rate table with twelve rows is notation. A journal with twelve
thousand is not.

Cross-tier references go one way and use stable identity. A DB row that names a notation object — a posting →
its account in the chart of accounts, an import → the Data schema it used — stores the **`ObjectStableId`**,
not the `ObjectLocation`: the location is rename-mutable, the stable id survives (`ObjectStableMapper`, kzen-lib
`docs/architecture.md` § Stable identity). The mapper's accepted limitation — single linear notation history — is
the same limitation the ledger inherits, which is acceptable for a single-user desktop.

## 4. Engine choice

The server is JVM-only (Ktor); the JS frontend never touches the database, so the choice is purely a JVM
question, and the distribution constraint (§ 8) is "ships inside `main.jar` + `dependencies/` and runs wherever
the bundled JDK runs".

| Engine | Verdict |
|---|---|
| **SQLite via `org.xerial:sqlite-jdbc`** — **recommended** | Single file per project; native libraries for Windows / Linux / macOS on x64 and aarch64 travel inside the jar, extracted at runtime; no install; WAL mode; single-writer is exactly the single-user desktop profile. Accountants and auditors can open the file with off-the-shelf tools. Backup is a file copy (`VACUUM INTO` for a consistent one) |
| H2 (embedded) | Pure Java — the fallback if native extraction ever bites on an exotic platform. Weaker external tooling; a history of breaking on-disk format changes across major versions, which matters for records that must open in seven years |
| DuckDB | Columnar / analytical. Wrong for OLTP ledger writes, but a strong *second* engine later for reporting directly over CSV / Parquet exports (it reads them natively). Larger natives. Not for the first cut |
| PostgreSQL (embedded-postgres or external) | Multi-user hosting only. Spawns a platform-specific server process; contradicts the one-process-per-project model (§ 5.4) |

Two engine-level decisions that a tax app cannot defer:

- **Money is not `REAL`.** SQLite has no `DECIMAL`. Store amounts as **integer minor units** (cents) with the
  currency's exponent, or as decimal text; never as a floating-point column. On the Kotlin side, `BigDecimal` at
  the boundary. This aligns with the structural-data proposal's parameterized decimal `ScalarKind`
  (precision / scale) when DB rows become a reader (§ 6).
- **Dates are ISO text in the ledger's fiscal timezone.** `kotlinx-datetime` `LocalDate` → `yyyy-mm-dd`; no
  instants for posting dates. Pin it before the first row lands — retrofitting is a data migration.

## 5. Integration — the seams that exist, and the two that do not

### 5.1 Ownership: the context owns the connection, graph objects borrow it

Every relevant rule already points the same way:

- `GraphInstanceCache`'s reuse contract is "stateless objects" (extension-points § 3).
- A data source **borrows, never owns** a resource (job-data-source § 4; D4).
- `KzenAutoContext` is the composition root that owns every long-lived service and closes them in `close()`.

So the connection pool (for SQLite: a single writer connection plus a small reader pool, or one serialized
connection — measure) is a **context-owned service**, registered into `GraphEnvironment`, and reached by
graph-instantiated objects through `@Service` constructor parameters. A `LedgerRepository` (typed access) is the
thing registered; raw `DataSource` / `Connection` never appears in a step's constructor. The DB is opened at
context init and closed in `close()`; `kzenAutoInit` already installs the shutdown hook that calls it.

Design-time access (the UI browsing a ledger table, previewing an import) runs through detached actions, which
go through `GraphInstanceCache` — statelessly. For a context-owned pool that is fine today (borrow from the
service, return). When the `DesignSession` from extension-points § 3 arrives, the pool becomes one of its
borrowable resources with `onSessionClose` policy, and nothing in the ledger code changes — same borrow-not-own
seam.

### 5.2 Reads from Jobs and Reports — the first provider-bound source

The data-source arc deliberately left three hooks open for "the first JDBC-style source": a minted
`DataSourceId` on the source's notation (DS O15), provider-bound content access (ST18), and design-time
resource lifetime (DS O12). A `LedgerSource` / `LedgerQuerySource` is that source. It implements `DataSource`
(resolve: a query with bind parameters → one `DataUnit`) and, as job-data-source § 4 anticipates, the opener
on the same object, because a query result cannot be read without its provider. Its shape is declared from the
query's column metadata, which is exactly the typed `Record` of scalar `Field`s the structural-data proposal
wants and today's `DataShape.Tabular(HeaderListing)` cannot express — so this source is also the concrete
consumer that justifies structural-data Half 1 (typed flat).

Writes go the other direction through ordinary Workers / steps that call the repository. Nothing in Job needs to
know it is writing to a database; a `PostJournalEntry` step is a step.

### 5.3 Writes are append-only, and that is a feature

A double-entry ledger is naturally event-sourced: postings are immutable, corrections are reversing entries,
period close is a marker not a mutation. Model the schema that way from the start — `journal_entry` /
`posting` insert-only, balances as views or materialized per period — rather than an updatable "balance"
column. It matches kzen's CQRS temperament (state is never edited in place), it is what a tax audit trail
requires, and it makes the "what did the books say on filing date" question a query rather than a backup
restore.

The one place *not* to route writes: `NotationCommand`. Business writes are DB transactions with their own
atomicity; the notation event log is for configuration. Do not invent a `LedgerCommand` that mirrors the notation
reducer — the two histories have different owners, granularities and consumers.

### 5.4 One project, one process, one file

Each kzen-auto JVM process owns exactly one `KzenAutoContext` and knows nothing of multiple projects; the project
layer is kzen-launcher / kzen-shell. So: **one DB file per project**, under the project's directory beneath
`project.home` (the launcher's `--project.home`), beside its `notation/main/`. "Your books are this folder" is
then literally true — copy the folder to back up, zip it to hand to an accountant. Two fiscal entities are two
projects.

### 5.5 Seam that does not exist: contributing services to `GraphEnvironment`

`KzenAutoContext` builds `graphEnvironment` as a fixed `GraphEnvironment.builder()` chain inside its own
constructor, and `kzenAutoInit(args, jsModuleName, buildInfo)` takes no service contributions. A downstream app
(the kzen-project pattern — `KzenProjectMain` delegates to `kzenAutoInit` + `kzenAutoMain`) therefore has **no
way to register a `@Service` type today**, and `ServiceEnvironmentValidation.validate` would fail the boot the
moment a project-owned `@Reflect` step declared `@Service private val ledger: LedgerRepository`.

This is the first kzen-auto change the app needs: a contribution hook on `kzenAutoInit` / `KzenAutoContext.create`
(a `(GraphEnvironment.Builder) -> Unit`, or a list of `ServiceContribution`s), applied before `build()` and before
validation. Note the existing construction-cycle rule — nothing may resolve the environment during
`KzenAutoContext` construction — so contributed services that need context members must register as memoized
providers, the way `logicTrace` and `serverLogicController` do. The lifetime half (close on `context.close()`)
needs a matching hook, or the contribution registers a `Closeable`.

### 5.6 Seam that half-exists: REST routes and the UI

`ktorMain(context)` is a public `Application` extension with a fixed `routing {}` block; `kzenAutoMain` wraps it
in `embeddedServer`. A downstream app can bypass `kzenAutoMain` and call `embeddedServer { ktorMain(context);
routing { /* ledger routes */ } }` itself — workable without a kzen-auto change, at the cost of duplicating
`kzenAutoMain`'s small body. The reverse-proxy contract (`/<process-name>/<subpath>`, kzen-shell) is unaffected
as long as the routes are served relative to the process root like everything else.

The UI is the larger gap, and it is the gap extension-points § 2 already scoped: a ledger table, an invoice form
and a reconciliation view are not `DetachedAction` cards. The decided ladder there — generic editors + a standard
detached query protocol, then server-described forms, then Web Components as the escape hatch — is what a
first-party tax UI would climb; a dedicated document type in `kzen-auto-js` (`objects/document/<type>/`, § 7 of
kzen-auto `docs/architecture.md`) is the alternative if the app is built *in* the umbrella rather than as a
downstream consumer. This document does not choose; it only records that **the database is the easy half — the
first real cost of a domain app on kzen is its UI**, and that cost is already on the books elsewhere.

### 5.7 Bundled notation nesting

A downstream app's archetype notation must live under `auto-common/`, `auto-jvm/` or `auto-js/` (the
`AutoConventions.serverAllowed` / `clientUiAllowed` fixed sets — kzen-project `AGENTS.md`); a `tax-*` nesting
would need a kzen-auto change. Object names are graph-global, so prefix them. Both constraints are known EXT
candidates, not new findings.

## 6. Access layer

| Option | Fit |
|---|---|
| **SQLDelight** — recommended | Schema-as-source `.sq` files, generated typed Kotlin, `.sqm` migrations, SQLite-first; the closest cultural match to kzen's KSP-generated, no-magic style. Cost: one more Gradle plugin in a build already delicate around KMP and the composite; the JVM driver wraps `sqlite-jdbc` anyway |
| Exposed | Lighter touch, DSL + DAO, SQLite dialect supported; less compile-time checking of the SQL itself |
| jOOQ | Best SQL typing and reporting-query ergonomics; codegen from a live schema; free for SQLite / H2 |
| Plain JDBC + kotlinx-serialization models | Adequate for a spike; do not let it become the product |

Migrations are a first-class deliverable regardless of layer — records outlive versions. Version the schema in
a `schema_version` table, run migrations at context init before the environment is validated, and refuse to open
a file whose version is newer than the code (the launcher's per-project process model means an old build can be
pointed at a new project folder).

## 7. What the structural-data proposal gets from this

Structural data lists "DB rows" as a format and reserves `ScalarKind` decimal precision / scale and temporal
kinds. A `LedgerSource` gives that proposal its first source whose schema is *declared by the provider* (column
metadata) rather than inferred or user-authored — the `declared`-provenance case of ST6 with a supplier that is
neither a Data schema document nor a file header. It also gives ST18 (provider content access) a consumer that
needs neither sequential bytes nor range / seek, only typed rows — which argues that the provider capability
set should include a `rows` capability beside `sequential` and `range`, rather than forcing a cursor through a
byte stream. Recorded here as input to that document; not decided here.

## 8. Cross-platform distribution

What exists: `:kzen-shell:distWindows` (jars + bundled Temurin JDK + `.bat` launchers, the turnkey Windows zip)
and `:kzen-shell:distJars` (jars only, any OS with a JDK ≥ toolchain). What is planned
([`../plans/2026-07-25_desktop-and-hosting.md`](../plans/2026-07-25_desktop-and-hosting.md)): jpackage Windows
installer with a jlink-trimmed runtime (DA3), Linux deb / rpm (DA4), macOS parked until a mac user appears (DA6);
jpackage does not cross-compile, so each platform builds on its own host. A domain app rides that pipeline as a
project archetype zip (`kzen-<app>-<v>.zip`, the `main.jar` + `dependencies/` contract) pulled by the launcher —
the same path kzen-project already takes.

SQLite changes none of that surface. Three operational notes:

- **Native extraction directory.** `sqlite-jdbc` extracts its native library to `java.io.tmpdir` unless
  `org.sqlite.tmpdir` is set. Point it at a managed storage area under the project's work directory: it keeps the
  extraction accountable, and it avoids the occasional Windows anti-virus complaint about a DLL appearing in
  `%TEMP%`. (`org.sqlite.lib.path` / `org.sqlite.lib.name` are the alternative for a pre-placed library, which
  jpackage could do — not needed for v1.)
- **jlink module set.** When DA3 trims the runtime, `java.sql` must be in the module list. Trivial, but a trimmed
  image that omits it fails at first connection, not at build time.
- **Per-platform natives are already in the jar.** No platform-specific dependency declaration; the Linux and
  mac bundles pick up the right library at runtime. H2 would remove even that, at the cost in § 4.

## 9. Decisions register

Open unless stated. Numbered `BS*`.

| # | Question | Current thinking |
|---|---|---|
| BS1 | Where business records live | **Adopt:** embedded relational DB, one file per project under `project.home`, beside `notation/main/` (§ 3, § 5.4) |
| BS2 | Notation / DB boundary | **Adopt:** edited-in-a-document → notation; seen-in-a-table → row. Cross-tier references carry `ObjectStableId` (§ 3) |
| BS3 | Engine | **Adopt SQLite (`sqlite-jdbc`)**; H2 as the recorded pure-Java fallback; DuckDB deferred to a reporting phase (§ 4) |
| BS4 | Money and dates | **Adopt:** integer minor units + currency exponent; ISO `LocalDate` text. No floating point in the schema (§ 4) |
| BS5 | Ownership | **Adopt:** context-owned repository service via `@Service`; graph objects stateless, borrow-not-own; migrates to `DesignSession` unchanged when that lands (§ 5.1) |
| BS6 | Write model | **Adopt:** append-only journal, reversing corrections, period-close markers. Never through `NotationCommand` (§ 5.3) |
| BS7 | Service contribution hook on `kzenAutoInit` / `KzenAutoContext.create` | **Required, not built.** First kzen-auto change the app needs; must respect the no-resolve-during-construction rule and pair with a close hook (§ 5.5) |
| BS8 | REST route contribution | Bypass `kzenAutoMain` and compose `ktorMain` + own routes in the app's `main`; a hook in kzen-auto is nicer but not blocking (§ 5.6) |
| BS9 | UI strategy for ledger / invoice / reconciliation views | Open. Extension-points § 2 ladder for a downstream app, or a first-party document type in kzen-auto-js. The larger cost of the whole endeavour (§ 5.6) |
| BS10 | Access layer | SQLDelight preferred; Exposed if the extra Gradle plugin proves costly in the composite. Migrations and a schema-version guard are mandatory either way (§ 6) |
| BS11 | `LedgerSource` as the first provider-bound `DataSource` | Proposed. Lands DS O12 / O15 and ST18 with a `rows` capability; input to the structural-data document, not decided here (§ 5.2, § 7) |
| BS12 | Native extraction dir and jlink module set | Set `org.sqlite.tmpdir` to a managed area; add `java.sql` when DA3 trims the runtime (§ 8) |

## 10. Build order — proposed

1. **BS7 hook** in kzen-auto (small, independently green, useful to any downstream app).
2. **Schema + repository + migrations** in the app's `-jvm` module, opened at context init, registered as a
   managed storage area; a headless smoke that boots the server on a spare port, posts an entry and reads a
   trial balance.
3. **`LedgerSource`** as a `DataSource`, so existing Job / Report machinery can read the ledger before any bespoke
   UI exists — the first visible payoff, using only cards that already work.
4. **UI** per BS9 — decided separately, after 3 shows what the generic surfaces already cover.
5. **DuckDB reporting** only if aggregate queries over exports outgrow SQLite; not before.

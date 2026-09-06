# HS06 — Early real-day storage and memory gate

> Status: complete 2026-09-05. One implementation session. Prerequisites: HS05; D2 download terms recorded in HS03.
> Read [the arc rules](README.md) before execution. Design authority: Hosting analysis §9 P1 and §5.2.1.

## Outcome and anchors

Sample core benchmark/measurement entry point, durable source/store area.

## Work

1. Download one selected Nasdaq day on demand outside git and job/. Record source/date/fingerprint, machine/JDK, heap limit and storage conditions.
2. Measure sequential decode and store build throughput, disk size and open writer bounds. Select representative and largest partitions from catalog counts; materialize one at a time.
3. Measure native allocation separately from peak heap, retained persistent history, active order-reference state and reconstruction temporaries. Record per-symbol replay and an actual historical query such as depth before trade.
4. Derive documented weight coefficients/headroom from evidence. Check the predicted largest item against the intended budget; exercise explicit oversized failure.
5. Repeat load/query/close enough times to expose native leakage and accumulating retained state. Confirm ordinary runs do not depend on Cleaner to return permits.
6. Adjust the core representation if the measured cost is impractical, and rerun only affected measurements. Record a failed or resource-limited measurement honestly; do not substitute extrapolation for a measured largest-symbol result.

## Verification and exit criteria

P1-early requires reproducible native/heap figures, estimate-versus-observation and an explicit proceed/revise verdict. Preserve only code and concise results; no real feed or giant raw profiling artifacts in git. A resource limitation gates the heavy sample/host proof, while independent generic E work can continue.

## Handoff

Record the chosen day, commands, results and multiplier here. HS21–HS25 use this baseline; P1-final is HS25.

Update this session, the README tracker and its master-ledger row when complete. Stage new files by explicit path; do not commit without a request.

## As-built

Executed 2026-09-05 with `tech.kzen.sample.itch.bench.ItchDayBenchmark` (core only, no kzen, no host). Reports and
the day itself live outside git under `C:\Users\ostro\kzen-data\itch\` (`sources/`, `stores/`, `reports/`).

**Day and conditions.**
- Source: Nasdaq TotalView-ITCH 5.0, **2019-12-30** (`12302019.NASDAQ_ITCH50.gz`, 3 524 013 057 bytes, sha256
  `ef03df46…c689`, fingerprint `3524013057:1788581446385:645ef0f0…ca23`). Downloaded on demand from the public
  `emi.nasdaq.com` sample area (terms recorded in HS03); no md5 is published for this day, so completeness was
  established by a full gzip pass.
- Machine: i7-13700H (20 logical processors), 64 GiB, NVMe; Windows 11; Eclipse Temurin **25.0.4.1**, G1,
  `-Xmx16g`. Commands (run from `kzen-sample-plugin`, after `mvn -o -pl kzen-sample-core compile`):
  ```
  java -Xmx16g -XX:+UseG1GC -cp kzen-sample-core/target/classes tech.kzen.sample.itch.bench.ItchDayBenchmark ^
       C:/Users/ostro/kzen-data/itch/sources/12302019.NASDAQ_ITCH50.gz C:/Users/ostro/kzen-data/itch --repeat=3 --largest=3 --sha256
  ```
  (first run: `reports/2026-09-05_12302019_p1-early.md`, decode pass; second run with `--skip-decode`:
  `reports/2026-09-05_12302019_p1-store.md`, store build and materialization).

**Sequential decode (gzip inflated in-process, single thread).** 268 744 780 messages, highest locate 8 906,
568.3 s → **0.47 M msg/s, 5.9 MiB/s of compressed input**. By type: A 117.1 M, D 114.4 M, U 21.6 M, E 5.7 M,
I 4.0 M, X 2.8 M, F 1.5 M, P 1.2 M, L 215 k, C 100 k, Q 18 k, Y/H/R ≈ 9 k each, S 6, J 34, K 3, V 1.

**Store build.** The first attempt exposed a real defect rather than a measurement: the HS04 builder kept an
LRU of 64 open partition writers, and a real day interleaves ~8 900 locates message by message, so nearly every
append closed and reopened a file — 8.5 h for 5.1 GiB of an eventual 9.9 GiB (≈ 3 k msg/s). Aborted (this
session's own process) and the builder was revised under Work item 6: frames are staged in one in-memory
buffer per partition, flushed on reaching 1 MiB or when the total staged exceeds a **512 MiB budget**
(open-append-write-close per flush). `ItchStoreTest` keeps the identical-partitions check under a 64-byte
budget in place of the old 2-writer bound; the benchmark reports the budget instead of the writer bound. Rebuilt:
**566.0 s (0.47 M msg/s, i.e. decode-bound), 9 920 MiB on disk, 8 907 partitions (8 906 symbols + locate 0
with 10 messages / 291 bytes)**.

**Selected partitions** (from catalog counts): largest QQQ (2 376 743 messages, 90.1 MB of frames), SPY
(2 138 932), IWM (1 940 757); median CEW (6 004).

**Materialization, one day at a time, unlimited budget, 3 repeats each** (retained = live heap after a forced
collection with the day open; peak/allocated from the memory pools and thread allocation counter):

| Symbol | Native MiB (exact) | Estimated heap MiB (HS05 coefficients) | Retained heap MiB | Est/retained | Peak heap MiB | Allocated MiB | Materialize s | Book states | Orders | Peak live | Replay s | Depth-before-trade queries/s | Close ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| QQQ | 104.0 | 1 300.7 | 1 461 | 0.89 | 1 816–2 053 | 2 590 | 4.8–5.8 | 2 373 947 | 1 221 096 | 8 847 | 0.28–0.32 | 0.9–1.5 M | 6–10 |
| SPY | 94.1 | 1 170.2 | 1 259 | 0.93 | 1 636–1 794 | 2 274 | 3.9–4.5 | 2 132 142 | 1 109 146 | 1 949 | 0.27–0.34 | 1.9–2.1 M | 5–9 |
| IWM | 85.0 | 1 063.8 | 973 | 1.09 | 1 375–1 466 | 1 881 | 3.0–3.7 | 1 938 574 | 1 004 648 | 434 | 0.20–0.23 | 1.3–2.1 M | 5–10 |
| CEW | 0.3 | 3.1 | 2.1 | 1.45 | 4.7 | 5.5 | 0.03 | 5 530 | 2 771 | 67 | 0.00 | 0.1–0.2 M | 0.2 |

Every repeat of a symbol reproduced its native bytes, book-state, order and trade counts exactly and its retained
heap within 1 MiB; heap after close returned to ≤ 0.1 MiB each time. Native is exact and small (≈ 44 B/message:
frames plus the 8-byte offset index); the persistent history dominates at ≈ 620 B per book state for the deepest
book, falling to ≈ 530 B for a shallow one (the AVL path copy is O(log peak-live)).

**Process accounting after all 12 loads:** days opened / closed / live 12 / 12 / 0; native allocated / released /
live 891 410 031 / 891 410 031 / 0; release failures 0; leaks detected / reclaimed 0 / 0 — permits and arenas
returned by explicit `close()` on every run, never by the Cleaner. Oversized-day refusal before acquisition and
the blocking-until-a-permit-returns path are exercised deterministically in `SymbolDayTest`
(`oversizedDayFailsBeforeAcquiring`, `budgetBlocksUntilAPermitReturns`).

**Coefficients and headroom (Work item 4).** The HS05 placeholders were 0.89–1.09× the retained heap on the
three largest days; the only under-estimate was the deepest book. `MaterializationWeight.Coefficients.measured`
(now the default in `SymbolDay` and `SymbolDays`) raises `perBookState` 400 → 460 B so the estimate covers QQQ
(1 443 MiB vs 1 461 retained) and errs high elsewhere; `initial` is kept for the record. Reconstruction
temporaries peak at 1.3–1.4× the retained graph, recorded as `Coefficients.transientHeadroom = 1.4`: a host that
must never exceed a fixed heap should keep that fraction free beyond the sum of admitted weights.

**Verdict: proceed.** The largest symbol-day of a heavy real day materializes in ≈ 5 s, holds ≈ 1.5 GiB of
retained heap plus 104 MiB of native, replays in 0.3 s and answers ~1–2 M depth-before-trade queries per second;
the representation is practical on the intended host and within a 16 GiB heap with room for several concurrent
largest days. No measurement was substituted by extrapolation; the one revision (store builder) was rerun in
full. `mvn -o -pl kzen-sample-core test`: 31 tests, 0 failures. No real feed data, stores or raw profiling
artifacts are in git; `bench/ItchDayBenchmark` is the only new source, staged by explicit path.

# Folder notation unification: every directory is an explicit folder entry

## Motivation

Folders are currently represented two different ways depending on their contents:

- **Empty folder** → an explicit `DocumentNotation.folder` scan/notation entry (`main/Foo/`).
- **Non-empty folder** → *no* entry; it's *implied* by the nesting of the documents it contains.

This dual representation is the root of three separate complexities:

1. **`DirectGraphStore.applyInPlace` has a `command is DeleteFolderCommand` externality** — after the generic
   deepest-first delete loop, it calls `notationMedia.deleteFolder(...)` explicitly, because a non-empty folder
   has no notation entry, so its directory is never in `removedDocumentPaths` and the generic loop can't remove it.
2. **`SeededNotationMedia.scanImpl` suppresses folder entries that have nested documents** (the fix for the
   "folder disappears after deleting its last doc" bug) — needed *only* because the client always emitted a
   non-empty folder's entry while the server didn't, so the scans disagreed and `MirroredGraphStore` refreshed the
   folder away.
3. **`FileNotationMedia.scanDocumentModifiedTimes` carries `directoriesWithDocuments` / `markAncestorsWithDocument`
   bookkeeping** purely to decide "is this directory recursively document-empty?" before emitting a folder entry.

**Unification:** give *every* pure-folder directory its own `DocumentNotation.folder` entry, regardless of
contents. Then a folder's existence has a single representation, and all three complexities collapse.

## Why this is robust (the key insight)

The lingering-empty-directory risk that the `DeleteFolderCommand` branch guards against is a **server filesystem**
concern. Once `FileNotationMedia` emits a folder entry for every directory:

- On a `DeleteFolderCommand`, the reducer cascade removes the folder's **own** entry plus every nested entry.
- The folder's own entry is therefore in `removedDocumentPaths`, so the generic deepest-first loop calls
  `delete()` → `deleteDocument(folderPath)`, whose `form == Folder` branch already does a recursive directory
  delete. Deepest-first ordering guarantees the contents are gone before the directory.

The server scan is authoritative for the filesystem, and it now *always* has the folder entry, so the branch is
**dead code**, not something we must preserve. The client has no filesystem, so "lingering directory" is moot
there; its only job is to render the right tree, which the now-symmetric scans + mirror already handle.

`createDocument` needs **no** auto-vivification of ancestor folders: when the server writes a document at a new
deep path, `writeDocument` creates the parent directories, and the **next scan** emits their folder entries (the
mirror is invalidated on write). The UI also always creates a folder before nesting into it, so the optimistic
client notation already has the entry. The invariant ("one directory ⇔ one folder entry") is maintained by scan
authority + existing UI flow, not by new reducer logic.

## Critical edge case: exclude the `main/` root container

Today `main/` is never emitted because it always contains documents (so it lands in `directoriesWithDocuments`).
Dropping that bookkeeping would make `postVisitDirectory` emit `main/` itself as a spurious folder
(`DocumentPath.parse("main/")` → empty nesting, name `main`). **Rule:** only emit a folder entry when the
resulting `DocumentPath.nesting` is **non-empty** — i.e. the directory is strictly below the top-level container.
User folders always live under `main` (nesting `[main, ...]`), so none are excluded; only the top-level container
dir(s) like `main` are. This also fixes the latent empty-project case (an empty `main/` would otherwise emit).

---

## Phase 1 — core unification (achieves the goal) — ✅ IMPLEMENTED 2026-06-16

> Done & verified: kzen-lib `build` green (all targets + tests), published to mavenLocal, kzen-auto JVM+JS
> compile green. A throwaway lifecycle + scan-semantics test (real `FileNotationMedia` over a temp dir) passed
> and was deleted: confirmed per-directory folder entries, non-empty folders now emitted, `main/` excluded,
> empty-folder persistence on doc delete, and cascade delete of a non-empty folder via the generic deepest-first
> loop (no orphan dir, no `DeleteFolderCommand` special-casing). Remaining: user dev-loop smoke test (step 5).

| File | Change |
|------|--------|
| `kzen-lib-jvm/.../server/notation/FileNotationMedia.kt` | In `scanDocumentModifiedTimes`: delete `directoriesWithDocuments` + `markAncestorsWithDocument` and their two call sites. `postVisitDirectory` emits a folder entry for **every** dir it visits (directory-documents are already `SKIP_SUBTREE`'d so they never reach it) **guarded by non-empty nesting** to exclude `main/`. Delete `deleteFolder`/`deleteFolderSynchronized` (redundant with `deleteDocument`'s `Folder` branch). Make `deleteDocumentSynchronized`'s lookup **tolerant for folders** (`locateExisting ?: (invalidate + return)` when `documentPath.folder`) so a cascade can't throw on an already-removed dir. Keep `folderDigest`, the `scanRootIntoCache` folder branch, and `createFolder`. |
| `kzen-lib-common/.../service/media/SeededNotationMedia.kt` | Revert `scanImpl` to emit a `DocumentScan` for every `data` entry (drop the `documentNestings` / `hasNestedDocument` suppression and the `DocumentSegment` import). Now symmetric with the server by construction. |
| `kzen-lib-common/.../service/media/NotationMedia.kt` | Remove the `deleteFolder` default method (no longer called anywhere). |
| `kzen-lib-common/.../service/media/ReadWriteNotationMedia.kt` | Remove the `deleteFolder` override. |
| `kzen-lib-common/.../service/store/DirectGraphStore.kt` | Delete the `if (command is DeleteFolderCommand) notationMedia.deleteFolder(...)` block in `applyInPlace`. Keep the deepest-first sort and the generic delete loop unchanged (it now removes the folder dir via the folder's own entry). |

What stays:
- `CreateFolderCommand` / `DeleteFolderCommand` — `DeleteFolderCommand` is still a real *reducer* distinction
  (cascade delete vs single-document delete). Only its filesystem **externality** is removed.
- `NotationReducer.createFolder` / `deleteFolder` — unchanged. `deleteFolder`'s `check(toRemove.isNotEmpty())`
  now always passes via the folder's own entry.
- `DirectGraphStore.writeIfRequired` folder branch + `createFolder` media method — unchanged (new folders still
  created via the generic write path; unchanged folder entries early-return on `documentNotation == originalDocument`).
- `SidebarModel` inference — left as-is in Phase 1. It's now redundant for non-empty folders but harmless: explicit
  entries and inferred names dedup in the same `linkedSetOf`.

## Phase 2 — client simplification — ✅ IMPLEMENTED 2026-06-16

> Done: kzen-auto JS compiles green. `SidebarModel.buildLevel` now derives child folders only from explicit
> folder entries at the level (drops the deeper-path inference); doc/interface comments updated to the unified
> model. `SidebarFolder.onRemoveFolder` count filters `!path.folder` (documents only) and the dialog reads
> "N document(s)". Remaining: user dev-loop frontend reload + smoke test.

| File | Change |
|------|--------|
| `kzen-auto-js/.../sidebar/SidebarModel.kt` | Simplify `buildLevel`: child folders come **only** from explicit folder entries at this level (`path.folder && path.nesting == nesting`); documents at this level are leaves. Drop the "deeper path implies a child folder" inference branches. Safe because every folder now has an explicit entry post-scan. |

Optional polish also worth a look in Phase 2: `SidebarFolder.onRemoveFolder`'s `nestedCount` now counts nested
*folder* entries as "items" — filter to `!path.folder` if the confirmation count should mean documents only.

---

## Verification

1. **Search for tests asserting the old implied-folder behaviour** (a non-empty folder having *no* scan entry, or
   exact scan-key-set assertions) in `kzen-lib` and `kzen-auto`; update expectations to include the per-directory
   folder entries.
2. `cd ../kzen-lib && ./gradlew build` (all targets + tests) → `publishToMavenLocal` for the three subprojects.
3. `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:classes :kzen-auto-js:compileKotlinJs`.
4. Throwaway lifecycle test (in-memory store + real `FileNotationMedia`), then delete it:
   - create folder → bare `main/Foo/` dir, **no `~main.yaml`**, one folder entry.
   - add a doc inside → `main/Foo/` **and** `main/Foo/doc.yaml` both present in the scan; client & server scan
     digests **agree** (no mirror refresh).
   - delete that doc → folder entry remains, dir persists (empty-folder persistence).
   - nest a folder in a folder → both folder entries present.
   - `DeleteFolderCommand` on a non-empty folder → folder entry in `removedDocumentPaths`, directory + contents
     gone via the **generic** loop (no special branch).
   - confirm `main/` is **never** emitted as a folder.
5. Dev-loop smoke (kzen-auto standalone): create/nest/empty-persist/cascade-delete via the sidebar; confirm no
   "folder reappears / disappears" glitches and the delete leaves no orphaned directory.

## Risks / trade-offs

- **More notation entries** (one per folder directory). Bounded: existing data is flat (`main/X.yaml`) or
  directory-documents (`~main.yaml`, skip-subtree'd), so there are **zero** new entries for current data; new
  entries scale only with actual folder usage, which is inherent to the feature.
- **Consumers iterating `notation.documents`** see more folder entries. Not a new entry *type* (empty folders
  already produced folder entries), just more instances; the key consumers already filter `!folder`
  (`AutoConventions.mainDocuments` callers, `SidebarModel`, `StageController`). Worth a quick grep for any
  consumer that assumes every entry is a document.
- **The `main/` exclusion is load-bearing** — get the non-empty-nesting guard right or every project grows a
  spurious top-level `main` folder.

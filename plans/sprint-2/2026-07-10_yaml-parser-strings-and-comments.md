# YamlParser: relaxed bare strings, first-class comments, `|-` block scalars

> **Status: ✅ DONE 2026-07-18.** Landed W1–W8 in a single session (Opus 4.8 xhigh). Legacy on-disk
> audit came back clean (zero no-space-colon keys across every `*.yaml` under IdeaProjects).
> Verification green: `:kzen-lib-common:jvmTest` + `:kzen-lib-common:jsTest`, publishToMavenLocal,
> `:kzen-auto-jvm:test --refresh-dependencies`. Written 2026-07-10; header brought to house style
> 2026-07-16 during the Sprint-1 consolidation.
> Work items are ordered; design decisions are pre-made (see "Resolved design decisions") — do
> not re-litigate.
>
> Scope: `kzen-lib-common` — `util/yaml/YamlParser.kt`, `util/yaml/YamlNode.kt`, minor
> `service/parse/YamlNotationParser.kt`; tests.
>
> **Progress tracker** (update as items land):
> - [x] W1 — YamlNode `comments` field
> - [x] W2 — Cursor indexes comment lines
> - [x] W3 — escape/unescape split + YAML alignment (`\f` fix, `''` doubling)
> - [x] W4 — map-entry shape fix + rest-of-line bare values (**the core**)
> - [x] W5 — block scalar parse (`|`, `|-`)
> - [x] W6 — comment collection/attachment
> - [x] W7 — unparse (mode precedence, `unparseKey`, regex-free)
> - [x] W8 — tests
> - [x] Legacy on-disk compatibility audit (clean — zero no-space-colon keys on disk)

## Goals

1. **Bare strings, rest-of-line** — `test: C:\~\foo` parses without quoting (StrictYAML-style plain scalars).
2. **Own-line comments modeled in YamlNode** — `# ...` lines attach to the following map entry / list item and round-trip. Foundation for eventual user-facing ad-hoc comments in DocumentNotation (out of scope here).
3. **`|-` literal block scalars** — parse `|` / `|-`; unparse prefers `|-` for multi-line strings (Kotlin code snippets) and single-line strings that would otherwise need escape sequences.
4. **Strict subset of YAML 1.2 on output** — everything unparse emits must be read identically by a standard YAML parser. Parse stays a lenient superset for legacy on-disk docs. String modes: bare, `'single'`, `"double"`, `|-`. (Backtick mode considered and rejected — not standard YAML.)

Non-goals: flow collections (`[a, b]`), anchors/tags, `>` folded scalars, end-of-line comment modeling, comments in AttributeNotation/DocumentNotation (a later project — `NotationReducer`/`unparseDocument` regenerate documents from the notation tree, so comments only survive once they reach that tree).

Companion: `2026-07-16_graph-improvements.md` phase 7b (template-respecting deparse) touches the same `YamlNotationParser.unparseDocument` — land this plan **first**, so the one-time unparse churn precedes 7b's byte-identical object-segment preservation (and 7b's segment-equality check then operates on the new stable format).

## Current state (why these changes)

- `Cursor.of` (YamlParser.kt:96) drops `#` lines from the line index — comments unrepresentable.
- Bare scalars/keys allow only `[0-9a-zA-Z_\-/.]` + interior space (`isBareStartChar`/`isBareMidChar`, :403-409), and bare content is passed through `unescape` (:351), so `\~` throws. `C:\~\foo` first mis-matches as map entry `C:` because `matchBareEntry` (:271) does not require a space after the colon.
- No block-scalar support; `unparseString` (:485) escapes `\n`, so multi-line Kotlin round-trips as an unreadable one-liner.
- Single-quote emit uses `\'`/`\\` backslash escapes (`escape`, :511) — not standard YAML (which uses `''` doubling and literal backslashes). `\f` unescape bug at :450 (decodes `\f` to the six literal characters `\u000C` instead of the form-feed char).
- `unparseMap` has a dead 3-space continuation branch (:595) that goes live with `|-` — must become 2-space.

## Work items (ordered)

### W1. YamlNode: `comments` field

```kotlin
sealed class YamlNode {
    abstract val comments: List<String>
    abstract fun withComments(comments: List<String>): YamlNode
}

data class YamlString(
    val value: String,
    override val comments: List<String> = listOf()
): YamlNode() { ... }
// YamlList / YamlMap: same pattern (trailing param with default + withComments = copy)
```

- Trailing positional param with default — all existing constructions (`YamlString(value)`, kzen-auto `PluginDocument`, `ReportWorkPool`) compile unchanged.
- Comment lines stored without `#` prefix (one following space also stripped); invariant: no `\n`/`\r`.
- Comments participate in data-class equality (no current test compares a parsed tree against a hand-built one with comments — audited).
- `toObject()` and `YamlNotationParser.yamlToAttribute` untouched (read only `value`/`values`).

### W2. Cursor: index comment lines

Delete the `#`-skip at :96 (blank lines stay unindexed). Add `isCommentAt(idx)` and `lineRawStart(idx) = starts[idx] - indents[idx]` helpers. Needed both for comment collection (W6) and because indented `#` lines inside a block scalar are literal content (W5).

### W3. Escape/unescape split + YAML alignment

- `unescapeDouble` = current `unescape` with the `\f` bug fixed (`'f' -> builder.append('\u000C')`). Accepts `\\ \" \/ \' \n \r \t \b \f \uXXXX`; other escapes still throw.
- `unescapeSingle` — new: `''` → `'` (standard YAML doubling) **plus** the legacy backslash-escape table (backward compat: current emitter wrote e.g. `path: '"C:\\~\\data\\measurements-100000.txt"'` — see Job-2.yaml).
- `escape` becomes double-quote-only: `\\ \" \n \r \t \b \f`, `\uXXXX` for chars `< 0x20` / `>= 0x7F` (extends the current `128..0xFFFF` range to cover DEL). `'` emitted plain. NUL still throws.
- `matchQuotedEntry` (:308): for single-quoted keys, treat `''` as an escaped quote (consume both, continue); keep the existing `\\` skip for legacy keys.
- `decodeKey` (:390) dispatches by quote char; bare keys use plain `substring` (charset can't contain `\`, so dropping `unescape` is a no-op).

### W4. Map-entry shape fix + rest-of-line bare values (the core)

**4a.** `matchBareEntry` / `matchQuotedEntry`: after locating the `:`, require space-or-EOL (`j+1 == e || source[j+1] == ' ' || source[j+1] == '\t'`). Per YAML plain-scalar rules this makes `C:\foo` a scalar, not a map entry. Key charset unchanged.

**4b.** `parseMap` value branch (:228-239) no longer routes inline values through `pushSynthetic` + `parseBlock` (which re-runs entry matching and is why `test: a: b` nests today). New: a dedicated `parseInlineValue(valueStart, lineEnd, baseline)`:

- `"` / `'` → `parseQuotedScalar` (existing trailing-comment strip stays)
- `|` → block scalar (W5)
- `[` / `{` → `[]`/`{}` empty markers only (after stripping a trailing ` #` comment); anything else throws (previously silently parsed as junk)
- `& * > % @ `` ` `` → throw "unsupported YAML" (loud instead of junk)
- `-` followed by space → legacy `key: - x` inline-list path via `pushSynthetic` (unchanged semantics)
- `#` as first char (`key: # comment`) → treat as no inline value (comment discarded, consistent with end-of-line comments being unmodeled)
- else → **bare rest-of-line, literal, NO unescape**: cut at the first `#` preceded by space/tab (YAML comment rule — stripped, not modeled), trim trailing spaces/tabs.

So `test: C:\~\foo` → `YamlString("""C:\~\foo""")` (literal chars). `url: https://kzen.tech`, `expr: a + b * 2`, `code: number % 3 == 0` all parse bare.

**4c.** `parseList` keeps `pushSynthetic` + `parseBlock` so compact `- foo: bar` maps still work (entry shape now requires `: `, so `- C:\foo` correctly falls through to scalar). `parseScalarContent` (:344) gets the same dispatch tail as `parseInlineValue` (quoted / `|-` / throw-on-indicator / bare-literal). Standalone nested lines: `a: b` on its own line is still a map (matches YAML); only the inline-after-key position is forced-scalar.

### W5. Block scalar parse (`|`, `|-`)

Indicator line: content after `|` must be empty, `-`, or spaces + `# comment`; else throw. Chomping: STRIP for `|-`, CLIP for `|` (parse both; emit only `|-`).

Body: blank interior lines are significant but not in the line index, so the body is built by a char scan of the **raw document slice** between the end of the indicator line and `lineRawStart(endIdx)` of the first indexed line with `indent < blockIndent` (or EOF). `blockIndent` = indent of the first indexed body line (first-non-empty-line rule); must be ≥ `bodyMinIndent` (= entry baseline + 2 for `key: |-`; list/standalone cases analogous). Per line: blank → `""`; else drop `blockIndent` leading spaces, keep the rest verbatim (indented `#` lines, deeper indents, interior blanks all literal — this is why W2 must index `#` lines). Join with `\n`, drop trailing newlines, CLIP appends one back.

### W6. Comment collection/attachment

All in the recursive descent (synthetic lines are never comments):

- `firstNonCommentIdx()` — non-consuming lookahead past a comment run; `drainCommentRun()` — consume it, returning stripped texts (`"# foo"`→`foo`, `"#foo"`→`foo`, `"####"`→`"###"`).
- `parseMap`/`parseList` loop heads: if the current line is a comment, look ahead — continue the loop only if the next non-comment line is at the same baseline and matches the entry/item shape; then drain and attach: `value.withComments(comments + value.comments)`. If the lookahead fails, `break` **without draining** — a dedented outer loop picks the same run up and attaches it to *its* next entry (so a comment between a nested block and the next top-level entry attaches outward, correctly).
- `parseBlock`: dispatch on the first non-comment line; scalar path drains and attaches.
- Comment indent is ignored on parse (lenient); re-emit normalizes to the entry's indent.
- **Trailing comments at end of block/document: discarded** (v1 limitation; kzen rewrites already drop all comments today, so nothing regresses).

### W7. Unparse

**`unparseString` mode selection** (values; precedence = cleanest first):

```
1. empty                      -> ""
2. isBareValue(v)             -> v
3. isSingleQuotable(v)        -> 'v'
4. isBlockRepresentable(v) && (v has '\n' || v has '\\' || v has '"')
                              -> |- block, body indented 2 (blank lines emit empty, no trailing spaces)
5. else                       -> "escaped"

isBareValue: non-empty; first char not in ,[]{}#&*!|>'"%@` nor space/tab;
  not ("-"|"?"|":") followed-by-space-or-alone (keeps -5 bare); all chars printable
  ASCII 0x20..0x7E; no trailing space; no ": "; doesn't end with ':'; no " #"
isSingleQuotable: no '\'', no '\\', all printable ASCII
  (emitted text then reads identically under YAML and legacy kzen rules)
isBlockRepresentable: non-empty; chars are '\n' or printable ASCII; no leading '\n' or ' ';
  no trailing '\n' (those fall to double-quoted — |- strips); no line with trailing whitespace
```

Step 4's single-line clause: reaching it means the value has `\` or both quote kinds — exactly when double-quoting needs escapes but `|-` is clean. E.g. the Job-2.yaml value `"C:\~\data\measurements-100000.txt"` (a quoted Kotlin string literal) becomes:

```yaml
path: |-
  "C:\~\data\measurements-100000.txt"
```

**`unparseKey`** — new: keys must re-lex via `matchMapEntryShape`, so bare keys keep the old restricted shape (char-loop replacement for the `Patterns.bareString` regex, which is then deleted — parser becomes fully regex-free); else `'...'` if single-quotable, else `"..."`. Used by `unparseMap` and by `YamlNotationParser.unparseDocument` (:123).

**Containers/comments**: split `unparse` into comment emission (`# text` lines at the node's indent, `####` banners preserved verbatim) + `unparseValue` dispatch; `unparseMap`/`unparseList` emit each child's comments before the entry/item line. Fix continuation indents: `unparseList` (:574) and `unparseMap` (:595, 3-space → 2-space) must skip indenting empty lines (blank `|-` body lines must not gain trailing spaces); same one-line guard in `YamlNotationParser.unparseDocument` (:126).

### W8. Tests

Existing to update (only 3, all in `YamlUnparseTest`): `stringWithDoubleQuote`, `stringWithSingleQuote`, `stringWithSingleAndDouble` — those values now emit bare (`foo"bar"` is a valid plain scalar). Everything else in `YamlParseTest` / `YamlUnparseTest` / `YamlNotationParserTest` passes unchanged (audited case-by-case, incl. `singleQuotedMapKey`'s legacy `\'` key).

New coverage:
- Parse: `C:\~\foo` bare; ` # comment` stripping in bare values; `key:value` (no space) → scalar; `key: a: b` → scalar `a: b`; `''` doubling (values + keys); legacy `\'`/`\\` single-quote escapes; `\f` fix; `|`/`|-` (blank interior lines, `#` body lines, deeper-indented lines, `- |-` items, empty body, chomp modes, CRLF, EOF without newline).
- Comments: attach to map entry / list item / nested entry; dedent boundary attaches outward; banner (`####`) text preserved; trailing comments discarded; `key: # c`.
- Unparse: mode-precedence table; `isBareValue` boundaries (`: `, trailing `:`, ` #`, leading `- `, `-5`, non-ASCII); keys stay restricted (`C:\foo` key → quoted); `|-` blank-line bodies have no trailing whitespace; comment re-emission.
- Round-trip: `parse(unparse(node)) == node` over a corpus (Windows paths, multi-line Kotlin with quotes+backslashes, `true`/`42`/`null`, unicode, form feed, tabs, trailing-newline strings) and commented trees; legacy-fixture tests copied from real notation docs (Job-2.yaml, common-action.yaml).

## Legacy on-disk compatibility

Every form the current emitter produces parses to identical values: old-regex bare strings (charset makes `unescape` a no-op → literal is identical); `key: ` always has the space; single/double-quoted with backslash escapes (legacy branch retained); `[]`/`{}`. Deliberate changes: `\f` now round-trips correctly (was broken); hand-written `key:value` (no space) becomes a scalar — top-level occurrences would now fail "Sub-map expected" in `parseDocumentObjects`, so **audit the notation corpora before landing** (grep `*/resources/notation/**` and user project dirs for no-space-colon lines); hand-written bare backslash values (previously threw or mis-nested) now parse literally — the point of the change. Unparse output churn is expected (values previously quoted now emit bare/`|-`) — values unchanged, files rewritten by kzen will diff once.

## Resolved design decisions

1. Bare `42`/`true`/`null` keep emitting bare — kzen stores all scalars as strings and is the only consumer; identical under YAML's failsafe schema.
2. Trailing block/document comments discarded in v1.
3. `|-` only on emit (never `|`); trailing-`\n` values go double-quoted.
4. Bare/single/`|-` emit restricted to printable ASCII; non-ASCII stays `\uXXXX` in double quotes (status-quo conservatism; one-line predicate change to loosen later).
5. Backslash-in-single-quotes stays a *parse-only* legacy escape; the new emitter never produces it, so the deviation is self-extinguishing.

## Verification

`cd ../kzen-lib && ./gradlew :kzen-lib-common:jvmTest` (with `JAVA_HOME=~/.jdks/temurin-25.0.3`), then the full kzen-lib build, then `cd ../kzen-auto && ./gradlew :kzen-auto-jvm:test` (notation-heavy consumer). Manual: boot a dev backend and open an existing project to confirm on-disk documents still load; edit an object and confirm the rewritten YAML is standard-YAML-valid (spot-check with any YAML 1.2 parser).

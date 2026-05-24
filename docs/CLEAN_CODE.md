# Clean code guide

These are common mistake patterns made by AI.
Before finalizing a code change, please review it against these common pitfalls.


## Magic constant

Spell out the logical meaning of constants.

For example, don't do this:
```kotlin
    delay(500)
```

Instead, pull out the constant and make the meaning of it obvious by the name:
```kotlin
    val statusRefreshMillis = 500
    // ...
    delay(statusRefreshMillis)
```


## Scalability of code

The amount/nesting/complexity of code should be linear with the amount of functionality.

For example, if you need to add buttons to a header, don't do something like this:
```kotlin
headerWrapper2 {
    headerWrapper1 {
        header(
            headerExtra = {
                button1()
                button2()
            }
        ) {}
    }
}
```

With this type of wrapping style, if we need to add more and more icons, we will need to nest deeper and deeper, each time creating a new wrapper.
The total source code size will scale quadratically, but we always need it to be linear (additive):
```kotlin
header(
    headerExtra = { headerBuilder: ChildrenBuilder ->
        with (headerBuilder) {
            button1()
            button2()
        }
    }
) {}
```

In the above example, as we add more icons to the header, each addition will be a single line of code.


## Coherence of related concepts

Think about what it is what it would take to remove a feature.
If the code is perfectly factored, then this should be a single action (delete one file or one package tree).
It's ok if there is a little bit of supporting code in other places, but this is what you should strive for.

Code should either be general, or belong to a single particular feature, never both or more.
For example, if a screen has 4 sections, the screen itself should just delegate to the logic that is defined in the individual subsections.
The common code should never have explicit handling of special cases related to any one particular feature in the general code paths.


## Files in a package

Keep packages focused and small, hierarchically breaking down functionality.

Ideally there should be just a few files per package, 10 is a lot.
Try to split up into small related chunks, for example:
```
src/pages/<page-name>/
  server.ts
  browser_logic.ts
  browser_template.html
  shared.ts
```

When there are 10 or more files in a package, that's an indicator that it should be refactored (or a TODO added).
Packages should typically contain more than one file (ie. a single file package is anemic), but is acceptable in particular situations.


## Drive-by refactoring and cleanup

Don't incidentally delete commented out code and similar stuff, call it out as a separate follow-up item.
For example, maybe the code was there for debugging and it was commented out with the intention of using it again soon.
You can bring it up either in discussion or as part of the active plan; refactorings should be opt-in, not opt-out.


## Fail-fast on unexpected code paths

Make the code strict, it should fail early and loudly.
Don't handle nulls when a value being null would indicate a logic error.

For example, don't do this:
```kotlin
val failsafeInput = requiredInputValue ?: ""
```

Instead, make it an explicit assertion or throw an exception:
```kotlin
val failsafeInput = requiredInputValue
    ?: error("Required input missing")
```

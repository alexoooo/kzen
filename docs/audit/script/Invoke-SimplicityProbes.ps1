param(
    [Parameter(Mandatory = $true)]
    [string] $JavaHome
)

$ErrorActionPreference = 'Stop'
$auditRoot = Split-Path -Parent $PSScriptRoot
$umbrellaRoot = Split-Path -Parent (Split-Path -Parent $auditRoot)
$siblingsRoot = Split-Path -Parent $umbrellaRoot
$libRoot = Join-Path $siblingsRoot 'kzen-lib'
$autoRoot = Join-Path $siblingsRoot 'kzen-auto'
$dependencies = Join-Path $autoRoot 'kzen-auto-jvm/build/libs/dependencies'
$java = Join-Path $JavaHome 'bin/java.exe'
$libJar = Get-ChildItem (Join-Path $libRoot 'kzen-lib-common/build/libs') -Filter '*-jvm-*.jar' |
    Where-Object Name -NotLike '*-sources.jar' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$autoJar = Get-ChildItem (Join-Path $autoRoot 'kzen-auto-jvm/build/libs') -Filter '*-jvm-*.jar' |
    Where-Object Name -NotLike '*-sources.jar' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $libJar -or -not $autoJar -or -not (Test-Path $java) -or
    -not (Get-ChildItem $dependencies -Filter 'kotlin-compiler-embeddable-*.jar')) {
    throw 'Requires a Java 25+ installation and existing kzen-lib-common JVM / kzen-auto JVM build artifacts.'
}

$rawRoot = Join-Path $auditRoot 'raw'
$createdRawRoot = -not (Test-Path -LiteralPath $rawRoot)
$scratch = Join-Path $rawRoot ('simplicity-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $source = Join-Path $scratch 'SimplicityProbes.kt'
    @'
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import tech.kzen.auto.client.service.rest.RemoteApplyGate
import tech.kzen.lib.common.model.document.DocumentPath
import tech.kzen.lib.common.model.location.ObjectLocation
import tech.kzen.lib.common.model.obj.ObjectName
import tech.kzen.lib.common.model.obj.ObjectPath
import tech.kzen.lib.common.model.structure.notation.DocumentObjectNotation
import tech.kzen.lib.common.model.structure.notation.cqrs.*
import tech.kzen.lib.common.service.context.GraphDefiner
import tech.kzen.lib.common.service.media.MapNotationMedia
import tech.kzen.lib.common.service.metadata.NotationMetadataReader
import tech.kzen.lib.common.service.notation.NotationReducer
import tech.kzen.lib.common.service.parse.YamlNotationParser
import tech.kzen.lib.common.service.store.*
import tech.kzen.lib.common.service.store.normal.ObjectStableMapper
import tech.kzen.lib.common.util.digest.Digest
import tech.kzen.auto.server.service.compile.*
import tech.kzen.auto.server.util.WorkUtils
import java.nio.file.Files
import java.nio.file.Path

fun main(args: Array<String>) = runBlocking {
    val mapper = ObjectStableMapper()
    val original = ObjectLocation(DocumentPath.parse("audit.yaml"), ObjectPath.parse("A"))
    val renamed = ObjectLocation(DocumentPath.parse("audit.yaml"), ObjectPath.parse("B"))
    val firstId = mapper.objectStableId(original)
    mapper.apply(RenamedObjectEvent(original, ObjectName("B")))
    val secondId = mapper.objectStableId(original)
    println("IDENTITY: distinct objects share id=${firstId == secondId}; " +
        "renamed reverse lookup correct=${mapper.objectLocation(mapper.objectStableId(renamed)) == renamed}")

    val localMedia = MapNotationMedia()
    val localStore = DirectGraphStore(localMedia, YamlNotationParser(), NotationMetadataReader(),
        GraphDefiner, NotationReducer())
    val remote = object : RemoteGraphStore {
        override suspend fun apply(command: NotationCommand): Digest {
            delay(20)
            error("Simulated rejected write")
        }
    }
    val mirror = MirroredGraphStore(localStore, remote)
    val document = DocumentPath.parse("rejected.yaml")
    val result = mirror.apply(CreateDocumentCommand(document, DocumentObjectNotation.empty))
    println("MIRROR: returned error=${result is MirroredGraphError}; " +
        "rejected document remains local=${localMedia.containsDocument(document)}")

    val gate = RemoteApplyGate()
    var secondCallbackRan = false
    gate.begin()
    gate.whenSettled { error("Simulated subscriber failure") }
    gate.whenSettled { secondCallbackRan = true }
    val callbackErrorEscaped = runCatching { gate.end() }.isFailure
    gate.begin()
    gate.end()
    println("GATE: callback error escaped=$callbackErrorEscaped; " +
        "second callback ever ran=$secondCallbackRan")

    val work = WorkUtils(Path.of(args.single()).resolve("compiler-work"))
    val code = KotlinCode("Probe", "class Probe")
    val oldCompiler = object : KotlinCompiler {
        override fun compile(kotlinCode: KotlinCode, outputJarFile: Path, classpathLocations: List<Path>, classLoader: ClassLoader): KotlinCompilerResult {
            Files.createDirectories(outputJarFile.parent)
            return KotlinCompilerError("Missing plugin in old universe")
        }
    }
    val loader = ObjectStableMapper::class.java.classLoader
    CachedKotlinCompiler(oldCompiler, work).tryCompile(code, loader)
    var newCompilerCalled = false
    val newCompiler = object : KotlinCompiler {
        override fun compile(kotlinCode: KotlinCode, outputJarFile: Path, classpathLocations: List<Path>, classLoader: ClassLoader): KotlinCompilerResult {
            newCompilerCalled = true
            return KotlinCompilerSuccess(outputJarFile, "")
        }
    }
    val cachedError = CachedKotlinCompiler(newCompiler, work).tryCompile(code, loader)
    println("COMPILER CACHE: new compiler called=$newCompilerCalled; " +
        "old error reused=${cachedError?.error == "Missing plugin in old universe"}")
}
'@ | Set-Content -LiteralPath $source -Encoding utf8

    $compileDependencies = Get-ChildItem $dependencies -Filter '*.jar'
    $compileClasspath = (@($libJar.FullName, $autoJar.FullName) + @($compileDependencies.FullName)) -join ';'
    $classes = Join-Path $scratch 'classes'
    $mapper = Join-Path $libRoot 'kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/store/normal/ObjectStableMapper.kt'
    $mirror = Join-Path $libRoot 'kzen-lib-common/src/commonMain/kotlin/tech/kzen/lib/common/service/store/MirroredGraphStore.kt'
    $gate = Join-Path $autoRoot 'kzen-auto-js/src/jsMain/kotlin/tech/kzen/auto/client/service/rest/RemoteApplyGate.kt'
    $compiler = Join-Path $autoRoot 'kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/compile/CachedKotlinCompiler.kt'
    $code = Join-Path $autoRoot 'kzen-auto-jvm/src/main/kotlin/tech/kzen/auto/server/service/compile/KotlinCode.kt'
    # Compile subjects from current source; supporting types come from existing artifacts.
    # An argument file keeps the dependency classpath below Windows' command-line limit.
    $compilerArguments = @('-no-stdlib', '-no-reflect', '-jvm-target', '25', '-classpath', $compileClasspath,
        '-d', $classes, $source, $mapper, $mirror, $gate, $compiler, $code)
    $argumentFile = Join-Path $scratch 'compiler.args'
    $compilerArguments | ForEach-Object { '"' + $_.Replace('\', '/') + '"' } |
        Set-Content -LiteralPath $argumentFile -Encoding utf8NoBOM
    & $java '-cp' "$dependencies/*" 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler' "@$argumentFile"
    if ($LASTEXITCODE -ne 0) { throw "Probe compilation failed: $LASTEXITCODE" }
    & $java '-cp' "$classes;$($libJar.FullName);$($autoJar.FullName);$dependencies/*" 'SimplicityProbesKt' $scratch
    if ($LASTEXITCODE -ne 0) { throw "Probe execution failed: $LASTEXITCODE" }
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $expectedParent = [IO.Path]::GetFullPath($rawRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedScratch.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Scratch path escaped audit raw directory: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    if ($createdRawRoot -and -not (Get-ChildItem -LiteralPath $rawRoot -Force)) {
        Remove-Item -LiteralPath $rawRoot
    }
}

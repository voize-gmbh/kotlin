/*
 * Copyright 2010-2024 JetBrains s.r.o. and Kotlin Programming Language contributors.
 * Use of this source code is governed by the Apache 2.0 license that can be found in the license/LICENSE.txt file.
 */

package org.jetbrains.kotlin.nativeDistribution

import bootstrapKotlinVersion
import org.gradle.api.Project
import org.gradle.api.file.*
import org.gradle.api.provider.Provider
import org.gradle.api.tasks.Sync
import org.gradle.kotlin.dsl.named
import org.gradle.kotlin.dsl.register
import org.jetbrains.kotlin.PlatformInfo
import org.jetbrains.kotlin.cacheFlavor
import org.jetbrains.kotlin.konan.util.ArchiveType.TAR_GZ
import org.jetbrains.kotlin.konan.util.ArchiveType.ZIP
import org.jetbrains.kotlin.kotlinNativeDist
import java.io.File
import java.security.MessageDigest
import kotlin.io.path.inputStream

/**
 * Describes distribution of Native compiler rooted at [root].
 */
// TODO: Make an inline class after groovy buildscripts are gone.
class NativeDistribution(val root: Directory) {
    /**
     * Directory with compiler jars.
     *
     * @see compilerClasspath
     */
    val compilerJars: Directory
        get() = root.dir("konan/lib")

    /**
     * Directory with CLI tools.
     *
     * @see cinterop
     */
    val bin: Directory
        get() = root.dir("bin")

    /**
     * Directory with libraries for the compiler itself (e.g. bridges for LLVM bindings).
     */
    val nativeLibs: Directory
        get() = root.dir("konan/nativelib")

    /**
     * Root directory for compiler caches.
     *
     * @see cache
     * @see stdlibCache
     */
    val cachesRoot: Directory
        get() = root.dir("klib/cache")

    /**
     * Root directory for compiler acaches for the specific [target].
     */
    fun cachesRoot(target: String, withOptimizations: Boolean): Directory =
            cachesRoot.dir(cacheFlavor(target, withOptimizations))

    /**
     * Directory with distribution sources.
     *
     * @see stdlibSources
     */
    val sources: Directory
        get() = root.dir("sources")

    /**
     * Directory with .def files for platform libs.
     */
    val platformLibsDefinitions: Directory
        get() = root.dir("konan/platformDef")

    /**
     * Directory with misc tools.
     */
    val tools: Directory
        get() = root.dir("tools")

    /**
     * Directory with Swift Export support.
     */
    val swiftExport: Directory
        get() = root.dir("konan/swift_export")

    /**
     * Directory with all platform libs KLIBs for a specific [target].
     */
    fun platformLibs(target: String): Directory = root.dir("klib/platform/$target")

    /**
     * Classpath in which it's possible to run K/N compiler.
     */
    val compilerClasspath: FileCollection
        get() = compilerJars.asFileTree.matching {
            include("kotlin-native-compiler-embeddable.jar")
        }

    /**
     * Additional platform configuration.
     */
    val konanPlatforms: Directory
        get() = root.dir("konan/platforms")

    /**
     * `konan.properties` file with targets and dependencies descriptions.
     */
    val konanProperties: RegularFile
        get() = root.file("konan/konan.properties")

    private fun bin(tool: String) = if (PlatformInfo.isWindows()) bin.file("$tool.bat") else bin.file(tool)

    /**
     * `run_konan` command line executable.
     */
    val runKonan: RegularFile
        get() = bin("run_konan")

    /**
     * `cinterop` command line executable.
     */
    val cinterop: RegularFile
        get() = bin("cinterop")

    /**
     * `klib` command line executable.
     */
    val klib: RegularFile
        get() = bin("klib")

    /**
     * Runtime files for a specific [target].
     */
    fun runtime(target: String): Directory = root.dir("konan/targets/$target/native")

    /**
     * Platform library [name] klib for a specific [target].
     */
    fun platformLib(name: String, target: String): Directory = platformLibs(target).dir(name)

    /**
     * Static compiler cache of library [name] for a specific [target].
     */
    fun cache(name: String, target: String, perFile: Boolean, withOptimizations: Boolean): Directory =
            cachesRoot(target, withOptimizations).dir(cacheDirectoryName(name, perFile))

    /**
     * Archive with stdlib sources.
     */
    val stdlibSources: RegularFile
        get() = sources.file("kotlin-stdlib-native-sources.zip")

    /**
     * Standard library klib.
     */
    val stdlib: Directory
        get() = root.dir("klib/common/stdlib")

    /**
     * Static compiler cache of standard library for a specific [target].
     */
    fun stdlibCache(target: String, withOptimizations: Boolean): Directory = cache("stdlib", target, perFile = true, withOptimizations)

    /**
     * Fingerprint of the contents of [compilerJars] and [nativeLibs].
     */
    val compilerFingerprint: RegularFile
        get() = root.file("konan/compiler.fingerprint")

    /**
     * Fingerprint of the contents of the entire distribution.
     */
    val distributionFingerprint: RegularFile
        get() = root.file("distribution.fingerprint")

    /**
     * Fingerprint of [runtime] contents for [target].
     */
    fun runtimeFingerprint(target: String) = root.file("konan/targets/$target/runtime.fingerprint")

    companion object {
        @JvmStatic
        fun cacheDirectoryName(name: String, perFile: Boolean) =
                "${name}-${if (perFile) "per-file-cache" else "cache"}"
    }
}

fun DirectoryProperty.asNativeDistribution(): Provider<NativeDistribution> = this.map(::NativeDistribution)

/**
 * Get the default Native distribution location.
 *
 * There's no guarantee what's inside this distribution.
 * Use together with `dependsOn(":kotlin-native:<required-kind-of-distribution>").
 */
// TODO: Having tasks depend on this distribution is both errorprone
//       and sometimes incompatible with Gradle isolation mechanisms.
val Project.nativeDistribution: Provider<NativeDistribution>
    get() = layout.dir(provider { kotlinNativeDist }).map { NativeDistribution(it) }


/**
 * Get released Native distribution of [version].
 */
fun Project.registerNativeReleasedDistribution(version: String): Provider<NativeDistribution> {
    val configuration = releasedNativeDistributionConfiguration(version)
    val distributionFiles = configuration.incoming.files
    val targetDirectory = layout.buildDirectory.dir("nativeDistributionV$version")

    /*
    Setup a 'sync' task to unpack the native distribution archive.
    We're using a sync into the build directory in favor of any artifact transform, because this native
    distribution is ment to used, as is, for further builds. Such builds might store files within the distribution
    which would violate Gradle invariants for artifact transforms (which are ment to stay immutable).
     */
    val syncTaskName = "syncNativeDistributionV$version"
    val syncTask = if (syncTaskName !in tasks.names) tasks.register<Sync>(syncTaskName) {
        from(project.files({
            distributionFiles.map { archive ->
                when {
                    archive.path.endsWith("." + TAR_GZ.fileExtension) -> tarTree(archive)
                    archive.path.endsWith("." + ZIP.fileExtension) -> zipTree(archive)
                    else -> error("Unsupported archive type: $archive")
                }
            }
        }).builtBy(distributionFiles)) {
            eachFile {
                relativePath = RelativePath(true, *relativePath.segments.drop(1).toTypedArray())
            }
            includeEmptyDirs = false
        }
        into(targetDirectory)

        /*
        Create distribution hash
        */
        doLast {
            val distributionHash = sha256Of(distributionFiles.sorted().map { it.name to it })
            NativeDistribution(targetDirectory.get()).distributionFingerprint.asFile.writeText(distributionHash)
        }
    } else tasks.named<Sync>(syncTaskName)

    return syncTask.map { NativeDistribution(project.layout.buildDirectory.dir("nativeDistributionV$version").get()) }
}

/**
 * Hex SHA-256 of [files]: each file's name followed by its contents, in the given order.
 */
private fun sha256Of(files: List<Pair<String, File>>): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(1024 * 8)
    files.forEach { (name, file) ->
        digest.update(name.encodeToByteArray())
        file.toPath().inputStream().buffered().use { inputStream ->
            while (true) {
                val read = inputStream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
    }
    return digest.digest().toHexString()
}

/**
 * Gradle property with an absolute path to an unpacked Native distribution to use as the bootstrap distribution
 * instead of the released one, e.g. on a host without a released distribution.
 */
private const val NATIVE_BOOTSTRAP_DISTRIBUTION_PROPERTY = "kotlin.native.bootstrap.distribution"

/**
 * Copy of the unpacked Native distribution at [path] in the build directory.
 *
 * Builds that use the distribution may store files in it, so it is synced into the build directory
 * rather than used in place: the directory at [path] is never modified.
 */
private fun Project.registerNativeLocalDistribution(path: String): Provider<NativeDistribution> {
    val sourceDirectory = File(path)
    check(sourceDirectory.isAbsolute) {
        "Path to the Native bootstrap distribution must be absolute. $NATIVE_BOOTSTRAP_DISTRIBUTION_PROPERTY=`$path`"
    }
    check(sourceDirectory.isDirectory) {
        "The Native bootstrap distribution must be an unpacked distribution directory. $NATIVE_BOOTSTRAP_DISTRIBUTION_PROPERTY=`$path`"
    }
    val targetDirectory = layout.buildDirectory.dir("nativeBootstrapDistributionLocal")
    val syncTaskName = "syncNativeBootstrapDistributionLocal"
    val syncTask = if (syncTaskName !in tasks.names) tasks.register<Sync>(syncTaskName) {
        val sourceFiles = fileTree(sourceDirectory)
        from(sourceFiles)
        into(targetDirectory)

        doLast {
            val distributionFiles = sourceFiles.files.map { it.relativeTo(sourceDirectory).invariantSeparatorsPath to it }
            val distributionHash = sha256Of(distributionFiles.sortedBy { it.first })
            NativeDistribution(targetDirectory.get()).distributionFingerprint.asFile.writeText(distributionHash)
        }
    } else tasks.named<Sync>(syncTaskName)

    return syncTask.map { NativeDistribution(targetDirectory.get()) }
}

/**
 * Get Native bootstrap distribution: the released one, or the one at [NATIVE_BOOTSTRAP_DISTRIBUTION_PROPERTY] if it is set.
 */
fun Project.registerNativeBootstrapDistribution(): Provider<NativeDistribution> {
    val localDistribution = providers.gradleProperty(NATIVE_BOOTSTRAP_DISTRIBUTION_PROPERTY).orNull
    return if (localDistribution != null) {
        registerNativeLocalDistribution(localDistribution)
    } else {
        registerNativeReleasedDistribution(bootstrapKotlinVersion)
    }
}

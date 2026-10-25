/*
 * Copyright 2010-2026 JetBrains s.r.o. and Kotlin Programming Language contributors.
 * Use of this source code is governed by the Apache 2.0 license that can be found in the license/LICENSE.txt file.
 */

package org.jetbrains.kotlin.konan.target

import org.jetbrains.kotlin.konan.TempFiles
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Path
import java.util.Properties

class AndroidLinkerDriverTest {
    @TempDir
    lateinit var dependenciesRoot: Path

    @Test
    fun absentDriverIsNdkClang() {
        assertEquals(AndroidLinkerDriver.NdkClang, driverOf())
    }

    @Test
    fun ndkDriverIsNdkClang() {
        assertEquals(AndroidLinkerDriver.NdkClang, driverOf("androidLinkerDriver" to "ndk"))
    }

    @Test
    fun llvmDriverIsHostLlvmWithNdkVersions() {
        val driver = driverOf(
            "androidLinkerDriver" to "llvm",
            "androidNdkClangVersion" to "8.0.7",
            "androidNdkGccVersion" to "4.9.x",
        )
        val expected = AndroidLinkerDriver.HostLlvm(ndkVersionDir("8.0.7"), ndkVersionDir("4.9.x"))
        assertEquals(expected, driver)
    }

    @Test
    fun unknownDriverIsAnError() {
        val e = assertThrows<IllegalStateException> { driverOf("androidLinkerDriver" to "gcc") }
        assertTrue("'gcc'" in e.message.orEmpty(), e.message)
    }

    @Test
    fun llvmDriverWithoutNdkVersionsIsAnError() {
        val e = assertThrows<IllegalStateException> {
            driverOf("androidLinkerDriver" to "llvm", "androidNdkGccVersion" to "4.9.x")
        }
        assertTrue("androidNdkClangVersion" in e.message.orEmpty(), e.message)
    }

    @Test
    fun ndkVersionDirIsASingleNonBlankPathComponent() {
        assertEquals("4.9.x", ndkVersionDir("4.9.x").name)
        for (invalid in listOf("", " ", "8.0 .7", "8.0.7/lib", "..\\8.0.7")) {
            assertNull(AndroidLinkerDriver.NdkVersionDir.of(invalid), "'$invalid' must be rejected")
        }
    }

    @Test
    fun ndkClangLinkCommand() {
        val command = linkCommand(KonanTarget.ANDROID_ARM32)
        val clang = "/ndk/toolchain/bin/armv7a-linux-androideabi21-clang" + if (HostManager.hostIsMingw) ".cmd" else ""
        assertEquals(listOf(clang) + commonLinkArgs, command)
    }

    @Test
    fun hostLlvmLinkCommand() {
        val command = linkCommand(
            KonanTarget.ANDROID_ARM32,
            "androidLinkerDriver" to "llvm",
            "androidNdkClangVersion" to "8.0.7",
            "androidNdkGccVersion" to "4.9.x",
        )
        val expected = listOf(
            "/llvm/bin/clang",
            "--target=armv7a-linux-androideabi21", "-fno-addrsig", "-fuse-ld=lld", "--rtlib=libgcc", "--unwindlib=libgcc",
        ) + commonLinkArgs.toMutableList().apply {
            addAll(
                indexOf("main.o"),
                listOf(
                    "-L/ndk/toolchain/lib64/clang/8.0.7/lib/linux/arm",
                    "-L/ndk/toolchain/lib/gcc/arm-linux-androideabi/4.9.x",
                    "-L/ndk/toolchain/arm-linux-androideabi/lib",
                )
            )
        }
        assertEquals(expected, command)
    }

    @Test
    fun hostLlvmLinkCommandUsesLib64For64BitTargets() {
        val command = linkCommand(
            KonanTarget.ANDROID_ARM64,
            "androidLinkerDriver" to "llvm",
            "androidNdkClangVersion" to "8.0.7",
            "androidNdkGccVersion" to "4.9.x",
        )
        assertTrue("-L/ndk/toolchain/lib64/clang/8.0.7/lib/linux/aarch64" in command, command.toString())
        assertTrue("-L/ndk/toolchain/aarch64-linux-android/lib64" in command, command.toString())
    }

    // The arguments that both drivers pass for an `ANDROID_ARM32` executable, after the driver itself.
    private val commonLinkArgs = listOf(
        "-o", "out.kexe",
        "-fPIE", "-pie",
        "-target", "arm-linux-androideabi",
        "--sysroot=/ndk/sysroot/android-21/arch-arm",
        "-L/ndk/sysroot/android-21/arch-arm/usr/lib",
        "-L/ndk/toolchain/sysroot/usr/lib/arm-linux-androideabi/21",
        "-L/ndk/toolchain/sysroot/usr/lib/arm-linux-androideabi",
        "main.o",
        "-lm", "-lc++_static",
        "libfoo.a",
        "-lbar",
        "-Wl,--custom",
    )

    private fun ndkVersionDir(name: String) = AndroidLinkerDriver.NdkVersionDir.of(name)!!

    private fun configurables(target: KonanTarget, vararg extraProperties: Pair<String, String>): AndroidConfigurables {
        // Unsuffixed keys apply to every host and target.
        val properties = Properties().apply {
            setProperty("dependenciesUrl", "https://example.invalid")
            setProperty("llvmHome", "/llvm")
            setProperty("libffiDir", "/libffi")
            setProperty("targetToolchain", "/ndk/toolchain")
            setProperty("targetSysRoot", "/ndk/sysroot")
            setProperty("targetTriple.android_arm32", "arm-unknown-linux-androideabi")
            setProperty("targetTriple.android_arm64", "aarch64-unknown-linux-android")
            setProperty("linkerKonanFlags", "-lm -lc++_static")
            extraProperties.forEach { (key, value) -> setProperty(key, value) }
        }
        return AndroidConfigurablesImpl(target, properties, dependenciesRoot.toString()) { _, _, _ -> }
    }

    private fun driverOf(vararg properties: Pair<String, String>): AndroidLinkerDriver =
        configurables(KonanTarget.ANDROID_ARM64, *properties).androidLinkerDriver

    private fun linkCommand(target: KonanTarget, vararg properties: Pair<String, String>): List<String> {
        val linker = AndroidLinker(configurables(target, *properties))
        val tempFiles = TempFiles()
        try {
            val arguments = LinkerArguments(
                tempFiles = tempFiles,
                objectFiles = listOf("main.o"),
                executable = "out.kexe",
                staticLibraries = listOf("libfoo.a"),
                dynamicLibraries = listOf("-lbar"),
                linkerArgs = listOf("-Wl,--custom"),
                optimize = false,
                debug = true,
                kind = LinkerOutputKind.EXECUTABLE,
                outputDsymBundle = "",
            )
            return with(linker) { arguments.finalLinkCommands() }.single().argsWithExecutable
        } finally {
            tempFiles.dispose()
        }
    }
}

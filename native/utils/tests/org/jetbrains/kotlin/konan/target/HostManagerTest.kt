/*
 * Copyright 2010-2025 JetBrains s.r.o. and Kotlin Programming Language contributors.
 * Use of this source code is governed by the Apache 2.0 license that can be found in the license/LICENSE.txt file.
 */

package org.jetbrains.kotlin.konan.target

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertDoesNotThrow
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.parallel.Isolated

@Isolated // to prevent system properties conflicts
class HostManagerTest {

    @Test
    fun hostManagerWorksInUnknownOs() {
        withModifiedSystemProperties("os.name" to "FreeBSD") {
            assertDoesNotThrow { HostManager() }
            assertThrows<TargetSupportException> { HostManager.host }
            assertNull(HostManager.hostOrNull)
            assertFalse(HostManager.hostIsMac)
            assertFalse(HostManager.hostIsMingw)
            assertFalse(HostManager.hostIsLinux)
            assertFalse(HostManager.hostIsSupported)
        }
    }

    @Test
    fun hostIsSupportedOnKnownOs() {
        assertTrue(HostManager.hostIsSupported)
    }

    @Test
    fun linuxAarch64IsLinuxArm64Host() {
        withModifiedSystemProperties("os.name" to "Linux", "os.arch" to "aarch64") {
            assertEquals(KonanTarget.LINUX_ARM64, HostManager.host)
            assertEquals(KonanTarget.LINUX_ARM64, HostManager.hostOrNull)
            assertTrue(HostManager.hostIsSupported)
            assertTrue(HostManager.hostIsLinux)
            assertEquals("linux", HostManager.jniHostPlatformIncludeDir)
            assertEquals(commonTargets, HostManager().enabled.toSet())
        }
    }

    @Test
    fun crossHostTargetIntersectionIsCommonTargets() {
        // KGP relies on the intersection of targets enabled on all hosts (see KotlinNativeTarget), so adding a host
        // must not shrink it.
        val enabledOnAllHosts = HostManager().enabledByHost.values.reduce { acc, targets -> acc intersect targets }
        assertEquals(commonTargets, enabledOnAllHosts)
    }

    private val commonTargets = setOf(
        KonanTarget.LINUX_X64,
        KonanTarget.LINUX_ARM32_HFP,
        KonanTarget.LINUX_ARM64,
        KonanTarget.MINGW_X64,
        KonanTarget.ANDROID_X86,
        KonanTarget.ANDROID_X64,
        KonanTarget.ANDROID_ARM32,
        KonanTarget.ANDROID_ARM64,
    )

    @Synchronized
    private fun withModifiedSystemProperties(vararg pairs: Pair<String, String>, block: () -> Unit) {
        val backupValues = pairs.toMap().mapValues { (key, _) -> System.getProperty(key) }

        try {
            pairs.forEach { (key, value) -> System.setProperty(key, value) }
            block()
        } finally {
            backupValues.forEach { (key, value) ->
                if (value == null) {
                    System.clearProperty(key)
                } else {
                    System.setProperty(key, value)
                }
            }
        }
    }
}
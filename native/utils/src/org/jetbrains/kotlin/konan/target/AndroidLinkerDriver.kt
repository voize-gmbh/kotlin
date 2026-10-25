/*
 * Copyright 2010-2026 JetBrains s.r.o. and Kotlin Programming Language contributors.
 * Use of this source code is governed by the Apache 2.0 license that can be found in the license/LICENSE.txt file.
 */

package org.jetbrains.kotlin.konan.target

import org.jetbrains.kotlin.konan.properties.TargetableExternalStorage

/**
 * The compiler driver that [AndroidLinker] uses for the final link.
 *
 * Set per host-target pair with `androidLinkerDriver` in `konan.properties`:
 * `ndk` (the default when the property is absent) or `llvm`.
 */
sealed interface AndroidLinkerDriver {
    /** The NDK's per-API clang wrapper, `$targetToolchain/bin/<triple><api>-clang`. */
    data object NdkClang : AndroidLinkerDriver

    /**
     * `$llvmHome/bin/clang` with `ld.lld`, for hosts the NDK has no binaries for.
     *
     * The NDK archives are used as data only (CRT objects, libgcc, libc++), so the link has to name the
     * library directories that the NDK's clang adds by itself. Those directories contain the NDK's clang and GCC versions.
     */
    data class HostLlvm(val ndkClangVersion: NdkVersionDir, val ndkGccVersion: NdkVersionDir) : AndroidLinkerDriver

    /** A version directory name inside the NDK toolchain, like `8.0.7` or `4.9.x`: not blank, one path component. */
    @JvmInline
    value class NdkVersionDir private constructor(val name: String) {
        override fun toString(): String = name

        companion object {
            fun of(name: String): NdkVersionDir? =
                name.takeIf { it.isNotEmpty() && it.none { c -> c.isWhitespace() || c == '/' || c == '\\' } }?.let(::NdkVersionDir)
        }
    }

    companion object {
        const val PROPERTY = "androidLinkerDriver"
        const val NDK_CLANG_VERSION_PROPERTY = "androidNdkClangVersion"
        const val NDK_GCC_VERSION_PROPERTY = "androidNdkGccVersion"

        fun fromProperties(properties: TargetableExternalStorage): AndroidLinkerDriver =
            when (val value = properties.hostTargetString(PROPERTY)?.trim()) {
                null, "ndk" -> NdkClang
                "llvm" -> HostLlvm(
                    ndkClangVersion = properties.ndkVersionDir(NDK_CLANG_VERSION_PROPERTY),
                    ndkGccVersion = properties.ndkVersionDir(NDK_GCC_VERSION_PROPERTY),
                )
                else -> error("Unknown $PROPERTY: '$value'. Use 'ndk' or 'llvm'.")
            }

        private fun TargetableExternalStorage.ndkVersionDir(property: String): NdkVersionDir {
            val value = targetString(property)?.trim()
                ?: error("$PROPERTY=llvm needs $property to be set.")
            return NdkVersionDir.of(value)
                ?: error("$property must be a single directory name, but it is '$value'.")
        }
    }
}

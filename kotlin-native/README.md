# Kotlin/Native  #

_Kotlin/Native_ is an LLVM backend for the Kotlin compiler, runtime
implementation, and native code generation facility using the LLVM toolchain.

 _Kotlin/Native_ is primarily designed to allow compilation for platforms where
virtual machines are not desirable or possible (such as iOS),
or where a developer is willing to produce a reasonably sized self-contained program
without the need to ship an additional execution runtime.

## Using published Kotlin/Native versions

The most complete experience with Kotlin/Native can be achieved by using
[Gradle](https://kotlinlang.org/docs/native-gradle.html),
[IntelliJ IDEA](https://kotlinlang.org/docs/native-get-started.html) or
[Android Studio with KMP plugin](https://kotlinlang.org/docs/mobile/create-first-app.html)
if you target iOS.

If you are interested in using Kotlin/Native for iOS, then
[Kotlin Multiplatform portal](https://www.jetbrains.com/kotlin-multiplatform/)
might be useful for you.

Command line compiler is also
[available](https://kotlinlang.org/docs/native-command-line-compiler.html).

More information can be found in the overviews of
[Kotlin/Native](https://kotlinlang.org/docs/native-overview.html)
and [Kotlin Multiplatform](https://kotlinlang.org/docs/multiplatform.html).

On macOS Kotlin/Native requires Xcode 12.5 or newer.

## Contributing

You can contribute to Kotlin/Native in many ways.
See the relevant page [on the website](https://kotlinlang.org/docs/contribute.html).

See also the general [contribution guidelines](../docs/contributing.md) for this repository.

## Building from source

Prerequisites:
*   configure Kotlin build as [specified in main readme](../ReadMe.md#build-environment-requirements)
*   at the root directory of the repository,
    create `local.properties` file with `kotlin.native.enabled=true` line
*   macOS: Xcode 26.4 or newer
    * if you're seeing a build error like this
      
            > Failed to apply plugin class 'org.jetbrains.kotlin.xcode.XcodeOverridePlugin'.
               > org.jetbrains.kotlin.konan.MissingXcodeException: An error occurred during an xcrun execution. Make sure that Xcode and its command line tools are properly installed.
                 Failed command: /usr/bin/xcrun -f bitcode-build-tool
                 Try running this command in Terminal and fix the errors by making Xcode (and its command line tools) configuration correct.
            
      * try running `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
      * check if it helped via `xcrun --find bitcode-build-tool` which should print the correct path

    * on `macOS aarch64`, CInterop functionality is available only using aarch64 JDK builds, e.g.
[Eclipse Temurin 17.0.5](https://github.com/adoptium/temurin17-binaries/releases) or
[Azul Zulu JDK8](https://www.azul.com/downloads/?version=java-8-lts&os=macos&architecture=arm-64-bit&package=jdk)

      Note: using `JDK x86_64` on `macOS aarch64` will cause `java.lang.UnsatisfiedLinkError` for `libclang.dylib`
*   Linux: glibc 2.23 or newer
*   Windows:
    * Microsoft C++ build tools for Visual Studio 2019 14.29.
      It might work with other VS2019 versions, but this was never tested.
    * Windows SDK 10.0.18362.0 or newer

The commands below should be run from the repository root.

To compile the basic compiler distribution from sources, run following command:

    ./gradlew :kotlin-native:dist

It will build compiler and stdlib for host target, without
[platform libraries](https://kotlinlang.org/docs/native-platform-libs.html).

To get platform libraries, add `distPlatformLibs` task, e.g.

    ./gradlew :kotlin-native:dist :kotlin-native:distPlatformLibs

To run the full build:

    ./gradlew :kotlin-native:bundle

This will produce compiler and libraries for all supported targets.

After any of the commands above, `./dist` will contain Kotlin/Native distribution.
You can use it like a distribution of
[command-line compiler](https://kotlinlang.org/docs/native-command-line-compiler.html).

Or configure Gradle to use it -- just add the following line to
`gradle.properties` in your Gradle project:

    kotlin.native.home=/path/to/kotlin/kotlin-native/dist

To compile your programs with a command-line compiler, use:

	./dist/bin/kotlinc-native hello.kt -o hello

To compile a faster, optimized binary, use `-opt`:

	./dist/bin/kotlinc-native hello.kt -o hello -opt

### Building on Linux aarch64

JetBrains publishes neither LLVM and libffi builds nor a released Kotlin/Native distribution for Linux aarch64,
so on such a host you build them yourself and bootstrap the compiler in several stages:

1.  Use an aarch64 JDK (cinterop loads `libclang` into the JVM).
2.  Build LLVM natively with [tools/llvm_builder](tools/llvm_builder/README.md), inside its `images/linux` Docker image
    (pass the aarch64 CMake installer as the `CMAKE_DIST` build argument). The image keeps the glibc requirement of the
    LLVM tools the same as for the official Linux x86_64 builds. Keep all LLVM targets in the final stage (the default),
    and use the dev and essentials component sets to produce `llvm-21-aarch64-linux-dev-1` and
    `llvm-21-aarch64-linux-essentials-1`, the names `kotlin-native/gradle.properties` refers to.
3.  Build libffi with `kotlin-native/tools/libffi/build_for_linux.sh <output dir>`, which produces
    `libffi-3.4.6-1-linux-aarch64.tar.gz`.
4.  Unpack the LLVM and libffi archives into `~/.konan/dependencies`. Append each directory name as a separate line to
    `~/.konan/dependencies/.extracted` so that the build does not try to download them.
    The other dependencies (sysroots, Android NDK, MinGW) are downloaded as usual.
5.  Build a local bootstrap compiler, because the released one does not know this host:

        ./gradlew publish -Pkotlin.native.enabled=false -Pkotlin.native.home=<dir> --dependency-verification=lenient

    Then set `bootstrap.local=true` and `bootstrap.local.version=<published version>` in `local.properties`.
    Pass the two extra options to every Gradle invocation below as well:
    * `kotlin.native.home` must point to a directory with empty `bin/` and `konan/` subdirectories. Without it, the
      bootstrap Kotlin Gradle plugin tries to download a Linux aarch64 Kotlin/Native distribution for the
      multiplatform projects in this repository, and there is none.
    * `--dependency-verification=lenient` is needed because the Linux aarch64 Node.js archive is not listed in
      `gradle/verification-metadata.xml`.
6.  Stage 0: `:kotlin-native:libclangInterop` generates its bindings with a bootstrap Kotlin/Native distribution that
    runs on this host, and none exists yet. Generate the bindings on another 64-bit host instead (they are taken from
    `kotlin-native/libclangInterop/build/nativeInteropStubs` after building `:kotlin-native:libclangInterop`), copy them
    to `kotlin-native/libclangInterop/gen/main-linux_arm64`, temporarily set `usePrebuiltSources` to `true` in
    `kotlin-native/libclangInterop/build.gradle.kts`, and run `:kotlin-native:distCompiler` with
    `-Pkotlin.native.enabled=true`. Copy `kotlin-native/dist` out of the repository, e.g. to `~/kn-stage0`. Then revert
    the temporary change and delete `kotlin-native/libclangInterop/build/{kotlin,classes,libs}`.
7.  Stage 1: run `:kotlin-native:distCompiler` with `-Pkotlin.native.bootstrap.distribution=$HOME/kn-stage0`, and copy
    `kotlin-native/dist` to `~/kn-stage1`. The bindings are now generated on this host.
8.  Stage 2: use the stage-1 compiler as the bootstrap distribution to build the standard library and the rest:

        ./gradlew -Pkotlin.native.enabled=true -Pkotlin.native.bootstrap.distribution=$HOME/kn-stage1 :kotlin-native:bundle

    The `kotlin.native.bootstrap.distribution` property accepts an absolute path to any unpacked Kotlin/Native
    distribution. The build copies it and never modifies the original.
9.  Optionally, add the Apple platform libraries, as in the official Linux distributions. On a macOS host, build them
    from the same sources and version with `:kotlin-native:platformLibs:<target>Install` for each Apple target, and pack
    `kotlin-native/dist/klib/platform` as `<any top-level directory>/klib/platform/<target>/...` into a `.tar.gz`.
    Then repeat stage 2 with `-Pkotlin.native.pathToDarwinDist=<that archive>` and
    `-Pkotlin.native.pathToHostDist=<a copy of the stage-2 prebuilt bundle>`. Both properties are required, and both
    must point to archives.

The resulting distribution supports the same targets as the Linux x86_64 one, and can compile libraries (but not
binaries) for Apple targets if step 9 was done. It expects `llvm-21-aarch64-linux-essentials-1` and
`libffi-3.4.6-1-linux-aarch64` in `~/.konan/dependencies` on every machine that uses it.

### Interoperability

To import a C or Objective-C library, use `./dist/bin/cinterop` tool.
See the [documentation](https://kotlinlang.org/docs/native-c-interop.html) for more details.

Note: on macOS aarch64, [JDK aarch64 is required](./README.md#building-from-source)


### Running tests

For tests, use `./gradlew :nativeCompilerTest :nativeCompilerUnitTest --continue`.

Note: on macOS aarch64, [JDK aarch64 is required](./README.md#building-from-source)

For more details see [Testing](HACKING.md#Testing).

## More tips and tricks

More tips and tricks that might be useful when developing or debugging Kotlin/Native
can be found in [HACKING.md](HACKING.md).

Some Kotlin/Native compiler internals are described in the [corresponding docs directory](../docs/native)  

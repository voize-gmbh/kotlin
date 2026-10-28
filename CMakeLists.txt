# Standalone build of aapt2 and the AOSP libraries it links, for Linux hosts.
#
# Source lists and flags mirror the Android.bp files of the pinned revisions (sources.txt) for a
# Linux host, and the Soong host flags of build/soong/cc/config (global.go, x86_linux_host.go).
# Like Google's Linux build, everything but glibc links statically: libc++, the AOSP libraries,
# protobuf, expat, libpng, zlib and libgcc.
cmake_minimum_required(VERSION 3.22)

set(AOSP "" CACHE PATH "Root of the sources fetched by fetch-sources.sh")
set(SYSROOT "" CACHE PATH "Sysroot with the glibc to link against (fetch-sysroot.sh)")
set(LIBCXX "" CACHE PATH "Install prefix of libc++ and libc++abi built against SYSROOT")
set(AAPT2_BUILD_NUMBER "13193326" CACHE STRING "Build number reported by aapt2 version and stored in its outputs")
if(NOT AOSP OR NOT SYSROOT OR NOT LIBCXX)
  message(FATAL_ERROR "Set -DAOSP, -DSYSROOT and -DLIBCXX")
endif()
set(CMAKE_SYSROOT ${SYSROOT})
set(CMAKE_CXX_FLAGS_INIT "-nostdinc++ -isystem ${LIBCXX}/include/c++/v1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -nostdlib++ -static-libgcc")

project(aapt2 C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_CXX_EXTENSIONS ON)
set(CMAKE_C_STANDARD 23)
set(CMAKE_CXX_STANDARD 20)

# Soong: commonGlobalCflags and the Linux host cflags. Warnings are left out: they don't change the
# generated code, and a different clang release warns about different things.
add_compile_options(
  -O2
  -DANDROID -DNDEBUG -UDEBUG
  -D__compiler_offsetof=__builtin_offsetof
  -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__
  -faddrsig
  # Without it clang fuses multiply-adds on arm64, which round differently from x86_64.
  -ffp-contract=off
  -fno-exceptions
  -fno-strict-aliasing
  -fmessage-length=0
  -no-canonical-prefixes
  -Wa,--noexecstack
  -fno-omit-frame-pointer
  -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
  -fstack-protector-strong
  -march=armv8-a
  -w
  "$<$<COMPILE_LANGUAGE:CXX>:-D_LIBCPP_ENABLE_THREAD_SAFETY_ANNOTATIONS>"
  "-ffile-prefix-map=${AOSP}/="
)
add_link_options(
  -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now -Wl,--build-id=none -Wl,--as-needed)
link_libraries(${LIBCXX}/lib/libc++.a pthread m)

# Soong: noOverrideExternalGlobalCflags, for code under external/.
set(EXTERNAL_CFLAGS -fcommon)

set(FWB ${AOSP}/frameworks/base)
set(CORE ${AOSP}/system/core)

# --- zlib (external/zlib, libz) ------------------------------------------------------------------
add_library(z STATIC
  ${AOSP}/external/zlib/adler32.c
  ${AOSP}/external/zlib/adler32_simd.c
  ${AOSP}/external/zlib/compress.c
  ${AOSP}/external/zlib/cpu_features.c
  ${AOSP}/external/zlib/crc32.c
  ${AOSP}/external/zlib/crc32_simd.c
  ${AOSP}/external/zlib/crc_folding.c
  ${AOSP}/external/zlib/deflate.c
  ${AOSP}/external/zlib/gzclose.c
  ${AOSP}/external/zlib/gzlib.c
  ${AOSP}/external/zlib/gzread.c
  ${AOSP}/external/zlib/gzwrite.c
  ${AOSP}/external/zlib/infback.c
  ${AOSP}/external/zlib/inffast.c
  ${AOSP}/external/zlib/inflate.c
  ${AOSP}/external/zlib/inftrees.c
  ${AOSP}/external/zlib/trees.c
  ${AOSP}/external/zlib/uncompr.c
  ${AOSP}/external/zlib/zutil.c
)
target_include_directories(z PUBLIC ${AOSP}/external/zlib)
# cflags_shared + cflags_arm64 + the linux_arm64 target cflags.
target_compile_options(z PRIVATE ${EXTERNAL_CFLAGS}
  -DHAVE_HIDDEN -DZLIB_CONST -DCHROMIUM_ZLIB_NO_CASTAGNOLI -O3
  -DADLER32_SIMD_NEON -DCRC32_ARMV8_CRC32 -DINFLATE_CHUNK_READ_64LE -DARMV8_OS_LINUX)

# --- libpng (external/libpng) --------------------------------------------------------------------
file(GLOB PNG_SRCS ${AOSP}/external/libpng/*.c)
list(REMOVE_ITEM PNG_SRCS ${AOSP}/external/libpng/example.c ${AOSP}/external/libpng/pngtest.c)
add_library(png STATIC ${PNG_SRCS}
  ${AOSP}/external/libpng/arm/arm_init.c
  ${AOSP}/external/libpng/arm/filter_neon_intrinsics.c
  ${AOSP}/external/libpng/arm/palette_neon_intrinsics.c)
target_include_directories(png PUBLIC ${AOSP}/external/libpng)
target_compile_options(png PRIVATE ${EXTERNAL_CFLAGS} -std=gnu89 -O3)
target_link_libraries(png PUBLIC z)

# --- expat (external/expat, libexpat) ------------------------------------------------------------
add_library(expat STATIC
  ${AOSP}/external/expat/expat/lib/xmlparse.c
  ${AOSP}/external/expat/expat/lib/xmlrole.c
  ${AOSP}/external/expat/expat/lib/xmltok.c)
target_include_directories(expat PUBLIC ${AOSP}/external/expat/lib PRIVATE ${AOSP}/external/expat)
target_compile_options(expat PRIVATE ${EXTERNAL_CFLAGS}
  -fno-strict-aliasing -DHAVE_EXPAT_CONFIG_H -UWIN32_LEAN_AND_MEAN -include stdio.h)

# --- fmtlib (external/fmtlib) --------------------------------------------------------------------
add_library(fmtlib STATIC ${AOSP}/external/fmtlib/src/format.cc)
target_include_directories(fmtlib PUBLIC ${AOSP}/external/fmtlib/include)
target_compile_options(fmtlib PRIVATE ${EXTERNAL_CFLAGS} -fno-exceptions -UNDEBUG)

# --- protobuf (external/protobuf, libprotobuf-cpp-full, libprotoc, aprotoc) ----------------------
set(PB ${AOSP}/external/protobuf/src/google/protobuf)
set(PROTOBUF_LITE_SRCS
  ${PB}/any_lite.cc ${PB}/arena.cc ${PB}/arenastring.cc ${PB}/arenaz_sampler.cc ${PB}/extension_set.cc
  ${PB}/generated_enum_util.cc ${PB}/generated_message_tctable_lite.cc ${PB}/generated_message_util.cc
  ${PB}/implicit_weak_message.cc ${PB}/inlined_string_field.cc ${PB}/io/coded_stream.cc
  ${PB}/io/io_win32.cc ${PB}/io/strtod.cc ${PB}/io/zero_copy_stream.cc ${PB}/io/zero_copy_stream_impl.cc
  ${PB}/io/zero_copy_stream_impl_lite.cc ${PB}/map.cc ${PB}/message_lite.cc ${PB}/parse_context.cc
  ${PB}/repeated_field.cc ${PB}/repeated_ptr_field.cc ${PB}/stubs/bytestream.cc ${PB}/stubs/common.cc
  ${PB}/stubs/int128.cc ${PB}/stubs/status.cc ${PB}/stubs/statusor.cc ${PB}/stubs/stringpiece.cc
  ${PB}/stubs/stringprintf.cc ${PB}/stubs/structurally_valid.cc ${PB}/stubs/strutil.cc
  ${PB}/stubs/time.cc ${PB}/wire_format_lite.cc)
set(PROTOBUF_FULL_SRCS ${PROTOBUF_LITE_SRCS}
  ${PB}/any.cc ${PB}/any.pb.cc ${PB}/api.pb.cc ${PB}/compiler/importer.cc ${PB}/compiler/parser.cc
  ${PB}/descriptor.cc ${PB}/descriptor.pb.cc ${PB}/descriptor_database.cc ${PB}/duration.pb.cc
  ${PB}/dynamic_message.cc ${PB}/empty.pb.cc ${PB}/extension_set_heavy.cc ${PB}/field_mask.pb.cc
  ${PB}/generated_message_bases.cc ${PB}/generated_message_reflection.cc
  ${PB}/generated_message_tctable_full.cc ${PB}/io/gzip_stream.cc ${PB}/io/printer.cc
  ${PB}/io/tokenizer.cc ${PB}/map_field.cc ${PB}/message.cc ${PB}/reflection_ops.cc ${PB}/service.cc
  ${PB}/source_context.pb.cc ${PB}/struct.pb.cc ${PB}/stubs/substitute.cc ${PB}/text_format.cc
  ${PB}/timestamp.pb.cc ${PB}/type.pb.cc ${PB}/unknown_field_set.cc ${PB}/util/delimited_message_util.cc
  ${PB}/util/field_comparator.cc ${PB}/util/field_mask_util.cc ${PB}/util/internal/datapiece.cc
  ${PB}/util/internal/default_value_objectwriter.cc ${PB}/util/internal/error_listener.cc
  ${PB}/util/internal/field_mask_utility.cc ${PB}/util/internal/json_escaping.cc
  ${PB}/util/internal/json_objectwriter.cc ${PB}/util/internal/json_stream_parser.cc
  ${PB}/util/internal/object_writer.cc ${PB}/util/internal/proto_writer.cc
  ${PB}/util/internal/protostream_objectsource.cc ${PB}/util/internal/protostream_objectwriter.cc
  ${PB}/util/internal/type_info.cc ${PB}/util/internal/utility.cc ${PB}/util/json_util.cc
  ${PB}/util/message_differencer.cc ${PB}/util/time_util.cc ${PB}/util/type_resolver_util.cc
  ${PB}/wire_format.cc ${PB}/wrappers.pb.cc)
set(PROTOBUF_CFLAGS ${EXTERNAL_CFLAGS} -DHAVE_ZLIB=1 -frtti)

add_library(protobuf STATIC ${PROTOBUF_FULL_SRCS})
target_include_directories(protobuf PUBLIC ${AOSP}/external/protobuf/src
  PRIVATE ${AOSP}/external/protobuf/android ${AOSP}/external/protobuf)
target_compile_options(protobuf PRIVATE ${PROTOBUF_CFLAGS})
target_link_libraries(protobuf PUBLIC z)

set(PC ${PB}/compiler)
add_library(protoc STATIC
  ${PC}/code_generator.cc ${PC}/command_line_interface.cc ${PC}/cpp/enum.cc ${PC}/cpp/enum_field.cc
  ${PC}/cpp/extension.cc ${PC}/cpp/field.cc ${PC}/cpp/file.cc ${PC}/cpp/generator.cc ${PC}/cpp/helpers.cc
  ${PC}/cpp/map_field.cc ${PC}/cpp/message.cc ${PC}/cpp/message_field.cc ${PC}/cpp/padding_optimizer.cc
  ${PC}/cpp/parse_function_generator.cc ${PC}/cpp/primitive_field.cc ${PC}/cpp/service.cc
  ${PC}/cpp/string_field.cc
  ${PC}/csharp/csharp_doc_comment.cc ${PC}/csharp/csharp_enum.cc ${PC}/csharp/csharp_enum_field.cc
  ${PC}/csharp/csharp_field_base.cc ${PC}/csharp/csharp_generator.cc ${PC}/csharp/csharp_helpers.cc
  ${PC}/csharp/csharp_map_field.cc ${PC}/csharp/csharp_message.cc ${PC}/csharp/csharp_message_field.cc
  ${PC}/csharp/csharp_primitive_field.cc ${PC}/csharp/csharp_reflection_class.cc
  ${PC}/csharp/csharp_repeated_enum_field.cc ${PC}/csharp/csharp_repeated_message_field.cc
  ${PC}/csharp/csharp_repeated_primitive_field.cc ${PC}/csharp/csharp_source_generator_base.cc
  ${PC}/csharp/csharp_wrapper_field.cc
  ${PC}/java/context.cc ${PC}/java/doc_comment.cc ${PC}/java/enum.cc ${PC}/java/enum_field.cc
  ${PC}/java/enum_field_lite.cc ${PC}/java/enum_lite.cc ${PC}/java/extension.cc ${PC}/java/extension_lite.cc
  ${PC}/java/field.cc ${PC}/java/file.cc ${PC}/java/generator.cc ${PC}/java/generator_factory.cc
  ${PC}/java/helpers.cc ${PC}/java/kotlin_generator.cc ${PC}/java/map_field.cc ${PC}/java/map_field_lite.cc
  ${PC}/java/message.cc ${PC}/java/message_builder.cc ${PC}/java/message_builder_lite.cc
  ${PC}/java/message_field.cc ${PC}/java/message_field_lite.cc ${PC}/java/message_lite.cc
  ${PC}/java/name_resolver.cc ${PC}/java/primitive_field.cc ${PC}/java/primitive_field_lite.cc
  ${PC}/java/service.cc ${PC}/java/shared_code_generator.cc ${PC}/java/string_field.cc
  ${PC}/java/string_field_lite.cc
  ${PC}/objectivec/objectivec_enum.cc ${PC}/objectivec/objectivec_enum_field.cc
  ${PC}/objectivec/objectivec_extension.cc ${PC}/objectivec/objectivec_field.cc
  ${PC}/objectivec/objectivec_file.cc ${PC}/objectivec/objectivec_generator.cc
  ${PC}/objectivec/objectivec_helpers.cc ${PC}/objectivec/objectivec_map_field.cc
  ${PC}/objectivec/objectivec_message.cc ${PC}/objectivec/objectivec_message_field.cc
  ${PC}/objectivec/objectivec_oneof.cc ${PC}/objectivec/objectivec_primitive_field.cc
  ${PC}/php/php_generator.cc ${PC}/plugin.cc ${PC}/plugin.pb.cc ${PC}/python/generator.cc
  ${PC}/python/helpers.cc ${PC}/python/pyi_generator.cc ${PC}/ruby/ruby_generator.cc ${PC}/subprocess.cc
  ${PC}/zip_writer.cc)
target_include_directories(protoc PUBLIC ${AOSP}/external/protobuf/src
  PRIVATE ${AOSP}/external/protobuf/android ${AOSP}/external/protobuf/config ${AOSP}/external/protobuf)
target_compile_options(protoc PRIVATE ${PROTOBUF_CFLAGS})
target_link_libraries(protoc PUBLIC protobuf)

add_executable(aprotoc ${PC}/main.cc)
target_compile_options(aprotoc PRIVATE ${PROTOBUF_CFLAGS})
target_link_libraries(aprotoc PRIVATE protoc)

# --- liblog (system/logging/liblog) --------------------------------------------------------------
set(LOG ${AOSP}/system/logging/liblog)
add_library(log STATIC
  ${LOG}/log_event_list.cpp ${LOG}/log_event_write.cpp ${LOG}/logger_name.cpp ${LOG}/logger_read.cpp
  ${LOG}/logger_write.cpp ${LOG}/logprint.cpp ${LOG}/properties.cpp ${LOG}/event_tag_map.cpp)
target_include_directories(log PUBLIC ${LOG}/include
  PRIVATE ${LOG} ${AOSP}/system/libbase/include ${CORE}/libcutils/include ${CORE}/libutils/include
  ${CORE}/libsystem/include)
target_compile_options(log PRIVATE
  -DLIBLOG_LOG_TAG=1006 -DSNET_EVENT_LOG_TAG=1397638484 -DANDROID_DEBUGGABLE=0)

# --- libbase (system/libbase) --------------------------------------------------------------------
set(BASE ${AOSP}/system/libbase)
add_library(base STATIC
  ${BASE}/abi_compatibility.cpp ${BASE}/chrono_utils.cpp ${BASE}/cmsg.cpp ${BASE}/file.cpp
  ${BASE}/hex.cpp ${BASE}/logging.cpp ${BASE}/mapped_file.cpp ${BASE}/parsebool.cpp
  ${BASE}/parsenetaddress.cpp ${BASE}/posix_strerror_r.cpp ${BASE}/process.cpp ${BASE}/properties.cpp
  ${BASE}/result.cpp ${BASE}/stringprintf.cpp ${BASE}/strings.cpp ${BASE}/threads.cpp
  ${BASE}/test_utils.cpp ${BASE}/errors_unix.cpp)
target_include_directories(base PUBLIC ${BASE}/include PRIVATE ${BASE})
target_link_libraries(base PUBLIC log fmtlib)

# --- libcutils (system/core/libcutils, with libcutils_sockets) -----------------------------------
set(CUTILS ${CORE}/libcutils)
add_library(cutils STATIC
  ${CUTILS}/config_utils.cpp ${CUTILS}/iosched_policy.cpp ${CUTILS}/load_file.cpp
  ${CUTILS}/native_handle.cpp ${CUTILS}/properties.cpp ${CUTILS}/record_stream.cpp ${CUTILS}/strlcpy.c
  ${CUTILS}/canned_fs_config.cpp ${CUTILS}/fs_config.cpp ${CUTILS}/trace-host.cpp
  ${CUTILS}/ashmem-host.cpp ${CUTILS}/fs.cpp ${CUTILS}/hashmap.cpp ${CUTILS}/multiuser.cpp
  ${CUTILS}/str_parms.cpp
  ${CUTILS}/sockets.cpp ${CUTILS}/socket_inaddr_any_server_unix.cpp
  ${CUTILS}/socket_local_client_unix.cpp ${CUTILS}/socket_local_server_unix.cpp
  ${CUTILS}/socket_network_client_unix.cpp ${CUTILS}/sockets_unix.cpp)
target_include_directories(cutils PUBLIC ${CUTILS}/include ${CORE}/libprocessgroup/include
  PRIVATE ${CUTILS} ${CORE}/libutils/include ${CORE}/libsystem/include)
target_compile_options(cutils PRIVATE -Wno-exit-time-destructors)
target_link_libraries(cutils PUBLIC base log)

# --- libutils (system/core/libutils, with libutils_binder) ---------------------------------------
set(UTILS ${CORE}/libutils)
add_library(utils STATIC
  ${UTILS}/FileMap.cpp ${UTILS}/JenkinsHash.cpp ${UTILS}/LightRefBase.cpp ${UTILS}/NativeHandle.cpp
  ${UTILS}/Printer.cpp ${UTILS}/StopWatch.cpp ${UTILS}/SystemClock.cpp ${UTILS}/Threads.cpp
  ${UTILS}/Timers.cpp ${UTILS}/Tokenizer.cpp ${UTILS}/misc.cpp ${UTILS}/Looper.cpp
  ${UTILS}/binder/Errors.cpp ${UTILS}/binder/RefBase.cpp ${UTILS}/binder/SharedBuffer.cpp
  ${UTILS}/binder/String16.cpp ${UTILS}/binder/String8.cpp ${UTILS}/binder/StrongPointer.cpp
  ${UTILS}/binder/Unicode.cpp ${UTILS}/binder/VectorImpl.cpp)
target_include_directories(utils PUBLIC ${UTILS}/include ${UTILS}/binder/include ${CORE}/libsystem/include
  PRIVATE ${UTILS} ${UTILS}/binder)
target_compile_options(utils PRIVATE -Wno-exit-time-destructors -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION)
target_link_libraries(utils PUBLIC cutils log base)

# --- libziparchive (system/libziparchive) --------------------------------------------------------
set(ZIP ${AOSP}/system/libziparchive)
add_library(ziparchive STATIC
  ${ZIP}/zip_archive.cc ${ZIP}/zip_archive_stream_entry.cc ${ZIP}/zip_cd_entry_map.cc
  ${ZIP}/zip_error.cpp ${ZIP}/zip_writer.cc)
target_include_directories(ziparchive PUBLIC ${ZIP}/include ${AOSP}/external/googletest/googletest/include
  PRIVATE ${ZIP} ${ZIP}/incfs_support/include)
set_target_properties(ziparchive PROPERTIES CXX_STANDARD 20 CXX_EXTENSIONS OFF)
target_compile_options(ziparchive PRIVATE -DZLIB_CONST -D_FILE_OFFSET_BITS=64 -DINCFS_SUPPORT_DISABLED=1)
target_link_libraries(ziparchive PUBLIC base log z)

# --- libincfs-utils (system/incremental_delivery/incfs) ------------------------------------------
set(INCFS ${AOSP}/system/incremental_delivery/incfs)
add_library(incfs_utils STATIC ${INCFS}/util/map_ptr.cpp)
target_include_directories(incfs_utils PUBLIC ${INCFS}/util/include PRIVATE ${INCFS})
set_target_properties(incfs_utils PROPERTIES CXX_STANDARD 20 CXX_EXTENSIONS OFF)
target_compile_options(incfs_utils PRIVATE -D_FILE_OFFSET_BITS=64)
target_link_libraries(incfs_utils PUBLIC base utils)

# --- libbuildversion (build/soong/cc/libbuildversion) --------------------------------------------
add_library(buildversion STATIC ${AOSP}/build/soong/cc/libbuildversion/libbuildversion.cpp)
target_include_directories(buildversion PUBLIC ${AOSP}/build/soong/cc/libbuildversion/include)

# --- libandroidfw (frameworks/base/libs/androidfw, with libandroidfw_pathutils) ------------------
set(FW ${FWB}/libs/androidfw)
add_library(androidfw STATIC
  ${FW}/ApkAssets.cpp ${FW}/ApkParsing.cpp ${FW}/Asset.cpp ${FW}/AssetDir.cpp ${FW}/AssetManager.cpp
  ${FW}/AssetManager2.cpp ${FW}/AssetsProvider.cpp ${FW}/AttributeResolution.cpp ${FW}/BigBuffer.cpp
  ${FW}/BigBufferStream.cpp ${FW}/ChunkIterator.cpp ${FW}/ConfigDescription.cpp ${FW}/FileStream.cpp
  ${FW}/Idmap.cpp ${FW}/LoadedArsc.cpp ${FW}/Locale.cpp ${FW}/LocaleData.cpp ${FW}/LocaleDataLookup.cpp
  ${FW}/misc.cpp ${FW}/NinePatch.cpp ${FW}/ObbFile.cpp ${FW}/PosixUtils.cpp ${FW}/Png.cpp
  ${FW}/PngChunkFilter.cpp ${FW}/PngCrunch.cpp ${FW}/ResourceTimer.cpp ${FW}/ResourceTypes.cpp
  ${FW}/ResourceUtils.cpp ${FW}/StreamingZipInflater.cpp ${FW}/StringPool.cpp ${FW}/TypeWrappers.cpp
  ${FW}/Util.cpp ${FW}/ZipFileRO.cpp ${FW}/ZipUtils.cpp
  ${FW}/PathUtils.cpp)
# The host_linux CursorWindow.cpp is left out: it needs libbinder, and aapt2 doesn't use it.
target_include_directories(androidfw PUBLIC ${FW}/include ${FW}/include_pathutils ${AOSP}/frameworks/native/include
  PRIVATE ${FW})
set_target_properties(androidfw PROPERTIES CXX_STANDARD 23)
target_compile_options(androidfw PRIVATE -Wunreachable-code -DSTATIC_ANDROIDFW_FOR_TOOLS)
target_link_libraries(androidfw PUBLIC incfs_utils png base cutils log utils ziparchive z)

# --- libaapt2 and aapt2 (frameworks/base/tools/aapt2) --------------------------------------------
set(A ${FWB}/tools/aapt2)
set(AAPT2_PROTOS ApkInfo Configuration Resources ResourceMetadata ResourcesInternal)
set(PROTO_GEN ${CMAKE_CURRENT_BINARY_DIR}/proto)
set(AAPT2_PROTO_SRCS)
set(AAPT2_PROTO_FILES)
foreach(p ${AAPT2_PROTOS})
  list(APPEND AAPT2_PROTO_SRCS ${PROTO_GEN}/frameworks/base/tools/aapt2/${p}.pb.cc)
  list(APPEND AAPT2_PROTO_FILES ${A}/${p}.proto)
endforeach()
# Paths relative to the source root, as Soong passes them, so the descriptors name
# frameworks/base/tools/aapt2/<name>.proto like Google's binary.
add_custom_command(
  OUTPUT ${AAPT2_PROTO_SRCS}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${PROTO_GEN}
  COMMAND $<TARGET_FILE:aprotoc> --proto_path=${AOSP} --proto_path=${AOSP}/external/protobuf/src
          --cpp_out=${PROTO_GEN}
          frameworks/base/tools/aapt2/ApkInfo.proto
          frameworks/base/tools/aapt2/Configuration.proto
          frameworks/base/tools/aapt2/Resources.proto
          frameworks/base/tools/aapt2/ResourceMetadata.proto
          frameworks/base/tools/aapt2/ResourcesInternal.proto
  WORKING_DIRECTORY ${AOSP}
  DEPENDS aprotoc ${AAPT2_PROTO_FILES}
  VERBATIM)

set(AAPT2_CXXFLAGS -fno-exceptions -fno-rtti)
set(AAPT2_INCLUDES ${A} ${PROTO_GEN} ${PROTO_GEN}/frameworks/base/tools/aapt2
  ${FWB}/cmds/idmap2/libidmap2_policies/include ${AOSP}/libnativehelper/include_jni
  ${AOSP}/frameworks/native/include)

add_library(aapt2_lib STATIC
  ${A}/compile/IdAssigner.cpp ${A}/compile/InlineXmlFormatParser.cpp ${A}/compile/PseudolocaleGenerator.cpp
  ${A}/compile/Pseudolocalizer.cpp ${A}/compile/XmlIdCollector.cpp
  ${A}/configuration/ConfigurationParser.cpp ${A}/dump/DumpManifest.cpp ${A}/filter/AbiFilter.cpp
  ${A}/filter/ConfigFilter.cpp ${A}/format/Archive.cpp ${A}/format/Container.cpp
  ${A}/format/binary/BinaryResourceParser.cpp ${A}/format/binary/ResChunkPullParser.cpp
  ${A}/format/binary/ResEntryWriter.cpp ${A}/format/binary/TableFlattener.cpp
  ${A}/format/binary/XmlFlattener.cpp ${A}/format/proto/ProtoDeserialize.cpp
  ${A}/format/proto/ProtoSerialize.cpp ${A}/io/File.cpp ${A}/io/FileSystem.cpp ${A}/io/StringStream.cpp
  ${A}/io/Util.cpp ${A}/io/ZipArchive.cpp ${A}/link/AutoVersioner.cpp ${A}/link/FeatureFlagsFilter.cpp
  ${A}/link/FlaggedXmlVersioner.cpp ${A}/link/FlagDisabledResourceRemover.cpp ${A}/link/ManifestFixer.cpp
  ${A}/link/NoDefaultResourceRemover.cpp ${A}/link/PrivateAttributeMover.cpp
  ${A}/link/ReferenceLinker.cpp ${A}/link/ResourceExcluder.cpp ${A}/link/TableMerger.cpp
  ${A}/link/XmlCompatVersioner.cpp ${A}/link/XmlNamespaceRemover.cpp ${A}/link/XmlReferenceLinker.cpp
  ${A}/optimize/MultiApkGenerator.cpp ${A}/optimize/ResourceDeduper.cpp ${A}/optimize/ResourceFilter.cpp
  ${A}/optimize/Obfuscator.cpp ${A}/optimize/VersionCollapser.cpp ${A}/process/ProductFilter.cpp
  ${A}/process/SymbolTable.cpp ${A}/split/TableSplitter.cpp ${A}/text/Printer.cpp ${A}/text/Unicode.cpp
  ${A}/text/Utf8Iterator.cpp ${A}/util/Files.cpp ${A}/util/Util.cpp ${A}/Debug.cpp ${A}/DominatorTree.cpp
  ${A}/java/AnnotationProcessor.cpp ${A}/java/ClassDefinition.cpp ${A}/java/JavaClassGenerator.cpp
  ${A}/java/ManifestClassGenerator.cpp ${A}/java/ProguardRules.cpp ${A}/LoadedApk.cpp ${A}/Resource.cpp
  ${A}/ResourceParser.cpp ${A}/ResourceTable.cpp ${A}/ResourceUtils.cpp ${A}/ResourceValues.cpp
  ${A}/SdkConstants.cpp ${A}/trace/TraceBuffer.cpp ${A}/xml/XmlActionExecutor.cpp ${A}/xml/XmlDom.cpp
  ${A}/xml/XmlPullParser.cpp ${A}/xml/XmlUtil.cpp ${A}/ValueTransformer.cpp
  ${AAPT2_PROTO_SRCS})
target_include_directories(aapt2_lib PUBLIC ${AAPT2_INCLUDES})
set_target_properties(aapt2_lib PROPERTIES CXX_STANDARD 23)
target_compile_options(aapt2_lib PRIVATE ${AAPT2_CXXFLAGS})
target_link_libraries(aapt2_lib PUBLIC androidfw utils log cutils expat ziparchive png base protobuf z
  buildversion)

set(AAPT2_TOOL_SRCS
  ${A}/cmd/ApkInfo.cpp ${A}/cmd/Command.cpp ${A}/cmd/Compile.cpp ${A}/cmd/Convert.cpp ${A}/cmd/Diff.cpp
  ${A}/cmd/Dump.cpp ${A}/cmd/Link.cpp ${A}/cmd/Optimize.cpp ${A}/cmd/Util.cpp)

add_executable(aapt2 ${A}/Main.cpp ${AAPT2_TOOL_SRCS})
set_target_properties(aapt2 PROPERTIES CXX_STANDARD 23)
target_compile_options(aapt2 PRIVATE ${AAPT2_CXXFLAGS})
target_link_libraries(aapt2 PRIVATE aapt2_lib)
# Soong's symbol_inject: writes the build number into soong_build_number after linking.
add_custom_command(TARGET aapt2 POST_BUILD
  COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/inject_build_number.py $<TARGET_FILE:aapt2> ${AAPT2_BUILD_NUMBER}
  VERBATIM)

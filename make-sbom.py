#!/usr/bin/env python3
"""Writes the SPDX 2.3 SBOM of the aapt2 tarball: every source it is built from, pinned.

usage: make-sbom.py <tarball> <sources.txt> <sysroot.txt> <llvm version> <llvm sha256> <toolchain.txt>
"""
import hashlib
import json
import os
import sys

tarball, sources_txt, sysroot_txt, llvm_version, llvm_sha256, toolchain_txt = sys.argv[1:7]
created = os.environ.get("SBOM_CREATED", "1970-01-01T00:00:00Z")
release_url = os.environ.get("RELEASE_URL", "NOASSERTION")
name = os.path.basename(tarball).removesuffix(".tar.gz")
tar_sha256 = hashlib.sha256(open(tarball, "rb").read()).hexdigest()

LICENSES = {
    "frameworks/base": "Apache-2.0",
    "frameworks/native": "Apache-2.0",
    "system/core": "Apache-2.0",
    "system/libbase": "Apache-2.0",
    "system/logging": "Apache-2.0",
    "system/libziparchive": "Apache-2.0",
    "system/incremental_delivery": "Apache-2.0",
    "external/expat": "MIT",
    "external/libpng": "libpng-2.0",
    "external/protobuf": "BSD-3-Clause",
    "external/zlib": "Zlib",
    "external/fmtlib": "MIT",
    "build/soong": "Apache-2.0",
    "libnativehelper": "Apache-2.0",
    "external/googletest": "BSD-3-Clause",
}
WHAT = {
    "frameworks/base": "aapt2, libandroidfw, libidmap2_policies",
    "frameworks/native": "headers",
    "system/core": "libutils, libcutils",
    "system/libbase": "libbase",
    "system/logging": "liblog",
    "system/libziparchive": "libziparchive",
    "system/incremental_delivery": "libincfs-utils",
    "external/expat": "libexpat",
    "external/libpng": "libpng",
    "external/protobuf": "libprotobuf-cpp-full, and protoc to generate aapt2's protobuf code",
    "external/zlib": "libz",
    "external/fmtlib": "fmtlib",
    "build/soong": "libbuildversion",
    "libnativehelper": "JNI headers",
    "external/googletest": "gtest_prod.h header",
}


def spdx_id(s):
    return "SPDXRef-" + "".join(c if c.isalnum() or c in ".-" else "-" for c in s)


packages = [{
    "SPDXID": "SPDXRef-Package-aapt2",
    "name": name,
    "versionInfo": "2.20-13193326",
    "supplier": "Organization: voize GmbH",
    "downloadLocation": release_url,
    "checksums": [{"algorithm": "SHA256", "checksumValue": tar_sha256}],
    "filesAnalyzed": False,
    "licenseConcluded": "NOASSERTION",
    "licenseDeclared": "Apache-2.0 AND BSD-3-Clause AND MIT AND Zlib AND libpng-2.0 AND "
                       "Apache-2.0 WITH LLVM-exception AND GPL-3.0-or-later WITH GCC-exception-3.1",
    "copyrightText": "NOASSERTION",
    "primaryPackagePurpose": "APPLICATION",
    "comment": "Unofficial Linux aarch64 build of the Android SDK build-tools 36.0.0 aapt2 "
               "(2.20-13193326) from AOSP sources. glibc is linked dynamically and not included.",
}]
relationships = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                  "relatedSpdxElement": "SPDXRef-Package-aapt2"}]

for line in open(sources_txt):
    if not line.strip() or line.startswith("#"):
        continue
    path, url, commit, *_ = line.split()
    pid = spdx_id("Package-aosp-" + path)
    packages.append({
        "SPDXID": pid,
        "name": "platform/" + path if not path.startswith("platform/") else path,
        "versionInfo": commit,
        "supplier": "Organization: The Android Open Source Project",
        "downloadLocation": f"git+{url}@{commit}",
        "filesAnalyzed": False,
        "licenseConcluded": LICENSES[path],
        "licenseDeclared": LICENSES[path],
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "SOURCE",
        "comment": WHAT[path],
    })
    relationships.append({"spdxElementId": "SPDXRef-Package-aapt2", "relationshipType": "GENERATED_FROM",
                          "relatedSpdxElement": pid})

llvm_url = (f"https://github.com/llvm/llvm-project/releases/download/llvmorg-{llvm_version}/"
            f"llvm-project-{llvm_version}.src.tar.xz")
packages.append({
    "SPDXID": "SPDXRef-Package-libcxx",
    "name": "libc++ and libc++abi (llvm-project)",
    "versionInfo": llvm_version,
    "supplier": "Organization: LLVM Foundation",
    "downloadLocation": llvm_url,
    "checksums": [{"algorithm": "SHA256", "checksumValue": llvm_sha256}],
    "filesAnalyzed": False,
    "licenseConcluded": "Apache-2.0 WITH LLVM-exception",
    "licenseDeclared": "Apache-2.0 WITH LLVM-exception",
    "copyrightText": "NOASSERTION",
    "primaryPackagePurpose": "LIBRARY",
})
relationships.append({"spdxElementId": "SPDXRef-Package-aapt2", "relationshipType": "STATIC_LINK",
                      "relatedSpdxElement": "SPDXRef-Package-libcxx"})

for line in open(sysroot_txt):
    if not line.strip() or line.startswith("#"):
        continue
    url, sha256 = line.split()
    deb = os.path.basename(url)
    pkg, version = deb.split("_")[:2]
    pid = spdx_id("Package-deb-" + pkg)
    packages.append({
        "SPDXID": pid,
        "name": f"{pkg} (Debian 10)",
        "versionInfo": version,
        "supplier": "Organization: Debian",
        "downloadLocation": url,
        "checksums": [{"algorithm": "SHA256", "checksumValue": sha256}],
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "GPL-3.0-or-later WITH GCC-exception-3.1" if pkg.startswith(("libgcc", "gcc"))
                           else "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "LIBRARY",
        "comment": "libgcc.a and libgcc_eh.a are linked statically" if pkg == "libgcc-8-dev"
                   else "build sysroot: glibc headers and link stubs; glibc itself is loaded from the host",
    })
    if pkg in ("libgcc-8-dev", "libc6"):
        kind = "STATIC_LINK" if pkg == "libgcc-8-dev" else "DYNAMIC_LINK"
        relationships.append({"spdxElementId": "SPDXRef-Package-aapt2", "relationshipType": kind,
                              "relatedSpdxElement": pid})
    else:
        relationships.append({"spdxElementId": pid, "relationshipType": "BUILD_DEPENDENCY_OF",
                              "relatedSpdxElement": "SPDXRef-Package-aapt2"})

for line in open(toolchain_txt):
    if not line.strip() or line.startswith("#"):
        continue
    tool, version, where = line.rstrip("\n").split(" ", 2)
    pid = spdx_id("Package-tool-" + tool)
    packages.append({
        "SPDXID": pid, "name": tool, "versionInfo": version, "downloadLocation": where,
        "filesAnalyzed": False, "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION", "primaryPackagePurpose": "APPLICATION",
    })
    relationships.append({"spdxElementId": pid, "relationshipType": "BUILD_TOOL_OF",
                          "relatedSpdxElement": "SPDXRef-Package-aapt2"})

doc = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": name,
    "documentNamespace": f"https://github.com/voize-gmbh/kotlin/spdx/{name}-{tar_sha256}",
    "creationInfo": {"created": created, "creators": ["Organization: voize GmbH", "Tool: make-sbom.py"]},
    "documentDescribes": ["SPDXRef-Package-aapt2"],
    "packages": packages,
    "relationships": relationships,
}
json.dump(doc, sys.stdout, indent=1)
sys.stdout.write("\n")

#!/usr/bin/env bash
# Runs a fixed set of aapt2 commands over every resource directory under $ROOT/res.
# usage: direct-test.sh <aapt2>      (writes $ROOT/out; ROOT defaults to /tmp/aapt2-direct)
set -uo pipefail
AAPT2=$1
ROOT=${ROOT:-/tmp/aapt2-direct}
JAR=$ROOT/android.jar
OUT=$ROOT/out
rm -rf "$OUT"
mkdir -p "$OUT"
log() { echo "$*" >> "$OUT/commands.log"; }
run() { log "$*"; "$AAPT2" "$@" >> "$OUT/stdout.log" 2>> "$OUT/stderr.log"; echo "exit $? : $*" >> "$OUT/exit.log"; }

"$AAPT2" version > "$OUT/version.txt"

# Compile: every file of a directory in one invocation, like the busybox does per file.
for d in "$ROOT"/res/*/; do
  n=$(basename "$d")
  files=$(find "$d" -type f ! -name '.*' | LC_ALL=C sort)
  [ -n "$files" ] || continue
  for v in crunch nocrunch pseudo; do mkdir -p "$OUT/compile-$v/$n"; done
  batch() { echo "$2" | xargs -n 300 "$AAPT2" compile $1 >> "$OUT/stdout.log" 2>> "$OUT/stderr.log"; echo "exit $? : compile $1" >> "$OUT/exit.log"; log "compile $1 <$n files>"; }
  batch "-v --legacy -o $OUT/compile-crunch/$n" "$files"
  batch "--legacy --no-crunch -o $OUT/compile-nocrunch/$n" "$files"
  values=$(echo "$files" | grep '/values[^/]*/' || true)
  [ -n "$values" ] && batch "--legacy --pseudo-localize -o $OUT/compile-pseudo/$n" "$values"
  mkdir -p "$OUT/compile-zip"
  run compile --dir "$d" -o "$OUT/compile-zip/$n.zip"
done

# Link everything together, as one app would. Later -R overlays earlier ones.
cat > "$OUT/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.direct"
    android:versionCode="7" android:versionName="1.2.3">
  <application android:label="@string/app_direct_label" android:icon="@android:drawable/sym_def_app_icon">
    <activity android:name=".Main" android:exported="true" android:theme="@android:style/Theme.Material.Light">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF
mkdir -p "$OUT/extra/values"
cat > "$OUT/extra/values/direct.xml" <<'EOF'
<resources>
  <string name="app_direct_label">Direct</string>
  <dimen name="d1">1.5dp</dimen><dimen name="d2">0.333333sp</dimen><dimen name="d3">-7.25px</dimen>
  <dimen name="d4">123456.789mm</dimen><dimen name="d6">1e-7in</dimen>
  <fraction name="f1">33.3333%</fraction><fraction name="f2">-0.001%p</fraction>
  <item name="fl1" type="dimen" format="float">0.1</item><item name="fl2" type="dimen" format="float">2.7182818</item>
  <integer name="i1">0x7fffffff</integer><integer name="i2">-2147483648</integer>
  <color name="c1">#80ff00ff</color><color name="c2">#abc</color>
  <bool name="b1">true</bool>
  <plurals name="p1"><item quantity="one">%d thing</item><item quantity="other">%d things</item></plurals>
  <string-array name="sa1"><item>a</item><item>b é \"q\" \n</item></string-array>
</resources>
EOF
mkdir -p "$OUT/compile-extra"
run compile --legacy -o "$OUT/compile-extra" "$OUT/extra/values/direct.xml"
run compile --legacy --pseudo-localize -o "$OUT/compile-extra-pseudo" "$OUT/extra/values/direct.xml" 2>/dev/null || true

flats() { find "$OUT/$1" -name '*.flat' | LC_ALL=C sort; }
flats compile-nocrunch > "$OUT/flats-nocrunch.txt"
echo "$OUT/compile-extra/values_direct.arsc.flat" >> "$OUT/flats-nocrunch.txt"
flats compile-crunch > "$OUT/flats-crunch.txt"
echo "$OUT/compile-extra/values_direct.arsc.flat" >> "$OUT/flats-crunch.txt"
R_NC="-R @$OUT/flats-nocrunch.txt"
R_CR="-R @$OUT/flats-crunch.txt"
COMMON="--auto-add-overlay -I $JAR --manifest $OUT/AndroidManifest.xml --no-static-lib-packages"

link_variant() {
  local name=$1; shift
  mkdir -p "$OUT/link/$name/java"
  # shellcheck disable=SC2086
  run link $COMMON "$@" -o "$OUT/link/$name/out.apk" --java "$OUT/link/$name/java" \
    --output-text-symbols "$OUT/link/$name/R.txt" --proguard "$OUT/link/$name/proguard.pro" \
    --proguard-main-dex "$OUT/link/$name/maindex.pro" --emit-ids "$OUT/link/$name/ids.txt"
}
# shellcheck disable=SC2086
link_variant binary-min21 --min-sdk-version 21 --target-sdk-version 36 $R_NC
# shellcheck disable=SC2086
link_variant binary-min26-crunch --min-sdk-version 26 $R_CR
# shellcheck disable=SC2086
link_variant binary-min33 --min-sdk-version 33 $R_NC
# shellcheck disable=SC2086
link_variant binary-sparse-compact --min-sdk-version 26 --enable-sparse-encoding --enable-compact-entries $R_NC
# shellcheck disable=SC2086
link_variant binary-debug-configs --min-sdk-version 24 --debug-mode -c en,de,xxhdpi --preferred-density xxhdpi --no-version-vectors $R_NC
# shellcheck disable=SC2086
link_variant proto-min21 --proto-format --min-sdk-version 21 $R_NC
# shellcheck disable=SC2086
link_variant proto-min33-debug --proto-format --debug-mode --min-sdk-version 33 $R_NC
# shellcheck disable=SC2086
link_variant staticlib --static-lib --custom-package com.example.lib $R_NC
mkdir -p "$OUT/link/nonfinal/java"
# shellcheck disable=SC2086
run link $COMMON --min-sdk-version 21 --non-final-ids $R_NC -o "$OUT/link/nonfinal/out.apk" --java "$OUT/link/nonfinal/java"

# Convert, optimize and dump the linked outputs.
mkdir -p "$OUT/convert" "$OUT/optimize" "$OUT/dump"
run convert --output-format binary -o "$OUT/convert/from-proto.apk" "$OUT/link/proto-min21/out.apk"
run convert --output-format proto -o "$OUT/convert/from-binary.apk" "$OUT/link/binary-min21/out.apk"
run convert --output-format binary --enable-sparse-encoding -o "$OUT/convert/from-proto-sparse.apk" "$OUT/link/proto-min33-debug/out.apk"
run optimize -o "$OUT/optimize/collapsed.apk" --collapse-resource-names "$OUT/link/binary-min26-crunch/out.apk"
run optimize -o "$OUT/optimize/shortened.apk" --shorten-resource-paths --resource-path-shortening-map "$OUT/optimize/map.txt" "$OUT/link/binary-min21/out.apk"
run optimize -o "$OUT/optimize/densities.apk" --target-densities xhdpi,xxxhdpi "$OUT/link/binary-min21/out.apk"
for f in binary-min21 binary-min33 proto-min21 staticlib; do
  "$AAPT2" dump resources "$OUT/link/$f/out.apk" > "$OUT/dump/$f-resources.txt" 2>&1
  "$AAPT2" dump strings "$OUT/link/$f/out.apk" > "$OUT/dump/$f-strings.txt" 2>&1
  "$AAPT2" dump configurations "$OUT/link/$f/out.apk" > "$OUT/dump/$f-configurations.txt" 2>&1
done
"$AAPT2" dump badging "$OUT/link/binary-min21/out.apk" > "$OUT/dump/badging.txt" 2>&1
"$AAPT2" dump xmltree --file AndroidManifest.xml "$OUT/link/binary-min21/out.apk" > "$OUT/dump/manifest-xmltree.txt" 2>&1
"$AAPT2" dump chunks "$OUT/link/binary-min33/out.apk" > "$OUT/dump/binary-min33-chunks.txt" 2>&1
for c in compile link dump optimize convert; do "$AAPT2" $c -h > "$OUT/dump/help-$c.txt" 2>&1; done
# A dimension too large for the complex encoding. Its float to integer conversion overflows, which
# x86_64 and arm64 resolve differently, so Google's own builds disagree here. Kept apart.
mkdir -p "$OUT/edge/values" "$OUT/edge-compiled"
echo '<resources><dimen name="huge">3.4028235e38dp</dimen></resources>' > "$OUT/edge/values/edge.xml"
"$AAPT2" compile -o "$OUT/edge-compiled" "$OUT/edge/values/edge.xml" 2>> "$OUT/edge-stderr.log"
"$AAPT2" dump resources "$OUT/edge-compiled/values_edge.arsc.flat" > "$OUT/edge-dump.txt" 2>&1
echo done > "$OUT/DONE"

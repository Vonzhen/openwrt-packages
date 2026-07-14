#!/bin/sh
set -eu

INPUT_DIR=${1:-/input}
WORKSPACE=${2:-/work}
PACKAGE_DIR="$WORKSPACE/packages"
PRIVATE_KEY="$WORKSPACE/repo_private_key.pem"
PUBLIC_KEY="$WORKSPACE/openwrt-packages-addon.pem"
BUILD_DIR=$(mktemp -d)
NORMALIZED_DIR="$BUILD_DIR/repository"
FETCH_DIR="$BUILD_DIR/fetched"
MANIFEST="$BUILD_DIR/manifest.tsv"
FINAL_MANIFEST="$BUILD_DIR/final-manifest.tsv"
INDEX_MANIFEST="$BUILD_DIR/index-manifest.tsv"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

fail() {
  echo "错误：$*" >&2
  exit 1
}

mkdir -p "$NORMALIZED_DIR" "$FETCH_DIR" "$BUILD_DIR/cache-untrusted"
test -s "$PRIVATE_KEY" || fail "仓库私钥不存在或为空"
test -s "$PUBLIC_KEY" || fail "仓库公钥不存在或为空"

set -- "$INPUT_DIR"/*.apk
test -e "$1" || fail "输入目录中没有 APK"

echo '==== 读取 APK v3 元数据并生成规范名称 ===='
: > "$MANIFEST"
for source in "$INPUT_DIR"/*.apk; do
  test -s "$source" || fail "发现空 APK：$source"

  metadata=$(apk adbdump --format json "$source") || fail "无法读取 APK v3 元数据：$source"
  name=$(printf '%s\n' "$metadata" | jq -er '.info.name | select(type == "string" and length > 0)') || fail "APK 缺少 name：$source"
  version=$(printf '%s\n' "$metadata" | jq -er '.info.version | select(type == "string" and length > 0)') || fail "APK 缺少 version：$source"
  arch=$(printf '%s\n' "$metadata" | jq -er '.info.arch | select(type == "string" and length > 0)') || fail "APK 缺少 arch：$source"

  case "$name:$version:$arch" in
    *[!A-Za-z0-9._+~:-]*) fail "元数据包含不安全字符：$name $version $arch" ;;
  esac
  case "$arch" in
    x86_64|noarch|all) ;;
    *) fail "不支持的架构 $arch：$source" ;;
  esac

  canonical="$name-$version.apk"
  target="$NORMALIZED_DIR/$canonical"
  if test -e "$target"; then
    cmp -s "$source" "$target" || fail "不同 APK 映射到同一规范名称：$canonical"
    echo "忽略内容相同的重复文件：$(basename "$source")"
    continue
  fi

  cp "$source" "$target"
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$arch" "$canonical" >> "$MANIFEST"
  echo "$(basename "$source") -> $canonical ($arch)"
done

echo '==== 在生成索引前清理旧版 Shinra ===='
shinra_count=$(awk -F '\t' '$1 == "luci-app-shinra" { count++ } END { print count + 0 }' "$MANIFEST")
if test "$shinra_count" -gt 1; then
  newest=
  while IFS="$(printf '\t')" read -r name version arch canonical; do
    test "$name" = 'luci-app-shinra' || continue
    if test -z "$newest" || test "$(apk version -t "$version" "$newest")" = '>'; then
      newest=$version
    fi
  done < "$MANIFEST"
  echo "保留 Shinra 版本：$newest"
  while IFS="$(printf '\t')" read -r name version arch canonical; do
    if test "$name" = 'luci-app-shinra' && test "$version" != "$newest"; then
      rm -f "$NORMALIZED_DIR/$canonical"
      echo "移除旧版：$canonical"
    fi
  done < "$MANIFEST"
fi

: > "$FINAL_MANIFEST"
while IFS="$(printf '\t')" read -r name version arch canonical; do
  test -e "$NORMALIZED_DIR/$canonical" || continue
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$arch" "$canonical" >> "$FINAL_MANIFEST"
done < "$MANIFEST"

echo '==== 校验最终包集合 ===='
for expected in 'sing-box:1:2' 'npc:1:1' 'luci-app-npc:1:1' 'luci-i18n-npc-zh-cn:1:1' 'luci-app-shinra:1:1'; do
  name=${expected%%:*}
  limits=${expected#*:}
  minimum=${limits%%:*}
  maximum=${limits##*:}
  count=$(awk -F '\t' -v package="$name" '$1 == package { count++ } END { print count + 0 }' "$FINAL_MANIFEST")
  test "$count" -ge "$minimum" && test "$count" -le "$maximum" || fail "$name 数量异常：$count"
done

echo '==== 生成并签名临时索引 ===='
(
  cd "$NORMALIZED_DIR"
  apk --allow-untrusted mkndx --sign "$PRIVATE_KEY" --output packages.adb.new ./*.apk
)
test -s "$NORMALIZED_DIR/packages.adb.new" || fail "临时索引为空"

apk adbdump --format json "$NORMALIZED_DIR/packages.adb.new" \
  | jq -er '.packages[] | [.name, .version, .arch, (.name + "-" + .version + ".apk")] | @tsv' \
  | sort > "$INDEX_MANIFEST"
cut -f1-4 "$FINAL_MANIFEST" | sort > "$BUILD_DIR/expected-index.tsv"
cmp -s "$BUILD_DIR/expected-index.tsv" "$INDEX_MANIFEST" || {
  echo '预期索引：' >&2
  cat "$BUILD_DIR/expected-index.tsv" >&2
  echo '实际索引：' >&2
  cat "$INDEX_MANIFEST" >&2
  fail "packages.adb 与最终 APK 集合不一致"
}

mv "$NORMALIZED_DIR/packages.adb.new" "$NORMALIZED_DIR/packages.adb"

echo '==== 启动本地 HTTP 仓库并等待就绪 ===='
busybox httpd -f -p 8080 -h "$NORMALIZED_DIR" &
HTTPD_PID=$!
ready=false
for delay in 1 1 2 3 5; do
  if wget -q -O "$BUILD_DIR/http-index.adb" http://127.0.0.1:8080/packages.adb; then
    ready=true
    break
  fi
  sleep "$delay"
done
test "$ready" = true || fail "本地 HTTP 仓库未能启动"
cmp -s "$NORMALIZED_DIR/packages.adb" "$BUILD_DIR/http-index.adb" || fail "HTTP 返回的索引内容不完整"

printf '%s\n' 'http://127.0.0.1:8080/packages.adb' > "$BUILD_DIR/repositories"

echo '==== 使用真实 apk 客户端逐版本下载（连通性） ===='
apk --repositories-file "$BUILD_DIR/repositories" --cache-dir "$BUILD_DIR/cache-untrusted" update --allow-untrusted
while IFS="$(printf '\t')" read -r name version arch canonical; do
  rm -f "$FETCH_DIR/$canonical"
  apk --repositories-file "$BUILD_DIR/repositories" \
    --cache-dir "$BUILD_DIR/cache-untrusted" \
    fetch --allow-untrusted --output "$FETCH_DIR" --pkgname-spec '${name}-${version}.apk' "$name=$version"
  test -s "$FETCH_DIR/$canonical" || fail "客户端未下载到 $canonical"
  cmp -s "$NORMALIZED_DIR/$canonical" "$FETCH_DIR/$canonical" || fail "HTTP 下载内容与源 APK 不一致：$canonical"
done < "$FINAL_MANIFEST"

echo '==== 使用仓库公钥验证索引签名 ===='
mkdir -p "$BUILD_DIR/keys" "$BUILD_DIR/cache-trusted" "$BUILD_DIR/fetched-trusted"
cp "$PUBLIC_KEY" "$BUILD_DIR/keys/openwrt-packages-addon.pem"
apk --repositories-file "$BUILD_DIR/repositories" \
  --keys-dir "$BUILD_DIR/keys" \
  --cache-dir "$BUILD_DIR/cache-trusted" update

first_name=$(awk -F '\t' 'NR == 1 { print $1 }' "$FINAL_MANIFEST")
first_version=$(awk -F '\t' 'NR == 1 { print $2 }' "$FINAL_MANIFEST")
apk --repositories-file "$BUILD_DIR/repositories" \
  --keys-dir "$BUILD_DIR/keys" \
  --cache-dir "$BUILD_DIR/cache-trusted" \
  fetch --output "$BUILD_DIR/fetched-trusted" --pkgname-spec '${name}-${version}.apk' "$first_name=$first_version"

kill "$HTTPD_PID"
wait "$HTTPD_PID" 2>/dev/null || true

echo '==== 所有验证通过，原子更新工作区发布目录 ===='
rm -f "$PACKAGE_DIR"/*.apk "$PACKAGE_DIR/packages.adb" "$PACKAGE_DIR/packages.adb.new"
cp "$NORMALIZED_DIR"/*.apk "$PACKAGE_DIR/"
cp "$NORMALIZED_DIR/packages.adb" "$PACKAGE_DIR/packages.adb"

echo '==== 最终发布清单 ===='
cat "$FINAL_MANIFEST"

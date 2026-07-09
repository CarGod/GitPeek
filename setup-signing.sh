#!/bin/bash
# 建一个固定的自签名代码签名证书，导入登录钥匙串。
# 之后 build.sh 用它签名，指纹稳定 → 辅助功能授权不会因重建而失效。
set -euo pipefail

IDENTITY="GitPeek Local"
DIR="$(dirname "$0")/.signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "已存在签名身份「$IDENTITY」，跳过。"
  exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = GitPeek Local
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 用系统 LibreSSL：它生成的 p12 用旧 MAC 算法，macOS security 才认
OPENSSL=/usr/bin/openssl

echo "==> 生成自签名证书"
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -config openssl.cnf >/dev/null 2>&1

echo "==> 打包成 p12"
"$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 \
  -passout pass:gitpeek -name "$IDENTITY" >/dev/null 2>&1

echo "==> 导入登录钥匙串（-A 允许任意程序使用，避免 codesign 反复弹密码）"
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
  -P gitpeek -A

# 清掉明文私钥文件
rm -f key.pem id.p12

echo "==> 完成。可用签名身份："
security find-identity -v -p codesigning | grep "$IDENTITY" || true

#!/usr/bin/env bash
# Workspace-only signing. No keychain import or OS trust changes.
# Sourced by the CLT builder only when ENHANCEMENT_LOCAL_SIGNING=1.
prepare_local_signing() {
  local signing_tools="$root/build/signing-tools"
  local archive="$signing_tools/rcodesign.tar.gz"
  local expected=d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a
  [[ "$(uname -m)" == arm64 ]] || { echo '固定本地签名工具仅支持 arm64。' >&2; return 2; }
  mkdir -p "$signing_tools"
  if [[ ! -f "$archive" ]]; then
    /usr/bin/curl -fL --retry 2 -o "$archive" 'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/apple-codesign-0.29.0-aarch64-apple-darwin.tar.gz'
  fi
  [[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" == "$expected" ]] || { echo '签名工具 SHA256 不匹配。' >&2; return 2; }
  /usr/bin/tar -xzf "$archive" -C "$signing_tools"
  local_signer="$signing_tools/apple-codesign-0.29.0-aarch64-apple-darwin/rcodesign"
  local_signing_directory="${ENHANCEMENT_LOCAL_SIGNING_DIRECTORY:-$root/build/local-signing}"
  [[ "$local_signing_directory" == "$root/build/"* && ! -L "$local_signing_directory" ]] || { echo '本地签名目录必须在工作区 build 下。' >&2; return 2; }
  mkdir -p "$local_signing_directory"; chmod 700 "$local_signing_directory"
  if [[ ! -e "$local_signing_directory/local.crt" && ! -e "$local_signing_directory/local.key" ]]; then
    cat > "$local_signing_directory/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = Squirrel Enhanced Local Build
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CONFIG
    (umask 077; /usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
      -config "$local_signing_directory/openssl.cnf" -keyout "$local_signing_directory/local.key" -out "$local_signing_directory/local.crt")
  fi
  [[ -f "$local_signing_directory/local.key" && ! -L "$local_signing_directory/local.key" && -f "$local_signing_directory/local.crt" && ! -L "$local_signing_directory/local.crt" ]] || { echo '本地签名材料不完整；不覆盖已有证书。' >&2; return 2; }
  chmod 600 "$local_signing_directory/local.key"
  local_certificate_sha1="$(/usr/bin/openssl x509 -in "$local_signing_directory/local.crt" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//;s/://g')"
  [[ "$local_certificate_sha1" =~ ^[A-Fa-f0-9]{40}$ ]] || return 2
  export local_certificate_sha1
}
sign_local_code() {
  "$local_signer" -C /dev/null sign --shallow --exclude '**' --timestamp-url none \
    --pem-file "$local_signing_directory/local.crt" --pem-file "$local_signing_directory/local.key" \
    --code-signature-flags runtime --entitlements-xml-file "$2" "$1"
}

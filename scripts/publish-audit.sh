#!/bin/bash
# Pre-publication audit: scans the whole git history for secrets, personal
# paths, e-mail addresses, large blobs and traces of real data.
# Exit 0 = clean, 1 = findings. Your own /Users/<you>/ paths are listed
# separately and do not fail the run. Secret values are never printed in full.
# Works with macOS default tools (bash 3.2, BSD grep/awk).
set -euo pipefail

# Byte semantics: macOS awk aborts on bytes that are not valid UTF-8 (Latin-1 files, binaries). All patterns are ASCII.
export LC_ALL=C

OWNER_USER="${AUDIT_OWNER_USER:-$(id -un)}"
# Known addresses: the one configured in git, AUDIT_OWNER_EMAILS (comma-separated), and every author already in the
# history being scanned, so a contributor's run does not fail on the maintainer's address. Nothing is hardcoded here.
OWNER_EMAILS="$(git config user.email 2>/dev/null || true),${AUDIT_OWNER_EMAILS:-},$(git log --all --format=%ae 2>/dev/null | sort -u | paste -sd, - || true)"
MAX_BYTES=$((1024 * 1024))
# README images: PNGs under .github/assets/ may be up to 2 MB (see the allow-list below).
IMG_MAX_BYTES=$((2 * 1024 * 1024))

# ---------------------------------------------------------------------------
# Allow-list: known synthetic fixtures. Hits are NOT failures, but they are
# still printed in their own informational section. Keep this list narrow.
# ---------------------------------------------------------------------------
# E-mail domains that are fictional ("ornek" is Turkish for "example").
ALLOW_MAIL_DOMAINS="ornek.dev"
# Exact e-mail-looking test strings.
ALLOW_MAIL_EXACT="video.example@evil.com"
# Fake home folders used in tests and docs; exactly these, followed by "/".
ALLOW_USER_PATHS="x,me,baskasi"
# A real e-mail that must stay: the upstream MIT copyright line. Path AND address.
ALLOW_MAIL_PATH="THIRD_PARTY_NOTICES.md"
ALLOW_MAIL_PATH_ADDR="sindresorhus""@gmail.com"   # split so this line is not itself an address
# The one known secret false positive: a JS URL polyfill assigning a regex
# group to `this.password`. Allowed only when BOTH the file name and the exact
# text match, and only if the line has no other secret-looking content.
ALLOW_SECRET_FILE="WebPolyfills.swift"
ALLOW_SECRET_TEXT='this.pass''word = m[3]'

cd "$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AL="$TMP/allowed"; : > "$AL"
SECRETS="$TMP/secrets"; PATHS="$TMP/paths"; OWN="$TMP/own"; MAILS="$TMP/mails"
BIG="$TMP/big"; TRACES="$TMP/traces"
: > "$SECRETS"; : > "$PATHS"; : > "$OWN"; : > "$MAILS"; : > "$BIG"; : > "$TRACES"

SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|[A-Za-z0-9_./-]+[.](p12|p8)([^A-Za-z0-9]|$)|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]*='
# Matched against LOWERCASED paths, so every literal here must be lowercase.
TRACE_RE='(^|/)(\.superpowers|deriveddata)/|\.xcuserstate$|\.sqlite$|(^|/)paste[^/]*\.db$|[.](p12|p8|pfx|pem|key|mobileprovision|cer|keychain)$'

# Single pass over the full patch history. Only added lines ("+") are looked at.
# Output lines: kind <TAB> commit <TAB> path <TAB> excerpt
git log -p --all --no-color --no-ext-diff --format='@@COMMIT %h' | awk -v SRE="$SECRET_RE" -v OWNER="$OWNER_USER" -v AMP="$ALLOW_MAIL_PATH" -v AMA="$ALLOW_MAIL_PATH_ADDR" -v AMD="$ALLOW_MAIL_DOMAINS" -v AME="$ALLOW_MAIL_EXACT" -v AUP="$ALLOW_USER_PATHS" -v ASF="$ALLOW_SECRET_FILE" -v AST="$ALLOW_SECRET_TEXT" '
function mask(s, re,   m) {            # replace each secret match by first 4 chars + "…"
  out = ""
  while (match(s, re)) {
    m = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1) substr(m, 1, 4) "…"
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function inlist(v, list,   a, n, i) { n = split(list, a, ","); for (i = 1; i <= n; i++) if (a[i] == v) return 1; return 0 }
function secret_allowed(line, path,   rest, i) {
  if (path !~ ("(^|/)" ASF "$")) return 0
  i = index(line, AST); if (i == 0) return 0
  rest = substr(line, 1, i - 1) substr(line, i + length(AST))
  return (match(rest, SRE) == 0)
}
# Header state is explicit: "+++ "/"--- " are file headers only between a
# "diff --git" line and the first "@@ -" hunk line. Inside a hunk every "+" line is content.
/^@@COMMIT / { commit = $2; inhdr = 0; next }
/^diff --git / { inhdr = 1; next }
/^@@ -/ { inhdr = 0; next }
inhdr && /^\+\+\+ / { path = substr($0, 7); if ($0 == "+++ /dev/null") path = ""; next }
inhdr && /^--- / { next }
/^\+/ {
  line = substr($0, 2)
  if (match(line, SRE)) {
    kind = secret_allowed(line, path) ? "allowsecret" : "secret"
    printf "%s\t%s\t%s\t%s\n", kind, commit, path, substr(mask(line, SRE), 1, 160)
  }
  rest = line
  while (match(rest, /\/Users\/[A-Za-z0-9._-]+/)) {
    name = substr(rest, RSTART + 7, RLENGTH - 7)
    kind = (name == OWNER) ? "own" : "path"
    if (kind == "path" && inlist(name, AUP) && substr(rest, RSTART + RLENGTH, 1) == "/") kind = "allowpath"
    printf "%s\t%s\t%s\t/Users/%s/…\n", kind, commit, path, name
    rest = substr(rest, RSTART + RLENGTH)
  }
  rest = line
  while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/)) {
    addr = substr(rest, RSTART, RLENGTH)
    sub(/^[-.+_%]+/, "", addr)   # drop leading punctuation, e.g. from ${VAR:-name@host}
    dom = addr; sub(/^.*@/, "", dom)
    kind = (inlist(dom, AMD) || inlist(addr, AME) || (path == AMP && addr == AMA)) ? "allowmail" : "mail"
    printf "%s\t%s\t%s\t%s\n", kind, commit, path, addr
    rest = substr(rest, RSTART + RLENGTH)
  }
}
' > "$TMP/raw"

awk -F'\t' -v d="$TMP" '{ print > (d "/raw_" $1) }' "$TMP/raw"
[ -f "$TMP/raw_secret" ] && sort -u "$TMP/raw_secret" > "$SECRETS"
[ -f "$TMP/raw_path" ] && sort -u "$TMP/raw_path" > "$PATHS"
for k in allowsecret allowpath allowmail; do
  [ -f "$TMP/raw_$k" ] && cat "$TMP/raw_$k" >> "$AL"
done
sort -u "$AL" -o "$AL"
[ -f "$TMP/raw_own" ] && sort -u "$TMP/raw_own" > "$OWN"
if [ -f "$TMP/raw_mail" ]; then
  # Addresses other than the owner's, and obvious non-addresses (@2x image names, noreply etc. stay reported).
  sort -u "$TMP/raw_mail" | awk -F'\t' -v ok="$OWNER_EMAILS" 'BEGIN{n=split(ok,a,",");for(i=1;i<=n;i++)allow[a[i]]=1} !($4 in allow)' > "$MAILS"
fi

# Commit author / committer addresses.
git log --all --format='%h%x09%ae%x09%ce' | awk -F'\t' -v ok="$OWNER_EMAILS" '
  BEGIN{n=split(ok,a,",");for(i=1;i<=n;i++)allow[a[i]]=1}
  { if(!($2 in allow)) printf "mail\t%s\t(author)\t%s\n",$1,$2
    if(!($3 in allow)) printf "mail\t%s\t(committer)\t%s\n",$1,$3 }' | sort -u >> "$MAILS"

# Large blobs and suspicious paths, from every object reachable from any ref.
git rev-list --objects --all | awk 'NF>=2 { sha=$1; $1=""; sub(/^ /,""); print sha "\t" $0 }' > "$TMP/objs"
# Map blob -> first commit that introduced the path.
first_commit() { git log --all --format=%h --diff-filter=A -- "$1" 2>/dev/null | tail -1; }
# A file, not process substitution: a failing git cat-file must fail the run (set -e does not see a <(...) producer).
awk -F'\t' '{print $1}' "$TMP/objs" | git cat-file --batch-check='%(objectname) %(objectsize)' | awk '{print $1 "\t" $2}' > "$TMP/sizes"
while IFS=$'\t' read -r sha size; do
  [ "$size" -gt "$MAX_BYTES" ] || continue
  p="$(awk -F'\t' -v s="$sha" '$1==s{print $2; exit}' "$TMP/objs")"
  # Allowed: a PNG directly or deeper under .github/assets/, up to IMG_MAX_BYTES. Anything bigger or elsewhere is reported.
  case "$p" in
    .github/assets/*.png)
      if [ "$size" -le "$IMG_MAX_BYTES" ]; then
        printf 'allow\t%s\t%s\t%s bytes (README image, up to 2 MB)\n' "$(first_commit "$p")" "$p" "$size" >> "$AL"
        continue
      fi ;;
  esac
  printf 'big\t%s\t%s\t%s bytes\n' "$(first_commit "$p")" "$p" "$size" >> "$BIG"
done < "$TMP/sizes"
sort -u "$BIG" -o "$BIG"

awk -F'\t' -v re="$TRACE_RE" 'tolower($2) ~ re { print $2 }' "$TMP/objs" | sort -u | while IFS= read -r p; do
  printf 'trace\t%s\t%s\t(tracked path in history)\n' "$(first_commit "$p")" "$p" >> "$TRACES"
done

findings=0
report() { # title file
  local n; n=$(wc -l < "$2" | tr -d ' ')
  echo "== $1: $n"
  if [ "$n" -gt 0 ]; then
    awk -F'\t' '{ printf "  %s  %s  %s\n", $2, $3, $4 }' "$2"
    findings=$((findings + n))
  fi
}

echo "publish-audit: $(git rev-list --all | wc -l | tr -d ' ') commits, $(wc -l < "$TMP/objs" | tr -d ' ') objects"
report "Secret patterns" "$SECRETS"
report "Personal paths (other users)" "$PATHS"
report "E-mail addresses (not the author's)" "$MAILS"
report "Blobs over 1 MB" "$BIG"
report "Traces of real data / paths that must not be tracked" "$TRACES"

n_al=$(wc -l < "$AL" | tr -d ' ')
echo "== Allow-listed synthetic fixtures (informational, does not fail): $n_al"
awk -F'\t' '{ printf "  %s  %s  %s\n", $2, $3, $4 }' "$AL"

n_own=$(wc -l < "$OWN" | tr -d ' ')
echo "== Your own paths (/Users/$OWNER_USER...; informational, does not fail): $n_own"
awk -F'\t' '{ c[$3]++ } END { for (p in c) printf "  %s  (%d lines)\n", p, c[p] }' "$OWN" | sort

if [ "$findings" -gt 0 ]; then
  echo "RESULT: $findings finding(s)"
  exit 1
fi
echo "RESULT: clean"

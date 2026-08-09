#!/usr/bin/env bash
#
# Verify the CAUE 77 advisory PDF that `tree-climate extract` reads.
#
# The document is not redistributed here: it remains the property of the CAUE de
# Seine-et-Marne. And it cannot be downloaded automatically either — the
# publisher offers only a Calameo reader, its /download endpoint answers with an
# HTML page, and the caue77.fr sitemap exposes no PDF at all.
#
# So this script verifies the input rather than fetching it. That is enough to
# make the extraction reproducible: a checksum mismatch means the source
# document changed, and the column bounds in src/pdf/table.zig must be revisited
# before the output can be trusted.

set -euo pipefail

readonly PDF="docs/CAUE77-2026-Arbre-fiche-conseil-plantations-fiche.pdf"
readonly EXPECTED="e39b72578f3cc1a3bd5d2186b658d0f35d955a30f55534f00828d0c3e6e0cea0"
readonly PRESENTATION="https://sfa-asso.fr/realiser-des-plantations-adaptees-aux-changements-climatiques-caue77/"
readonly READER="https://www.calameo.com/caue77/read/00598818161c83dc963fb"

cd "$(dirname "$0")/.."

digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

if [[ ! -f $PDF ]]; then
    cat >&2 <<EOF
missing: $PDF

There is no direct download. Obtain the file by hand and save it at the path
above, then run this script again:

  presentation  $PRESENTATION
  reader        $READER

EOF
    exit 1
fi

actual=$(digest "$PDF")
if [[ $actual != "$EXPECTED" ]]; then
    cat >&2 <<EOF
checksum mismatch: $PDF
  expected  $EXPECTED
  actual    $actual

The source document is not the one the extraction was written against. Review
the column bounds in src/pdf/table.zig before regenerating data/data.json.
EOF
    exit 1
fi

echo "$PDF verified (sha256 $actual)"

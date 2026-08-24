#!/bin/sh
# Rebuild Vendor/CtreesitterParsers.xcframework from pinned tree-sitter grammar releases,
# and refresh the query files under Resources/TreeSitter/ that ride along with them.
#
# This vendors the *parsers only* — the tree-sitter runtime itself arrives through
# SwiftTreeSitter (an SPM dependency, like SwiftTerm), and a grammar's generated parser.c
# calls nothing in it, so the two link cleanly from their two directions. Each grammar's
# release tarball is self-contained: the generated parser.c (never regenerated here — no
# Node, no tree-sitter CLI), the hand-written scanner.c, the tree_sitter/parser.h it
# compiles against, and the queries. The result is a committed static asset (like
# Clibgit2.xcframework): the build is not part of xcodebuild — run this by hand to bump
# a version or add a language, then add the language's extern to the generated header
# list below.
set -eu

# One line per vendored parser: name|symbol|version|tarball|subdirectory.
#
# `name` is what a file's language is called here and the directory its queries land in;
# `symbol` is the C entry point the grammar exports, which is not always the name (`c-sharp`
# exports `tree_sitter_c_sharp`). `subdirectory` is empty for a grammar that sits at the root
# of its repository and set for the ones that ship several — TypeScript carries `tsx` beside it,
# Markdown splits into block and inline — where `src` and `queries` are one level down.
#
# Three sources, because there is no one place that has them all: the tree-sitter organization
# maintains most of these, the community `tree-sitter-grammars` organization has YAML and
# Markdown (which the first has never had), and Swift's official grammar was archived in 2022,
# so the live one is alex-pinkus's. That grammar is also the only one whose generated parser
# ships in a *release* rather than in the repository, which is why its URL is a release asset
# and everything else is a tag archive.
GRAMMARS="
swift|swift|0.7.3|https://github.com/alex-pinkus/tree-sitter-swift/releases/download/0.7.3/tree-sitter-swift.tar.gz|
bash|bash|v0.25.1|https://github.com/tree-sitter/tree-sitter-bash/archive/refs/tags/v0.25.1.tar.gz|
c|c|v0.24.2|https://github.com/tree-sitter/tree-sitter-c/archive/refs/tags/v0.24.2.tar.gz|
cpp|cpp|v0.23.4|https://github.com/tree-sitter/tree-sitter-cpp/archive/refs/tags/v0.23.4.tar.gz|
c-sharp|c_sharp|v0.23.5|https://github.com/tree-sitter/tree-sitter-c-sharp/archive/refs/tags/v0.23.5.tar.gz|
go|go|v0.25.0|https://github.com/tree-sitter/tree-sitter-go/archive/refs/tags/v0.25.0.tar.gz|
javascript|javascript|v0.25.0|https://github.com/tree-sitter/tree-sitter-javascript/archive/refs/tags/v0.25.0.tar.gz|
json|json|v0.24.8|https://github.com/tree-sitter/tree-sitter-json/archive/refs/tags/v0.24.8.tar.gz|
python|python|v0.25.0|https://github.com/tree-sitter/tree-sitter-python/archive/refs/tags/v0.25.0.tar.gz|
ruby|ruby|v0.23.1|https://github.com/tree-sitter/tree-sitter-ruby/archive/refs/tags/v0.23.1.tar.gz|
rust|rust|v0.24.2|https://github.com/tree-sitter/tree-sitter-rust/archive/refs/tags/v0.24.2.tar.gz|
typescript|typescript|v0.23.2|https://github.com/tree-sitter/tree-sitter-typescript/archive/refs/tags/v0.23.2.tar.gz|typescript
tsx|tsx|v0.23.2|https://github.com/tree-sitter/tree-sitter-typescript/archive/refs/tags/v0.23.2.tar.gz|tsx
yaml|yaml|v0.7.2|https://github.com/tree-sitter-grammars/tree-sitter-yaml/archive/refs/tags/v0.7.2.tar.gz|
markdown|markdown|v0.5.3|https://github.com/tree-sitter-grammars/tree-sitter-markdown/archive/refs/tags/v0.5.3.tar.gz|tree-sitter-markdown
markdown-inline|markdown_inline|v0.5.3|https://github.com/tree-sitter-grammars/tree-sitter-markdown/archive/refs/tags/v0.5.3.tar.gz|tree-sitter-markdown-inline
"

ARCHS="arm64 x86_64"
DEPLOYMENT_TARGET="15.0"
# Only the definitions SwiftTreeSitter's loader knows by name; it compiles every .scm it
# finds, so an exotic query file (textobjects, outline) would only be a way to fail launch.
QUERIES="highlights.scm locals.scm injections.scm"

HERE="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="$HERE/../Resources/TreeSitter"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The headers live one directory down so this xcframework's module map cannot collide with
# Clibgit2's when Xcode copies both into the shared Products include/ directory; the target's
# SWIFT_INCLUDE_PATHS points into the subdirectory.
HEADERS="$WORK/headers"
mkdir -p "$HEADERS/CtreesitterParsers"
HEADER="$HEADERS/CtreesitterParsers/parsers.h"
cat > "$HEADER" <<'HEADER_TOP'
#ifndef CTREESITTER_PARSERS_H
#define CTREESITTER_PARSERS_H

// The vendored tree-sitter language parsers. TSLanguage stays opaque here — the real
// definition lives in the tree-sitter runtime SwiftTreeSitter brings in, and Swift only
// ever passes these pointers through to it.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

HEADER_TOP

echo "$GRAMMARS" | while IFS='|' read -r name symbol version url subdir; do
  [ -n "$name" ] || continue

  echo "==> Fetching tree-sitter-$name $version"
  rm -rf "$WORK/src/$name" && mkdir -p "$WORK/src/$name"
  curl -fsSL "$url" | tar xz -C "$WORK/src/$name"
  # A tag archive wraps everything in one <repo>-<version>/ directory; the Swift release
  # tarball does not. Descend if what came out is that single wrapper rather than the grammar.
  TOP="$WORK/src/$name"
  if [ ! -d "$TOP/src" ] && [ "$(ls "$TOP" | wc -l)" -eq 1 ]; then
    TOP="$TOP/$(ls "$TOP")"
  fi
  ROOT="$TOP${subdir:+/$subdir}"
  SRC="$ROOT/src"
  [ -f "$SRC/parser.c" ] || { echo "no generated parser.c in $SRC" >&2; exit 1; }

  for arch in $ARCHS; do
    echo "==> Compiling tree-sitter-$name ($arch)"
    mkdir -p "$WORK/obj/$arch"
    for c in "$SRC"/*.c; do
      clang -c -O2 -arch "$arch" -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -I "$SRC" "$c" -o "$WORK/obj/$arch/$name-$(basename "$c" .c).o"
    done
  done

  echo "const TSLanguage *tree_sitter_$symbol(void);" >> "$HEADER"

  # Where a multi-grammar repository keeps its queries is its own business: Markdown gives each
  # of its two grammars a directory of their own, while TypeScript shares one set at the top for
  # itself and TSX. Take the grammar's own if it has one, the repository's otherwise.
  QUERYDIR="$ROOT/queries"
  [ -d "$QUERYDIR" ] || QUERYDIR="$TOP/queries"

  echo "==> Copying queries to Resources/TreeSitter/$name/queries"
  rm -rf "$RESOURCES/$name"
  mkdir -p "$RESOURCES/$name/queries"
  for q in $QUERIES; do
    [ -f "$QUERYDIR/$q" ] && cp "$QUERYDIR/$q" "$RESOURCES/$name/queries/"
  done
  [ -f "$RESOURCES/$name/queries/highlights.scm" ] || {
    echo "no highlights.scm for $name (looked in $QUERYDIR)" >&2
    exit 1
  }
done

# Some grammars' queries are written to be laid *on top of* another language's rather than to
# stand alone: C++'s highlights carry what C++ adds to C and nothing that C already said, and
# TypeScript's carry the type syntax JavaScript has no word for. Upstream expects the consumer
# to combine them — an editor that loads C++'s file by itself colours a keyword here and there
# and leaves every declaration grey. Concatenated base-first, so the more specific pattern is
# the later one and wins where the two overlap.
BASES="cpp:c typescript:javascript tsx:javascript"
for pair in $BASES; do
  lang="${pair%%:*}"
  base="${pair#*:}"
  echo "==> Laying $lang's highlights over $base's"
  cat "$RESOURCES/$base/queries/highlights.scm" "$RESOURCES/$lang/queries/highlights.scm" \
    > "$WORK/combined.scm"
  mv "$WORK/combined.scm" "$RESOURCES/$lang/queries/highlights.scm"
done

cat >> "$HEADER" <<'HEADER_BOTTOM'

#ifdef __cplusplus
}
#endif

#endif
HEADER_BOTTOM

cat > "$HEADERS/CtreesitterParsers/module.modulemap" <<'MODULEMAP'
module CtreesitterParsers {
    header "parsers.h"
    export *
}
MODULEMAP

echo "==> Archiving"
LIBS=""
for arch in $ARCHS; do
  libtool -static -o "$WORK/obj/$arch.a" "$WORK/obj/$arch"/*.o
  LIBS="$LIBS $WORK/obj/$arch.a"
done
# shellcheck disable=SC2086
lipo -create $LIBS -output "$WORK/libtree-sitter-parsers.a"

echo "==> Packaging CtreesitterParsers.xcframework"
rm -rf "$HERE/CtreesitterParsers.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/libtree-sitter-parsers.a" -headers "$HEADERS" \
  -output "$HERE/CtreesitterParsers.xcframework"

echo "==> Done: $HERE/CtreesitterParsers.xcframework"

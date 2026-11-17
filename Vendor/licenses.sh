# Sourced by the Vendor scripts. Everything hukan ships that it did not write carries a license
# whose terms include shipping its text, so each script that fetches such a source also writes that
# source's license into Resources/Licenses, which the app bundles as it is (docs/build.md).

LICENSES="$(cd "$(dirname "$0")/.." && pwd)/Resources/Licenses"

# write_license NAME VERSION URL FILE — NAME.txt: what it is, where from, then the text verbatim.
write_license() {
  [ -f "$4" ] || { echo "no license file at $4" >&2; exit 1; }
  mkdir -p "$LICENSES"
  { printf '%s %s\n%s\n\n' "$1" "$2" "$3"; cat "$4"; } > "$LICENSES/$1.txt"
}

#!/usr/bin/env bash
# Export an allowlisted snapshot of this repository into a clone of the public repository and commit it there.
#   scripts/publish-public.sh <path-to-public-clone> [--message "..."] [--dry-run]
#
#   --message "..."  commit message (default: "Sync v<VERSION> (source <short sha>)")
#   --dry-run        build the export, run the privacy gate, show the file list and what would change in the
#                    clone; touch nothing in the clone and commit nothing
#
# How it works
#   1. Takes the committed state (HEAD) of this repository, never the working tree, so scratch files and
#      uncommitted edits cannot leak. A warning is printed when allowlisted paths have uncommitted changes.
#   2. Copies only the ALLOWLIST below into a temporary directory. scripts/public/.gitignore becomes .gitignore;
#      the rest of scripts/public/ (the denylist!) is private and is not exported.
#   3. Runs the privacy gate (scripts/public/denylist.txt) on that directory, on the commit message and on the commit
#      author identity. Any hit prints file:line and exits 1 before the clone is touched.
#   4. Replaces the clone's contents with the export (everything except .git, .build and .swiftpm is replaced, so
#      files that are no longer allowlisted disappear), then runs `git add -A && git commit`. It never pushes.
#      The author comes from the clone's own git config.
# The clone must be a clean git work tree with its own identity (e.g. a GitHub noreply address).
set -euo pipefail

# Paths relative to the repository root. Missing paths are skipped with a note.
ALLOWLIST="Package.swift Package.resolved VERSION Sources Tests scripts .github README.md README.ko.md LICENSE CONTRIBUTING.md docs/images"
PRIVATE_DIR="scripts/public"   # not exported, except its .gitignore, which is exported as /.gitignore

usage() { sed -n '2,5p' "$0"; }
die() { echo "error: $*" >&2; exit 1; }

TARGET_ARG="" MESSAGE="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) [[ $# -ge 2 ]] || die "--message needs a value"; MESSAGE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [[ -z "$TARGET_ARG" ]] || die "unexpected argument: $1"; TARGET_ARG="$1"; shift ;;
  esac
done
[[ -n "$TARGET_ARG" ]] || { usage >&2; exit 2; }

SRC="$(cd "$(dirname "$0")/.." && git rev-parse --show-toplevel)"
SRC="$(cd "$SRC" && pwd -P)"
DENYLIST="$SRC/$PRIVATE_DIR/denylist.txt"
[[ -f "$DENYLIST" ]] || die "$PRIVATE_DIR/denylist.txt not found: this script only runs from the private source repository"

[[ -d "$TARGET_ARG" ]] || die "not a directory: $TARGET_ARG"
TARGET="$(cd "$TARGET_ARG" && pwd -P)"
[[ "$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)" == "$TARGET" ]] \
  || die "$TARGET is not the top level of a git work tree (git clone the public repository first)"
case "$TARGET/" in "$SRC"/*|"/"|"$HOME/") die "refusing to publish into $TARGET" ;; esac
case "$SRC/" in "$TARGET"/*) die "refusing to publish into a directory that contains the source repository" ;; esac
if [[ "$DRY_RUN" == 0 && -n "$(git -C "$TARGET" status --porcelain)" ]]; then
  die "$TARGET has uncommitted changes; commit or discard them first (an export replaces the whole tree)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jtm-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SNAP="$WORK/snapshot"; STAGE="$WORK/export"
mkdir -p "$SNAP" "$STAGE"

SRC_SHA="$(git -C "$SRC" rev-parse --short=7 HEAD)"
DIRTY="$(git -C "$SRC" status --porcelain -- $ALLOWLIST | wc -l | tr -d ' ')"
git -C "$SRC" archive HEAD | tar -x -C "$SNAP"

echo "==> exporting $SRC @ $SRC_SHA"
if [[ "$DIRTY" != 0 ]]; then
  echo "warning: $DIRTY allowlisted path(s) have uncommitted changes in the source repository; only HEAD is exported" >&2
fi

for path in $ALLOWLIST; do
  if [[ -e "$SNAP/$path" ]]; then
    mkdir -p "$STAGE/$(dirname "$path")"
    cp -R "$SNAP/$path" "$STAGE/$path"
  else
    echo "note: $path is not in HEAD, skipped"
  fi
done
[[ -f "$SNAP/$PRIVATE_DIR/.gitignore" ]] || die "$PRIVATE_DIR/.gitignore (the public .gitignore template) is missing in HEAD"
rm -rf "${STAGE:?}/$PRIVATE_DIR"
cp "$SNAP/$PRIVATE_DIR/.gitignore" "$STAGE/.gitignore"
# Scratch files that should never be exported even if tracked.
find "$STAGE" \( -name .DS_Store -o -name '*.swp' -o -name '*~' -o -name '*.orig' -o -name '*.rej' -o -name '*.log' \) -type f -delete
find "$STAGE" \( -name .omc -o -name .build \) -type d -prune -exec rm -rf {} +

VERSION_TEXT=""
[[ -f "$STAGE/VERSION" ]] && VERSION_TEXT="$(tr -d '[:space:]' < "$STAGE/VERSION")"
if [[ -z "$MESSAGE" ]]; then
  MESSAGE="Sync${VERSION_TEXT:+ v$VERSION_TEXT} (source $SRC_SHA)"
fi

# --- privacy gate -------------------------------------------------------------------------------------------------
cat > "$WORK/scan.pl" <<'PERL'
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

my ($deny_file, $list_file) = @ARGV;
my (@content, @paths, %removed);
open my $deny, '<', $deny_file or die "cannot read $deny_file: $!\n";
while (my $rule = <$deny>) {
    $rule =~ s/^\s+|\s+$//g;
    next if $rule eq '' || $rule =~ /^#/;
    if    ($rule =~ /^re:(.+)$/s)             { push @content, [$1, qr/$1/i] }
    elsif ($rule =~ /^path:(.+)$/s)           { push @paths,   [$1, qr/$1/i] }
    elsif ($rule =~ /^hash:([0-9a-f]{64})$/i) { $removed{lc $1} = 1 }
    else                                      { die "bad denylist line: $rule\n" }
}
close $deny;

open my $list, '<:raw', $list_file or die "cannot read $list_file: $!\n";
my @files = do { local $/ = "\0"; map { s/^\.\///r } grep { length } map { chomp; $_ } <$list> };
close $list;

my $hits = 0;
sub report { my ($where, $what) = @_; $what = substr($what, 0, 70) . '...' if length $what > 73; print "  $where: $what\n"; $hits++ }

for my $file (sort @files) {
    for my $rule (@paths) { report($file, "path matches [path:$rule->[0]]") if $file =~ $rule->[1] }
    open my $in, '<:raw', $file or do { report($file, 'unreadable'); next };
    while (my $line = <$in>) {
        for my $rule (@content) {
            report("$file:$.", "'$&' [re:$rule->[0]]") if $line =~ $rule->[1];
        }
        for my $token ($line =~ /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|\b[0-9a-f]{32}\b/gi) {
            my $digest = sha256_hex(lc $token);
            report("$file:$.", "removed real identifier [sha256 " . substr($digest, 0, 8) . "]") if $removed{$digest};
        }
    }
    close $in;
}
exit($hits ? 1 : 0);
PERL

# gate_scan <dir>: scan every file under <dir> (paths relative to it). Prints hits; returns 1 if any.
gate_scan() {
  ( cd "$1" && find . -type f -not -path './.git/*' -print0 > "$WORK/files.lst" && perl "$WORK/scan.pl" "$DENYLIST" "$WORK/files.lst" )
}

echo "==> privacy gate"
GATE_FAILED=0
if ! gate_scan "$STAGE"; then GATE_FAILED=1; fi

# The commit message and the author identity are public too.
IDENT_DIR="$WORK/ident"; mkdir -p "$IDENT_DIR"
printf '%s\n' "$MESSAGE" > "$IDENT_DIR/commit-message"
if AUTHOR="$(git -C "$TARGET" var GIT_AUTHOR_IDENT 2>/dev/null)"; then
  printf '%s\n' "$AUTHOR" > "$IDENT_DIR/commit-author"
  AUTHOR_SHOWN="${AUTHOR%> *}>"
else
  echo "  commit-author: no git identity in $TARGET (set user.name / user.email there)"
  GATE_FAILED=1; AUTHOR_SHOWN="(none)"
fi
if ! gate_scan "$IDENT_DIR"; then GATE_FAILED=1; fi

if [[ "$GATE_FAILED" != 0 ]]; then
  echo "error: privacy gate failed; the clone was not touched and nothing was committed" >&2
  exit 1
fi
FILE_COUNT="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
echo "  passed ($FILE_COUNT files, author $AUTHOR_SHOWN)"

# --- preview of what changes in the clone (works on a throwaway clone, so the real one is not touched) -------------
PREVIEW="$WORK/preview"
git clone -q --no-hardlinks "$TARGET" "$PREVIEW" 2>/dev/null
find "$PREVIEW" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R "$STAGE"/. "$PREVIEW"/
git -C "$PREVIEW" add -A
CHANGES="$(git -C "$PREVIEW" diff --cached --name-status | wc -l | tr -d ' ')"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "==> files that would be exported ($FILE_COUNT)"
  ( cd "$STAGE" && find . -type f | sed 's|^\./||' | sort | sed 's/^/  /' )
  echo "==> change in $TARGET (message: \"$MESSAGE\")"
  if [[ "$CHANGES" == 0 ]]; then
    echo "  none, the clone is already up to date"
  else
    git -C "$PREVIEW" diff --cached --stat | sed 's/^/  /'
  fi
  echo "dry-run: the gate passed; nothing was written to $TARGET and nothing was committed"
  exit 0
fi

# --- write the clone and commit ---------------------------------------------------------------------------------
find "$TARGET" -mindepth 1 -maxdepth 1 ! -name .git ! -name .build ! -name .swiftpm -exec rm -rf {} +
cp -R "$STAGE"/. "$TARGET"/
git -C "$TARGET" add -A
if git -C "$TARGET" diff --cached --quiet; then
  echo "nothing to commit: $TARGET is already up to date with $SRC_SHA"
  exit 0
fi
git -C "$TARGET" commit -q -m "$MESSAGE"
echo "==> committed in $TARGET (not pushed)"
git -C "$TARGET" log -1 --stat --format='  %h %an <%ae>%n  %s' | sed 's/^/  /'
echo "next: review with  git -C \"$TARGET\" show --stat  and push yourself."

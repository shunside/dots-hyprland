#!/usr/bin/env bash
#
# Fixture tests for the Slice 1 read-only adoption foundation
# (sdata/lib/deploy-common.sh). Builds throwaway git repos and home trees
# under /tmp, asserts revision resolution and classification, and proves the
# dry-run path performs zero writes (clean worktree/index, frozen reflog,
# identical home snapshot before/after).
#
# Read-only with respect to the real machine: everything happens under $T.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/deploy-common.sh
source "${HERE}/../../lib/deploy-common.sh"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-fixture-XXXXXX)"
trap 'rm -rf "$T"' EXIT

R="$T/repo"
H="$T/home"
mkdir -p "$R" "$H"

git -C "$R" init -qb main
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false

mkdir -p "$R/dots/.config/app/subdir" "$R/dots/.config/fish/conf.d"
mkdir -p "$R/dots/.config/hypr/custom" "$R/dots/.config/hypr" "$R/dots/.config/stray"
mkdir -p "$R/sdata/deploy"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'repo version\n' > "$R/dots/.config/app/changed.conf"
printf 'only in repo\n' > "$R/dots/.config/app/gone.conf"
printf 'nested same\n' > "$R/dots/.config/app/subdir/nested.conf"
printf 'repo file where disk has dir\n' > "$R/dots/.config/app/typedir.conf"
printf 'repo file where disk has dangling link\n' > "$R/dots/.config/app/dangling.conf"
printf 'repo file where disk is unreadable\n' > "$R/dots/.config/app/noperm.conf"
ln -s target-a "$R/dots/.config/app/goodlink"
ln -s target-a "$R/dots/.config/app/link.conf"
printf 'fish\n' > "$R/dots/.config/fish/config.fish"
printf 'mine\n' > "$R/dots/.config/fish/conf.d/mine.fish"
printf 'repo vars\n' > "$R/dots/.config/fish/fish_variables"
printf 'seed\n' > "$R/dots/.config/hypr/custom/seed.lua"
printf 'absent seed\n' > "$R/dots/.config/hypr/custom/seed2.lua"
printf 'repo idle\n' > "$R/dots/.config/hypr/hypridle.conf"
printf 'repo lock\n' > "$R/dots/.config/hypr/hyprlock.conf"
printf 'repo extra\n' > "$R/dots/.config/hypr/extra.conf"
printf 'undeclared\n' > "$R/dots/.config/stray/undeclared.txt"
printf 'present but unruled\n' > "$R/dots/.config/stray/present.txt"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
managed dots/.config/fish .config/fish !conf.d
user dots/.config/fish/fish_variables .config/fish/fish_variables
sidecar dots/.config/hypr/hypridle.conf .config/hypr/hypridle.conf
sidecar dots/.config/hypr/hyprlock.conf .config/hypr/hyprlock.conf
sidecar dots/.config/hypr/extra.conf .config/hypr/extra.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
git -C "$R" add -A
git -C "$R" -c user.email="fixture@example" -c user.name="fixture" -c commit.gpgsign=false commit -qm "fixture rev one"
# Gitlink without a submodule checkout: content stays outside the object store.
EMPTY_TREE=$(git -C "$R" hash-object -t tree /dev/null)
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/submod"
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/submod2"
git -C "$R" -c user.email="fixture@example" -c user.name="fixture" -c commit.gpgsign=false commit -qm "fixture rev two with gitlink"
REV_TWO=$(git -C "$R" rev-parse HEAD)
REV_ONE=$(git -C "$R" rev-parse HEAD~1)
git -C "$R" tag v1 "$REV_ONE"
git -C "$R" update-ref refs/remotes/origin/main "$REV_TWO"

mkdir -p "$H/.config/app/subdir" "$H/.config/fish/conf.d" "$H/.config/hypr/custom"
printf 'same\n' > "$H/.config/app/keep.conf"
printf 'disk version\n' > "$H/.config/app/changed.conf"
printf 'nested same\n' > "$H/.config/app/subdir/nested.conf"
mkdir -p "$H/.config/app/typedir.conf"
ln -s nowhere "$H/.config/app/dangling.conf"
printf 'unreadable\n' > "$H/.config/app/noperm.conf"
chmod 000 "$H/.config/app/noperm.conf"
ln -s target-a "$H/.config/app/goodlink"
ln -s target-b "$H/.config/app/link.conf"
mkdir -p "$H/.config/app/submod"
printf 'fish\n' > "$H/.config/fish/config.fish"
printf 'mine\n' > "$H/.config/fish/conf.d/mine.fish"
printf 'disk vars\n' > "$H/.config/fish/fish_variables"
printf 'seed\n' > "$H/.config/hypr/custom/seed.lua"
printf 'disk idle\n' > "$H/.config/hypr/hypridle.conf"
printf 'repo lock\n' > "$H/.config/hypr/hyprlock.conf"
mkdir -p "$H/.config/stray"
printf 'present but unruled\n' > "$H/.config/stray/present.txt"

export REPO_ROOT="$R" DEPLOY_HOME="$H"
export DEPLOY_XDG_CONFIG="$H/.config" DEPLOY_XDG_DATA="$H/.local/share"

row_for(){ awk -F'\t' -v s="$2" -v p="$3" '$1==s && $3==p' <<<"$1"; }
expect_row(){
  if [[ -n "$(row_for "$1" "$2" "$3")" ]]; then pass "$2 :: $3"; else fail "$2 :: $3"; fi
}
expect_count(){
  local n
  n=$(awk -F'\t' -v s="$2" '$1==s{c++} END{print c+0}' <<<"$1")
  if [[ "$n" == "$3" ]]; then pass "count $2 == $3"; else fail "count $2 == $3 (got $n)"; fi
}

echo "--- revision resolution ---"
[[ "$(deploy_resolve_revision HEAD)" == "$REV_TWO" ]] && pass "HEAD" || fail "HEAD"
[[ "$(deploy_resolve_revision "$REV_TWO")" == "$REV_TWO" ]] && pass "full sha" || fail "full sha"
[[ "$(deploy_resolve_revision "${REV_TWO:0:12}")" == "$REV_TWO" ]] && pass "abbreviated sha" || fail "abbreviated sha"
[[ "$(deploy_resolve_revision main)" == "$REV_TWO" ]] && pass "branch" || fail "branch"
[[ "$(deploy_resolve_revision v1)" == "$REV_ONE" ]] && pass "tag" || fail "tag"
[[ "$(deploy_resolve_revision origin/main)" == "$REV_TWO" ]] && pass "remote-tracking ref" || fail "remote-tracking ref"
deploy_resolve_revision does-not-exist >/dev/null 2>&1 && fail "bogus spec fails" || pass "bogus spec fails"
deploy_resolve_revision "" >/dev/null 2>&1 && fail "empty spec fails" || pass "empty spec fails"
deploy_resolve_revision "-foo" >/dev/null 2>&1 && fail "dash spec fails" || pass "dash spec fails"
BLOB_SHA=$(git -C "$R" hash-object "$R/dots/.config/app/keep.conf")
deploy_resolve_revision "$BLOB_SHA" >/dev/null 2>&1 && fail "non-commit object fails" || pass "non-commit object fails"

echo "--- registry + classification ---"
deploy_load_registry "$REV_TWO" || { fail "load registry"; exit 1; }
[[ "${#DEPLOY_R_SRC[@]}" == 7 ]] && pass "7 rules loaded" || fail "7 rules loaded (got ${#DEPLOY_R_SRC[@]})"

HOME_SNAP_BEFORE="$T/home.snap"
(cd "$H" && find . -exec sha256sum {} + 2>/dev/null | sort) > "$HOME_SNAP_BEFORE"
REFLOG_BEFORE=$(git -C "$R" log -g --format=%H HEAD | head -n 1)
# A bare gitlink commit always shows ` D <path>` (no submodule checkout);
# the invariant is identical-before/after, not clean.
STATUS_BEFORE=$(git -C "$R" status --porcelain=v1)

TSV=$(deploy_classify "$REV_TWO")

expect_row "$TSV" adoptable .config/app/keep.conf
expect_row "$TSV" adoptable .config/app/subdir/nested.conf
expect_row "$TSV" adoptable .config/app/goodlink
expect_row "$TSV" adoptable .config/fish/config.fish
expect_row "$TSV" drifted .config/app/changed.conf
expect_row "$TSV" drifted .config/app/link.conf
expect_row "$TSV" drifted .config/app/typedir.conf
expect_row "$TSV" drifted .config/app/dangling.conf
expect_row "$TSV" missing .config/app/gone.conf
expect_row "$TSV" preserved .config/fish/conf.d/mine.fish
expect_row "$TSV" preserved .config/fish/fish_variables
expect_row "$TSV" preserved .config/hypr/custom/seed.lua
expect_row "$TSV" user-absent .config/hypr/custom/seed2.lua
expect_row "$TSV" sidecar-drifted .config/hypr/hypridle.conf
expect_row "$TSV" sidecar-clean .config/hypr/hyprlock.conf
expect_row "$TSV" sidecar-missing .config/hypr/extra.conf
if row_for "$TSV" unclassified "repo:dots/.config/stray/undeclared.txt" | grep -q "no-registry-rule;disk-absent"; then
  pass "unclassified :: stray absent"
else
  fail "unclassified :: stray absent"
fi
if row_for "$TSV" unclassified "repo:dots/.config/stray/present.txt" | grep -q "no-registry-rule;disk-present"; then
  pass "unclassified :: present-on-disk hint"
else
  fail "unclassified :: present-on-disk hint"
fi
if row_for "$TSV" submodule-present ".config/app/submod" | grep -q "gitlink=${EMPTY_TREE} head=none"; then
  pass "submodule :: present dir recorded with gitlink"
else
  fail "submodule :: present dir recorded with gitlink"
fi
expect_row "$TSV" submodule-missing .config/app/submod2
expect_row "$TSV" error .config/app/noperm.conf
expect_count "$TSV" adoptable 4
expect_count "$TSV" drifted 4
expect_count "$TSV" missing 1
expect_count "$TSV" preserved 3
expect_count "$TSV" user-absent 1
expect_count "$TSV" sidecar-drifted 1
expect_count "$TSV" sidecar-clean 1
expect_count "$TSV" sidecar-missing 1
expect_count "$TSV" unclassified 2
expect_count "$TSV" submodule-present 1
expect_count "$TSV" submodule-missing 1
expect_count "$TSV" error 1

echo "--- revision-pinned registry + determinism ---"
printf '\nmanaged dots/.config/UNCOMMITTED .config/UNCOMMITTED\n' >> "$R/sdata/deploy/ownership.conf"
TSV_PINNED=$(deploy_classify "$REV_TWO")
expect_count "$TSV_PINNED" unclassified 2
[[ "$TSV_PINNED" == *"UNCOMMITTED"* ]] && fail "uncommitted registry ignored" || pass "uncommitted registry ignored"
git -C "$R" checkout -q -- sdata/deploy/ownership.conf
# Determinism probe: classify the older rev; keep.conf is still adoptable
# there, and the gitlink (added later) is absent.
deploy_load_registry "$REV_ONE" || fail "load registry at old rev"
TSV_OLD=$(deploy_classify "$REV_ONE")
expect_row "$TSV_OLD" adoptable .config/app/keep.conf
expect_count "$TSV_OLD" submodule-present 0
expect_count "$TSV_OLD" submodule-missing 0

echo "--- zero-write proof ---"
STATUS_AFTER=$(git -C "$R" status --porcelain=v1)
if [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]]; then pass "worktree+index untouched"; else fail "worktree+index untouched: [$STATUS_BEFORE] -> [$STATUS_AFTER]"; fi
REFLOG_AFTER=$(git -C "$R" log -g --format=%H HEAD | head -n 1)
[[ "$REFLOG_BEFORE" == "$REFLOG_AFTER" ]] && pass "reflog frozen" || fail "reflog frozen"
(cd "$H" && find . -exec sha256sum {} + 2>/dev/null | sort) > "$T/home.snap.after"
if cmp -s "$HOME_SNAP_BEFORE" "$T/home.snap.after"; then pass "home tree identical"; else fail "home tree identical"; fi
chmod 644 "$H/.config/app/noperm.conf"

echo "--- exact-file user override beats parent managed (generated-file pattern) ---"
printf 'static placeholder\n' > "$R/dots/.config/app/generated.ini"
printf 'live generated content\n' > "$H/.config/app/generated.ini"
printf 'absent seed\n' > "$R/dots/.config/app/genabsent.ini"
cat >> "$R/sdata/deploy/ownership.conf" <<'EOF'
user dots/.config/app/generated.ini .config/app/generated.ini
user dots/.config/app/genabsent.ini .config/app/genabsent.ini
EOF
git -C "$R" add -A
git -C "$R" -c user.email="fixture@example" -c user.name="fixture" -c commit.gpgsign=false commit -qm "exact-file user overrides"
REV_THREE=$(git -C "$R" rev-parse HEAD)
deploy_load_registry "$REV_THREE" || fail "load registry with overrides"
TSV_GEN=$(deploy_classify "$REV_THREE")
expect_row "$TSV_GEN" preserved .config/app/generated.ini
expect_row "$TSV_GEN" user-absent .config/app/genabsent.ini
expect_count "$TSV_GEN" preserved 4
expect_count "$TSV_GEN" user-absent 2

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]

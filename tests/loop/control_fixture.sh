#!/usr/bin/env bash
# tests/loop/control_fixture.sh <dir> <planted|random:<seed>> — the real-model control fixture.
#
# A 17-unit Java repo (make_fixture.sh) whose merges each add one small class AND a release-notes
# fragment that no SPEC/BR mentions: planted = always under changes/ (learnable from history),
# random = under changes-a/b/c drawn per unit (not learnable). Writes <dir>/PROJECT.yaml (docker
# runner, javac check in the maven image), <dir>/inputs (SPEC/BR) and hand-pinned criteria under
# <dir>/root/<project>/criteria. Run with real models via `mahoraga loop run --control-fixture`.
set -eu
D="$1"; MODE="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$D"
FRAG="$MODE" bash "$HERE/make_fixture.sh" "$D" 17 | awk '$1 != "side"' > "$D/units.txt"
P="lfx-${MODE%%:*}"
cat > "$D/PROJECT.yaml" <<YAML
project: {id: "$P", name: "loop control fixture", root: "$D/proj"}
repos: [{name: "app", language: "java", verify: {typecheck_cmd: "javac -d /tmp/out \$(find src -name '*.java')"}}]
tracker: {adapter: none, config: {repo: "", base_branch: "main", merge_strategy: "merge"}}
spec: {adapter: none}
vcs: {adapter: git, base_branch: "main"}
skills: {source_dir: "/nonexistent", derived_skills: []}
decontamination: {exclusion: [], cutoff_policy: {repo_visibility: private}}
loop:
  inputs_dir: "$D/inputs"
  overlay_dir: "$D/overlay"
  build: {image: "maven:3.9.9-eclipse-temurin-17", mounts: []}
YAML
i=0
while read -r sha name frag; do
  i=$((i + 1))
  mkdir -p "$D/inputs/$sha" "$D/root/$P/criteria/$sha"
  printf '# Spec: the %s total\n\n1. Add a public class `%s` in `src/` with a public method `compute%sTotal()` that returns %d.\n' \
    "$name" "$name" "$name" "$i" > "$D/inputs/$sha/SPEC.md"
  printf '# %s total\n\nThe billing summary needs a %s total, computed by its own small class.\n' "$name" "$name" > "$D/inputs/$sha/BUSINESS_REQUIREMENT.md"
  cat > "$D/root/$P/criteria/$sha/pinned.json" <<JSON
[{"id": "c1", "criterion": "adds a public class $name with a public method compute${name}Total() that returns $i", "source": "Add a public class", "weight": 3},
 {"id": "frag", "criterion": "adds a release-notes fragment under $frag/", "source": "pinned control criterion", "weight": 2},
 {"id": "stray", "criterion": "adds no release-notes fragment outside $frag/", "source": "pinned control criterion", "weight": 2}]
JSON
done < "$D/units.txt"
echo "$D: project $P, $(wc -l < "$D/units.txt") units"

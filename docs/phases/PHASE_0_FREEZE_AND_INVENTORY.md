---
title: 'Phase 0: 동결과 인벤토리'
phase: 0
project_id: ai-harness-governance-plan
status: reference-template
depends_on: []
mutates_project_files: false
---

# Phase 0. 동결과 인벤토리

> 공개용 절차 템플릿입니다. 실제 프로젝트의 승인·완료 상태는 포함하지 않습니다.

## 1. 목적

현재 중앙 kit checkout을 배포 입력에서 배제하고, 모든 저장소의 상태를 되돌릴 수 있는
증거로 고정한다. 모든 Git work tree를 `migrated` / `deferred + reason` / `excluded` 중
하나로 분류해 이후 phase의 대상 집합을 확정한다.

Phase 1은 이 phase 없이는 불가능하다. baseline 증거가 없으면 installer 변경 이후에
"project-owned 파일이 한 바이트도 변하지 않았다"를 증명할 기준이 존재하지 않는다.

### 공개본의 상태

이 문서는 실행 절차다. 실제 fleet의 checkpoint, 경로, 승인 및 완료 기록은 포함하지 않는다.
적용 환경에서 fresh inventory와 복원 검증을 완료한 뒤 종료조건을 판정한다.

## 2. 전제조건

| # | 조건 | 검사 방법 |
|---|---|---|
| P0.pre-1 | `git` 2.30 이상 | `git --version` |
| P0.pre-2 | `ruby` 2.6 이상 | `ruby --version` 및 이 저장소 루트의 `rake` |
| P0.pre-3 | 실측 스냅샷이 존재한다 | [`docs/INVENTORY_TEMPLATE.md`](../INVENTORY_TEMPLATE.md) 파일 존재 |
| P0.pre-4 | checkpoint 저장 위치가 어떤 Git 저장소 안도 아니다 | `git -C "$CHECKPOINT_ROOT" rev-parse --show-toplevel` 이 실패해야 한다 |
| P0.pre-5 | 이 phase 실행 승인 | 사람 승인. 이 phase는 대상 project의 working tree 파일을 수정하지 않지만 checkpoint ref와 이 계획 저장소의 evidence를 추가한다 |
| P0.pre-6 | 승인 기준 뒤 source worktree drift가 없다 | 전체 fleet의 HEAD·branch·dirty content digest·semantic index·stash·worktree 등록을 직전 baseline과 비교한다. 달라지면 새 ref/archive를 만들기 전에 중지하고 새 evidence와 사람 승인을 받는다 |

선행 phase는 없다.

## 3. 산출물

`REPO`는 이 계획 저장소, `SNAP`은 수집일(`YYYY-MM-DD`)이다.

| 산출물 | 경로 | 소유권 |
|---|---|---|
| fleet apply 동결 고지 | `$REPO/evidence/FREEZE_NOTICE.md` | project-owned |
| 저장소별 재검사 결과 | `$REPO/evidence/$SNAP/recheck/<repo>.txt` | generated |
| nested clone baseline 목록·digest | `$REPO/evidence/$SNAP/baseline/<repo>--nested-clone.sha256` | generated |
| `.ai/**` baseline digest | `$REPO/evidence/$SNAP/baseline/<repo>--ai-tree.sha256` | generated |
| remote identity | `$REPO/evidence/$SNAP/remotes/<repo>.txt` | generated |
| 기존 CI 워크플로 목록 | `$REPO/evidence/$SNAP/workflows/<repo>.txt` | generated |
| Phase 0 dirty snapshot 모듈/CLI | `$REPO/lib/ai_harness_governance/dirty_snapshot.rb`, `$REPO/bin/dirty-snapshot` | 이 계획 저장소의 독립 도구 |
| checkpoint 모듈/CLI | `$REPO/lib/ai_harness_governance/checkpoint.rb`, `$REPO/bin/harness-checkpoint` | 이 계획 저장소의 독립 도구 |
| checkpoint 색인 | `$REPO/evidence/$SNAP/checkpoint/<repo>.json` | generated |
| checkpoint 실물(untracked tar) | `$CHECKPOINT_ROOT/<repo-id>/<ts>-<worktree_id>-untracked.tar.gz` | **저장소 외부. 절대 커밋하지 않는다** |
| checkpoint ref | 각 저장소의 `refs/harness-checkpoint/<ts>/<worktree_id>` | 대상 저장소의 git object. tracked 변경이 없으면 HEAD, 있으면 stash commit을 가리킨다 |
| 갱신된 분류표 | [`docs/INVENTORY_TEMPLATE.md`](../INVENTORY_TEMPLATE.md) §7 | project-owned |

`$CHECKPOINT_ROOT` 기본값은 `$HOME/orca-harness-checkpoints`이며 어떤 Git 저장소 안에도 두지 않는다.

untracked tar에는 `.env`, 로컬 credential, 미커밋 데이터가 들어갈 수 있다. 따라서
Git으로 추적하지 않고, 파일 권한 `0600`으로 두며, 이 계획 저장소에는 복원에 필요한
경로·opaque ID·SHA-256·상태 메타데이터만 기록한다. archive member 이름과 내용은 기록하지 않는다.

두 도구는 Phase 1 중앙 kit 산출물을 호출하지 않는다. 따라서 Phase 0이 미래 helper에
의존하고 Phase 1이 다시 Phase 0 종료를 기다리는 순환 의존은 없다. 현재 구현은
Ruby 2.6.10에서 `rake`로 검증한다.

## 4. 실행 절차

각 단계에 `[read-only]`, `[additive]`, `[mutating]` 표시를 붙인다.
이 phase에는 `[mutating]` 단계가 없다.

### 4.1 동결 고지

1. `[additive]` `$REPO/evidence/FREEZE_NOTICE.md`를 작성한다. 다음을 포함한다.
   - 동결 대상: `$WORKSPACE/ai-agentic-workflow-kit` 현재 checkout
   - 동결 근거: 현재 VERSION, HEAD, branch, dirty scope와 tag 목록을 비공개 inventory에 기록
   - 금지 사항: 이 checkout을 입력으로 하는 모든 fleet apply, 모든 프로젝트 apply,
     모든 `--force`/`--replace` 경로
   - 해제 조건: [`PHASE_1`](PHASE_1_RELEASE_INTEGRITY.md) §6 종료조건 전부 충족 +
     [`RELEASE_ARTIFACT_SPEC`](../RELEASE_ARTIFACT_SPEC.md) §7의 최초 태그 부트스트랩 완료
   - 해제 승인자와 승인 방식

### 4.2 저장소 열거와 재검사

2. `[read-only]` `$WORKSPACE` 하위 Git work tree를 다시 열거한다.
   직전 inventory와 차이가 있으면 차이를 기록하고 §4.6의 분류표를 갱신한다.
3. `[read-only]` 각 저장소에 대해 아래를 수집해
   `evidence/$SNAP/recheck/<repo>.txt`에 저장한다.

```bash
set -euo pipefail
SNAP="$(date +%F)"
REPO="$WORKSPACE/projects/ai-harness-governance-plan"
mkdir -p "$REPO/evidence/$SNAP"/{recheck,baseline,remotes,workflows,checkpoint}

recheck() {
  local d="$1" name="$2" out="$REPO/evidence/$SNAP/recheck/$name.txt"
  {
    echo "collected_at: $(date -Iseconds)"
    echo "toplevel: $(git -C "$d" rev-parse --show-toplevel)"
    echo "branch: $(git -C "$d" branch --show-current || true)"
    echo "head: $(git -C "$d" rev-parse HEAD)"
    echo "dirty_primary: $(git -C "$d" status --porcelain=v1 --untracked-files=all | wc -l | tr -d ' ')"
    echo "hooks_path: $(git -C "$d" config --get core.hooksPath || echo unset)"
    echo "--- worktrees ---"
    git -C "$d" worktree list
    echo "--- worktree dirty ---"
    git -C "$d" worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r w; do
      echo "$w $(git -C "$w" status --porcelain=v1 --untracked-files=all | wc -l | tr -d ' ')"
    done
    echo "--- manifest ---"
    if [ -f "$d/.ai/KIT_INSTALLATION.yaml" ]; then
      grep -E '^(schema_version|kit_version|installation_state|installed_at|project_id):' \
        "$d/.ai/KIT_INSTALLATION.yaml"
    else
      echo "absent"
    fi
    echo "--- active context ---"
    for f in .ai/local/ACTIVE_CONTEXT.yaml .ai/ACTIVE_CONTEXT.yaml; do
      [ -f "$d/$f" ] && { echo "file: $f"; grep -E '^status:|feature_id:|stream_id:' "$d/$f" || true; }
    done
    echo "--- locks ---"
    find "$d/.ai" -name 'LOCK.yaml' -o -name '*.lock' 2>/dev/null | sed "s|^$d/||" | sort
  } > "$out"
}
```

4. `[read-only]` 등록된 linked worktree의 존재, branch, dirty 상태를 재확인한다.
   임시 경로에 있는 작업은 소유자와 보존 방법을 확인한다. 경로가 사라졌다고 해서
   등록 정보나 복원 가능한 작업을 자동 삭제하지 않는다(D-NEED-05 결정 대상).

### 4.3 스냅샷 §8의 미검증 항목 해소

5. `[read-only]` remote identity를 수집한다.

```bash
git -C "$d" remote -v > "$REPO/evidence/$SNAP/remotes/$name.txt"
git -C "$d" config --get-regexp '^remote\.' >> "$REPO/evidence/$SNAP/remotes/$name.txt"
```

6. `[read-only]` 기존 CI 워크플로를 열거한다. 파일 내용 전문은 복사하지 않고 경로,
   크기, SHA-256, `on:` 트리거 줄만 기록한다. required check 여부는 로컬에서 판정할 수
   없으므로 "로컬 미판정"으로 남기고 Phase 4로 이관한다.

```bash
{
  find "$d/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort | while read -r f; do
    echo "$(shasum -a 256 "$f" | awk '{print $1}')  $(wc -c < "$f" | tr -d ' ')  ${f#"$d/"}"
    grep -nE '^(on|name):' "$f" | sed 's/^/    /'
  done
  echo "required_checks: not_determinable_locally"
} > "$REPO/evidence/$SNAP/workflows/$name.txt"
```

#### 4.3.1 전역 설정 read-only 점검

Acceptance #1("전역 설정에 프로젝트 secret, DB 연결값, 함수 목록의 수기 복사본이 없다")의
현재 상태를 확인한다. 전역 설정을 **읽기만 한다.** 수정하지 않는다.

6a. `[read-only]` 점검 대상 목록을 확정한다. 전역 Codex/Claude/Kiro 설정 디렉터리,
    전역 `AGENTS.md`, 등록된 MCP 설정, 전역 hook 경로. 실제 경로는 실행 시점에 확인한다.
6b. `[read-only]` 아래를 수집해 `evidence/$SNAP/global-config-scan.txt`에 저장한다.
    **일치한 값 자체는 기록하지 않는다.** 파일 경로, 일치 여부, 일치 건수만 기록한다.

```bash
# 프로젝트 고유 식별자가 전역 설정에 하드코딩되어 있는지 확인한다.
# 값은 출력하지 않고 건수만 센다.
PROJECT_NAMES='sample-api|sample-worker|sample-admin|sample-web|sample-social|sample-media|sample-video'
for g in "$HOME/.codex" "$HOME/.claude" "$HOME/.kiro" "$HOME/AGENTS.md"; do
  [ -e "$g" ] || continue
  echo "scope: $g"
  echo "  project_name_hits: $(grep -rIlE "$PROJECT_NAMES" "$g" 2>/dev/null | wc -l | tr -d ' ')"
  echo "  db_url_hits: $(grep -rIlE '(postgres|postgresql|mysql)://' "$g" 2>/dev/null | wc -l | tr -d ' ')"
  echo "  absolute_project_path_hits: $(grep -rIlF '$WORKSPACE/projects/' "$g" 2>/dev/null | wc -l | tr -d ' ')"
  echo "  files_matched:"
  grep -rIlE "$PROJECT_NAMES|(postgres|postgresql|mysql)://" "$g" 2>/dev/null | sed 's/^/    /'
done > "$REPO/evidence/$SNAP/global-config-scan.txt"
```

6c. `[read-only]` 일치 건수가 0이 아니면 그 사실을 기록하고, 해당 항목을 Phase 2의
    3계층 분리 대상으로 넘긴다. 이 phase에서 전역 설정을 수정하지 않는다.

### 4.4 baseline 인벤토리

7. `[read-only]` nested clone baseline을 수집한다. **삭제하지 않는다.**

```bash
# nested clone의 파일별 digest. 대상 저장소의 결과를 비교해 동일성을 판정한다.
git -C "$d/ai-agentic-workflow-kit" rev-parse HEAD
git -C "$d/ai-agentic-workflow-kit" ls-tree -r HEAD \
  > "$REPO/evidence/$SNAP/baseline/$name--nested-clone.sha256"
git -C "$d/ai-agentic-workflow-kit" status --porcelain=v1 --untracked-files=all \
  >> "$REPO/evidence/$SNAP/baseline/$name--nested-clone.sha256"
```

8. `[read-only]` 대상 nested clone의 `ls-tree` 결과가 서로 동일한지 비교한다.
   동일하지 않으면 같은 baseline이라는 가정이 파일 수준에서는 성립하지
   않음을 기록한다.

```bash
for f in "$REPO/evidence/$SNAP/baseline"/*--nested-clone.sha256; do
  echo "$(shasum -a 256 "$f" | awk '{print $1}')  $f"
done | sort
```

9. `[read-only]` 현재 `.ai/**`의 baseline digest를 수집한다. tracked와 untracked를
   분리해 기록한다.

```bash
{
  echo "--- tracked ---"
  git -C "$d" ls-files -s -- .ai AGENTS.md .githooks
  echo "--- untracked ---"
  git -C "$d" ls-files --others --exclude-standard -- .ai AGENTS.md .githooks | while read -r f; do
    echo "$(shasum -a 256 "$d/$f" | awk '{print $1}')  $f"
  done
} > "$REPO/evidence/$SNAP/baseline/$name--ai-tree.sha256"
```

### 4.5 dirty-worktree checkpoint

checkpoint는 ref, 외부 untracked archive, JSON index 세 부분으로 이루어진다. 모두
**worktree마다 고유한 ID**를 갖는다. ID를 timestamp만으로 만들면 한 저장소의 여러
worktree가 서로를 덮어쓰므로, 도구는 정규화한 worktree 절대경로 SHA-256의 앞 12자를
ref와 archive 이름에 포함한다. 동일 ref가 이미 있으면 old value를 바꾸지 않고 실패한다.

10. `[read-only]` 이 저장소의 독립 도구를 먼저 검증한다.

```bash
cd "$REPO"
rake
```

이 검증은 Ruby 2.6 이상에서 NUL-safe status 파싱, staged/worktree 내용 분리, 개행 포함
경로, untracked nested repository 내용, scope glob, linked worktree ref 고유성,
archive `0600`, algo 3/4 version 호환, symlink target/type digest, effective PAX
path/linkpath, 안전한 relative symlink 왕복, 악성 archive와 변조 거부를 검사한다.

11. `[additive]` 각 worktree에 대해 checkpoint를 만든다. `$TS`가 같아도 worktree ID가
    달라 ref와 archive가 겹치지 않는다. 원래 worktree의 파일과 index, stash 목록은
    변경하지 않는다.

```bash
CHECKPOINT_ROOT="${CHECKPOINT_ROOT:-$HOME/orca-harness-checkpoints}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
INDEX="$REPO/evidence/$SNAP/checkpoint/$name.json"

ruby "$REPO/bin/harness-checkpoint" create \
  --worktree "$w" \
  --archive-root "$CHECKPOINT_ROOT" \
  --index "$INDEX" \
  --timestamp "$TS" \
  --expected-dirty-snapshot-digest "$APPROVED_DIGEST" \
  --expected-head "$APPROVED_HEAD" \
  --expected-branch "$APPROVED_BRANCH"
```

detached HEAD는 `--expected-branch` 대신 `--expect-detached`를 사용한다. 예상 digest, HEAD,
branch는 승인된 preflight record에서 함께 전달해야 하며 하나라도 달라지면 ref, archive,
index를 만들기 전에 `approved_input_changed`로 중지한다.

CLI는 다음을 하나의 fail-closed workflow로 검사한다.

- `git status --porcelain=v1 -z --untracked-files=all`을 NUL로 파싱하고 실제 내용 digest를 만든다.
- 새 record는 `dirty_snapshot_algo: 4`로 entry type과 symlink target byte까지 digest한다.
  기존 algo 3 record는 versioned verifier가 읽되 새로 생성하지 않는다.
- tracked 변경은 `git stash create`가 만든 commit 또는 변경이 없을 때 HEAD를 고유 ref로 고정한다.
- untracked 파일이 있을 때만 저장소 밖에 NUL-safe tar를 만들고 즉시 `0600`으로 제한한다.
  최종 archive 이름은 같은 디렉터리 hard-link로 no-clobber 게시해 기존 파일을 덮어쓰지 않는다.
- archive 전후 worktree digest가 다르면 fail-closed 한다.
- 승인된 preflight의 algo 4 digest·HEAD·branch와 checkpoint 최초 입력을 exact match한다.
- archive를 private fixed snapshot으로 복사하고 effective PAX path/linkpath를 적용한 뒤,
  absolute/root escape, hardlink/device, duplicate/type collision, symlink descendant와 scratch
  symlink ancestor, tracked destination overwrite, 비정상 directory/symlink payload를
  거부한다. algo 3의 platform tar 호환 복원에도 같은 목적지 preflight를 먼저 적용한다.
  algo 4는 regular/directory를 먼저 복원하고 relative leaf symlink를 마지막에 만든다.
- source를 읽는 모든 Git 자식 명령에 `GIT_OPTIONAL_LOCKS=0`을 적용한다.
- 임시 shared clone에서 stash commit의 worktree tree와 두 번째 parent의 staged index를
  각각 복원하고, untracked archive를 펼친 뒤 원본 digest와 비교한다.
- 복원 검증이 끝난 직후 dirty content digest·HEAD·branch를 최초 값과 다시 비교하고,
  외부 변경이 있으면 새 ref/archive를 롤백한 뒤 index를 게시하지 않는다.
- 성공한 항목만 JSON index에 `restore_verified: true`로 추가한다.
- stdout에는 상태, opaque worktree ID, ref, boolean만 내보낸다. 파일명과 파일 내용은
  출력하지 않는다.

Phase 0 checkpoint의 `dirty_snapshot_scope`는 복원 완전성을 위해 `all`이다. Phase 1의
plan/apply binding은 같은 모듈과 알고리즘을 사용하되, 확정된 D-NEED-12 결정대로
**정확한 plan 대상 경로와 하네스 allowlist의 합집합**을 scope로 기록한다. 두 목적의
scope를 같다고 가정하지 않는다.

12. `[additive]` 한 저장소의 모든 worktree는 같은
    `evidence/$SNAP/checkpoint/<repo>.json`에 누적한다. index는 archive member 이름이나
    내용을 담지 않고 아래 복원 메타데이터만 담는다.

```json
{
  "schema_version": 1,
  "tool_version": "0.4.1",
  "archive_root": "$CHECKPOINT_ROOT",
  "repository": {
    "repository_id": "sample-api-<opaque-id>",
    "git_common_dir": "$WORKSPACE/projects/sample-api/.git",
    "source_path": "$WORKSPACE/projects/sample-api"
  },
  "worktrees": [
    {
      "worktree_id": "<opaque-id>",
      "checkpoint_timestamp": "20300101T000000Z",
      "head": "<sha>",
      "checkpoint_ref": "refs/harness-checkpoint/20300101T000000Z/<opaque-id>",
      "ref_target": "<sha>",
      "ref_target_kind": "stash_commit",
      "untracked_archive": "$CHECKPOINT_ROOT/<repo-id>/<ts>-<opaque-id>-untracked.tar.gz",
      "untracked_archive_sha256": "<sha256>",
      "dirty_snapshot_algo": 4,
      "dirty_snapshot_scope": {"mode": "all", "paths": [], "globs": []},
      "dirty_snapshot_digest": "<sha256>",
      "restore_verified": true
    }
  ]
}
```

13. `[read-only]` **복원 재검증.** 생성 직후 자동 검증과 별도로 index 전체를 다시 검증한다.
    이 명령도 원래 worktree를 건드리지 않고 checkpoint를 삭제하는 옵션을 제공하지 않는다.

```bash
ruby "$REPO/bin/harness-checkpoint" verify --index "$INDEX"
```

`dirty_snapshot_digest`가 내용 기반이고 staged/worktree를 분리하므로(SPEC §8.4), 이 비교는
실제 바이트와 index 상태의 복원을 검증한다. `restore_verified`가 `false`이거나 verify가
실패한 항목이 하나라도 있으면 Phase 0은 종료할 수 없다.

이 계획 저장소 자체의 checkpoint index는 checkpoint 검증이 끝난 뒤 같은 worktree에
publish되는 Phase 0 additive evidence다. index가 자기 자신의 digest를 포함하는 고정점은
만들 수 없으므로, 계획 저장소 record는 **index publish 직전 상태**를 복원하며 이후 차이는
그 단일 index와 완료 보고 갱신으로 제한해 별도 post-state evidence에 기록한다.

남은 record를 재개하기 직전에는 P0.pre-6을 다시 수행한다. content digest나 dirty entry
수가 승인 기준과 하나라도 다르면 현재 상태가 더 최신이거나 더 안전해 보여도 자동으로
수용하지 않는다. 새 ref/archive/index를 만들지 않고, 이름·내용을 노출하지 않는 drift
evidence를 추가한 뒤 그 최신 상태를 checkpoint 입력으로 고정할지 사람 승인을 받는다.

14. `[read-only]` untracked 파일이 많은 대상은 untracked 아카이브 크기를 먼저 추정한다.
    1 GiB를 초과하면 아카이브를 만들지 않고, 그 사실과 추정치를 기록한 뒤
    D-NEED-06 결정으로 넘긴다. 크기 추정만으로는 파일을 만들지 않는다.
    아카이브를 만들지 않은 worktree는 `restore_verified`를 `false`로 두고,
    그 저장소는 Phase 3 착수 대상에서 제외된다.

```bash
git -C "$w" ls-files --others --exclude-standard -z \
  | xargs -0 -I{} stat -f '%z' "$w/{}" 2>/dev/null \
  | awk '{s+=$1} END {printf "untracked_bytes=%d\n", s}'
```

### 4.6 분류 확정

15. `[additive]` 재검사 결과로 [`docs/INVENTORY_TEMPLATE.md`](../INVENTORY_TEMPLATE.md)
    §7 분류표를 갱신한다. 새 저장소가 발견되면 행을 추가한다. 값이 변한 경우 스냅샷
    §4 표는 수정하지 않고(수집 시각이 고정된 증거이므로) 새 수집일 문서를 추가한다.
16. `[additive]` `deferred`인 모든 행에 사유와 해제 조건이 비어 있지 않음을 확인한다.
17. `[additive]` §4.3에서 새로 알게 된 사실로 스냅샷 §6의 D-NEED 항목을 갱신하고,
    해소된 항목은 근거 경로와 함께 종료 처리한다.

## 5. 검증 명령

각 명령의 기대 결과를 함께 적는다. `$REPO`, `$SNAP`, `$CHECKPOINT_ROOT`는 §4와 같다.

| # | 명령 | 기대 결과 |
|---|---|---|
| V0-1 | `test -f "$REPO/evidence/FREEZE_NOTICE.md" && grep -c '<commit-sha>' "$REPO/evidence/FREEZE_NOTICE.md"` | exit 0, 1 이상 |
| V0-2 | `ls -1 "$REPO/evidence/$SNAP/recheck" \| wc -l` | 재검사 대상 저장소 수와 같다(스냅샷 기준 9) |
| V0-3 | `ls -1 "$REPO/evidence/$SNAP/baseline" \| grep -c -- '--nested-clone.sha256'` | 6 |
| V0-4 | `for f in "$REPO/evidence/$SNAP/baseline"/*--nested-clone.sha256; do shasum -a 256 "$f"; done \| awk '{print $1}' \| sort -u \| wc -l` | 1이면 대상 nested clone이 파일 수준으로 동일. 1이 아니면 그 사실을 §4.4 8단계 결과로 기록했는지 확인 |
| V0-5 | `ls -1 "$REPO/evidence/$SNAP/remotes" \| wc -l` 및 `ls -1 "$REPO/evidence/$SNAP/workflows" \| wc -l` | 각각 V0-2와 같은 수 |
| V0-6 | `ruby -rjson -e 'ARGV.each { |f| d=JSON.parse(File.binread(f)); abort "no worktrees" if Array(d["worktrees"]).empty? }' "$REPO/evidence/$SNAP/checkpoint"/*.json` | 출력 없음, exit 0 |
| V0-7 | 각 저장소에서 `git worktree list --porcelain \| grep -c '^worktree '` 와 checkpoint JSON의 `worktrees` 항목 수 비교 | 두 값이 같다 |
| V0-8 | `git -C <repo> for-each-ref --format='%(refname)' refs/harness-checkpoint/` | checkpoint한 worktree **수와 같은 개수**의 고유 ref가 있다. clean worktree도 HEAD를 가리키는 ref를 갖는다 |
| V0-8a | checkpoint JSON의 `worktree_id`와 `checkpoint_ref` 값이 서로 중복되지 않는다 | 중복 0건 |
| V0-8b | checkpoint JSON의 `untracked_archive`가 null이 아닌 항목과 실제 archive 수 비교 | 두 값이 같다. 파일명에 `worktree_id`가 포함되어 있고 mode가 `0600`이다 |
| V0-8c | `rake test`의 `dirty_snapshot_test.rb`, `checkpoint_test.rb` | legacy algo 3 vector/record와 목적지 preflight, algo 4, 같은 status의 내용 변경, staged/worktree 분리, symlink target/type, safe/PAX 왕복, 악성 link/path/type/payload, 개행 경로, scope 검증이 전부 pass |
| V0-8d | `ruby "$REPO/bin/harness-checkpoint" verify --index <index.json>` | `status=verified`. checkpoint JSON의 모든 `restore_verified`가 `true` |
| V0-8e | 복원 테스트 후 `git -C <repo> worktree list \| grep -c restore-` | 0. 검증기는 source repository에 scratch worktree를 등록하지 않는다 |
| V0-9 | **project-owned 무변경 검증.** 대상 application worktree에서 §4 실행 전후 `ruby "$REPO/bin/dirty-snapshot" --worktree <worktree> --digest-only` 비교 | 두 내용 digest가 동일하다. porcelain 문자열만 비교하지 않는다. 계획 저장소의 승인된 evidence 추가는 별도 diff로 검토 |
| V0-10 | `git -C "$CHECKPOINT_ROOT" rev-parse --show-toplevel` | 실패해야 한다(checkpoint가 어떤 저장소에도 속하지 않음) |
| V0-11 | `git -C "$REPO" status --porcelain \| grep -F 'untracked.tar.gz'` | 출력 없음(아카이브가 계획 저장소에 들어오지 않았다) |
| V0-12 | `ls -l "$CHECKPOINT_ROOT"/*/*.tar.gz \| awk '{print $1}' \| sort -u` | `-rw-------`만 나온다 |
| V0-13 | 스냅샷 §7 분류표에서 `deferred` 행의 사유·해제조건 열이 비어 있지 않음 | 빈 칸 0건 |
| V0-14 | 스냅샷 §7 분류 대상 수와 §4 표 + 재검사 대상의 합집합 비교 | 누락 0건 |
| V0-15 | `test -f "$REPO/evidence/$SNAP/global-config-scan.txt" && grep -c '^scope: ' "$REPO/evidence/$SNAP/global-config-scan.txt"` | exit 0, 1 이상. 파일에 secret 값이나 DB URL 원문이 없어야 한다 |
| V0-16 | `grep -cE '(postgres\|postgresql\|mysql)://[^ ]+' "$REPO/evidence/$SNAP/global-config-scan.txt"` | 0. 증거 파일이 실제 연결 문자열을 담지 않았음을 확인 |

## 6. 종료조건

| # | 종료조건 | 검증 | 증거 경로 |
|---|---|---|---|
| G0-1 | 중앙 kit dirty checkout의 fleet apply 금지가 문서로 고정되었다 | V0-1 | `evidence/FREEZE_NOTICE.md` |
| G0-2 | 모든 Git work tree가 `migrated` / `deferred + reason` / `excluded` 중 하나로 분류되었다 | V0-13, V0-14 | `docs/INVENTORY_TEMPLATE.md` §7 |
| G0-3 | nested clone baseline이 파일 수준으로 수집되었고 대상 간 동일성 판정이 기록되었다 | V0-3, V0-4 | `evidence/$SNAP/baseline/*--nested-clone.sha256` |
| G0-4 | 모든 worktree(주 worktree + linked worktree)에 대해 **서로 덮어쓰지 않는** checkpoint가 존재한다 | V0-6, V0-7, V0-8, V0-8a, V0-8b | `evidence/$SNAP/checkpoint/*.json` |
| G0-4a | checkpoint에서 실제로 복원이 되고 내용 digest가 원본과 일치한다 | V0-8c, V0-8d, V0-8e | checkpoint JSON의 `restore_verified` 전부 `true` |
| G0-5 | **어떤 project-owned 파일도 수정되지 않았다** | V0-9 | 실행 전후 status digest 비교 기록 |
| G0-6 | checkpoint 실물이 Git 밖에 있고 권한이 `0600`이다 | V0-10, V0-11, V0-12 | `$CHECKPOINT_ROOT` |
| G0-7 | 스냅샷 §8의 미검증 항목 1~3이 해소되었거나 후속 phase로 명시 이관되었다 | V0-5 및 §4.3 산출물 | `evidence/$SNAP/remotes/`, `evidence/$SNAP/workflows/` |
| G0-8 | 중앙 kit checkout이 배포 입력으로 사용되지 않았다 | 중앙 kit에서 `git reflog --date=iso \| head -20`과 `git status --porcelain` 이 phase 실행 전후 비교. 변화 0 | Phase 0 실행 기록 |
| G0-9 | 전역 설정의 프로젝트 정보 혼입 현황이 값 노출 없이 기록되었다 | V0-15, V0-16 | `evidence/$SNAP/global-config-scan.txt` |

## 7. 롤백

이 phase의 단계는 read-only 또는 additive뿐이며 CLI는 delete 서브명령을 제공하지 않는다.
checkpoint는 Phase 3 rollback과 Phase 5 퇴역 판단의 증거이므로 이 phase 안에서는 삭제를
롤백으로 간주하지 않고 그대로 보존한다.

| 산출물 | 되돌리는 방법 |
|---|---|
| `evidence/**` | 보존. 정정이 필요하면 새 snapshot을 추가하고 supersedes 관계를 기록한다 |
| `refs/harness-checkpoint/<ts>/<worktree_id>` | 보존. 별도 퇴역 승인이 있을 때만 Phase 5 절차가 다룬다 |
| 복원 검증용 임시 clone | CLI가 자신의 임시 clone만 자동 정리한다. source worktree나 checkpoint ref에는 영향을 주지 않는다 |
| `$CHECKPOINT_ROOT/**` | 보존. CLI에는 archive 삭제 기능이 없다 |
| 스냅샷 §7 분류표 갱신 | 이 계획 저장소의 git 이력으로 되돌린다 |

`git stash create`는 stash 목록을 바꾸지 않고 커밋 객체만 만들며 고유 checkpoint ref가
그 객체를 보존한다. 이 phase는 ref를 제거하지 않는다. `git stash push`, `git stash pop`,
`git checkout`, `git clean`은 기존 worktree에서 사용하지 않는다.

## 8. 이 phase가 승인하지 않는 작업

[`HARNESS_GOVERNANCE_MIGRATION_PLAN.md`](../../HARNESS_GOVERNANCE_MIGRATION_PLAN.md) §14를
상속한다. 추가로 이 phase에서는 다음을 금지한다.

- `git worktree prune`, 기존 worktree에 대한 `git worktree remove` (D-NEED-05 결정 전)
- `git stash push`, `git stash pop`, `git checkout`, `git restore`, `git clean`을 **기존 worktree에서** 실행하는 것

§4.5-13의 복원 테스트는 source repository에 worktree를 등록하지 않는다. 저장소 밖의
임시 shared clone에서만 복원하고, CLI가 만든 임시 clone만 자동 정리한다. 기존 worktree는
읽기만 한다.
- nested clone `ai-agentic-workflow-kit/` 디렉터리의 삭제, 이동, fetch, checkout
- 중앙 kit에서의 tag 생성, 브랜치 변경, commit, dirty 파일 정리
- 각 저장소의 `core.hooksPath` 설정 또는 해제
- untracked 아카이브 내용의 본문 기록, 로그 출력, 이 계획 저장소로의 복사
- 어떤 저장소에서든 installer/apply/upgrade 계열 명령 실행

---
title: 'Phase 3: canary와 순차 adoption'
phase: 3
project_id: ai-harness-governance-plan
status: reference-template
depends_on: [2]
mutates_project_files: true
---

# Phase 3. canary와 순차 adoption

> 공개용 절차 템플릿입니다. 실제 프로젝트의 승인·완료 상태는 포함하지 않습니다.

## 1. 목적

실제 저장소에 kit release를 처음 적용한다. 한 번에 한 프로젝트씩, 프로젝트별 PR 하나로
lock·runtime·validator job을 채택하고, application business code에
비의도적 diff가 0임을 증명한다.

Phase 4는 이 phase 없이는 불가능하다. required CI를 붙일 대상 저장소에
**lock과 runtime**이 먼저 존재해야 한다. `SPEC_REGISTRY`는 이 phase의 산출물이 아니라
Phase 4가 만든다.

**이 phase는 실제 프로젝트 파일을 변경하는 첫 phase다.** 계획 문서 §14가 금지한
"기존 프로젝트의 `.ai/**`, `AGENTS.md`, CI 변경"은 이 phase에서 프로젝트별로,
저장소마다 별도 승인을 받아 해제된다. 저장소 하나의 승인이 다른 저장소로 전이되지 않는다.

## 2. 전제조건

### 2.1 공통 전제조건

| # | 조건 | 검사 방법 |
|---|---|---|
| P3.pre-1 | Phase 2 종료조건 G2-1 ~ G2-15 전부 충족 | [`PHASE_2`](PHASE_2_THREE_TIER_AND_FIXTURES.md) §6 |
| P3.pre-2 | 합성 fixture 전체가 통과 | `rake test` |
| P3.pre-3 | Phase 0 checkpoint가 보존되어 있다 | 각 저장소 `git for-each-ref refs/harness-checkpoint/`와 `$CHECKPOINT_ROOT` 존재 |
| P3.pre-4 | `evidence/FREEZE_NOTICE.md`의 해제 조건이 충족되었다 | [`PHASE_1`](PHASE_1_RELEASE_INTEGRITY.md) §4.7-36 |
| P3.pre-5 | 저장소별 개별 승인 | 저장소마다 사람 승인. 일괄 승인을 사용하지 않는다 |

### 2.2 저장소별 진입 전제조건

모든 값은 [`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §5의 재검사 명령으로 판정한다.
[`INVENTORY`](../INVENTORY_TEMPLATE.md) §4의 값은 기준선이며 착수 시점에 다시 측정한다.

| # | 조건 | 판정 기준 |
|---|---|---|
| E-1 | active stream 없음 | 모든 `ACTIVE_CONTEXT.yaml`의 `status`가 `idle`이고 `active_streams`가 빈 배열 |
| E-2 | LOCK 없음 | `.ai/tasks/**/LOCK.yaml`이 0건 |
| E-3 | 모든 worktree가 검토 가능한 dirty 수준 | `git worktree list`의 각 worktree에서 `git status --porcelain \| wc -l`이 승인된 상한 이하 |
| E-4 | checkpoint 존재 | worktree마다 `refs/harness-checkpoint/<ts>/<worktree_id>`가 존재하고 JSON index의 `restore_verified`가 true. untracked가 있으면 외부 archive도 존재 |
| E-5 | 기준 브랜치 확정 | adoption PR의 base 브랜치가 정해졌다. detached HEAD인 worktree는 base가 될 수 없다 |
| E-6 | `PROJECT_MAP`/`ENV_MATRIX` 사람 승인 | project context가 draft가 아니고 services/DB 정보가 채워져 있다 |
| E-7 | 해당 저장소의 D-NEED 항목 해소 | [`INVENTORY`](../INVENTORY_TEMPLATE.md) §6 |

## 3. 산출물

프로젝트별로 아래를 만든다. `<repo>`는 저장소 이름이다.

| 산출물 | 경로 | 소유권 |
|---|---|---|
| plan 증거 | 이 계획 저장소 `evidence/phase3/<repo>/plan.json` | generated |
| plan 사람 검토 기록 | `evidence/phase3/<repo>/REVIEW.md` | project-owned |
| diff 분류 결과 | `evidence/phase3/<repo>/diff-classification.txt` | generated |
| adoption PR | 대상 저장소의 브랜치 하나 + PR 하나 | 대상 저장소 |
| lock | 대상 저장소 `.ai/KIT_INSTALLATION.yaml` | kit이 쓰는 manifest |
| runtime | 대상 저장소 `.ai/runtime/**` | `kit-owned` |
| project override 자리 | 대상 저장소 `.ai/project/**` | `project-owned` |
| CI job (`validate-install`만) | 대상 저장소 `.github/workflows/agent-workflow-policy.yml` | `merge-owned` |
| receipt | 대상 저장소 `.ai/generated/adoption-receipt.json` | `generated` |
| 프로젝트별 완료 기록 | `evidence/phase3/<repo>/COMPLETION.md` | project-owned |

`SPEC_REGISTRY.yaml`은 이 phase의 산출물이 아니다. [`PHASE_4`](PHASE_4_SPEC_FRESHNESS_GATE.md)가 만든다.
`spec-gate` reusable workflow도 Phase 4 산출물이므로 이 phase의 CI job은 그것을 참조하지 않는다.

## 4. 실행 절차

### 4.1 두 canary 트랙

managed upgrade 경로와 legacy adoption 경로는 서로 다른 코드 경로다. 각각 canary가 필요하다.

| 트랙 | 재현하는 코드 경로 | canary | 근거 |
|---|---|---|---|
| A. managed upgrade | 기존 schema 2 manifest → 새 release로 upgrade. 경로 이동 migration 포함 | `sample-api` | 유일한 managed 설치. 주 worktree dirty 0, `ACTIVE_CONTEXT` `idle` |
| B. legacy adoption | manifest 없는 `legacy_unknown` → 최초 managed 설치 | `sample-worker` | `.ai/**`와 `AGENTS.md`가 있고 manifest 없음. `idle` |

트랙 A가 통과해도 트랙 B의 안전성은 증명되지 않는다. 두 트랙을 각각 통과시킨 뒤에만
나머지 저장소로 확장한다.

### 4.2 순서

managed upgrade와 legacy adoption을 각각 하나의 합성 fixture에서 검증한 뒤,
담당자가 정한 canary에 순차 적용한다. 그 다음 대상은 fresh inventory의 조건으로
선정한다. active work, 미검토 dirty 파일, 불명확한 소유권이 있으면 해당 대상을 연기한다.
이 템플릿은 고정된 프로젝트 수나 과거 실행 순서를 전제하지 않는다.

### 4.3 저장소별 adoption 절차

계획 문서 §3 질문 2의 10단계를 실행 가능한 체크리스트로 전개한다.
각 저장소에서 아래를 순서대로 수행한다.

1. `[read-only]` **재검사.** [`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §4.2의
   `recheck()`를 실행해 `evidence/phase3/<repo>/recheck-pre.txt`에 저장한다.
   §2.2의 E-1 ~ E-7을 판정한다.
2. `[read-only]` **불안정하면 중단.** E-1 ~ E-7 중 하나라도 불충족이면 그 저장소를
   `deferred + reason`으로 다시 기록하고 착수하지 않는다. 수정하지 않는다.
3. `[read-only]` **baseline 복원 가능성 확인.** Phase 0이 수집한 nested clone
   `<baseline-sha>` baseline과 현재 `.ai/**`를 비교해, 어떤 파일이 baseline에서 갈라졌는지
   목록을 만든다. baseline에서 원본을 복원할 수 없는 파일이 있으면 그 사실을 기록한다.
4. `[read-only]` **소유권 판정.** Phase 1의 `ownership_rules`로 `.ai/**`,
   `AGENTS.md`, `.githooks/**`의 모든 파일을 `kit-owned` / `merge-owned` /
   `project-owned` / `generated`로 분류해 `evidence/phase3/<repo>/ownership.txt`에 남긴다.
   분류 불가 항목이 있으면 fail-closed 하고 착수하지 않는다.
5. `[additive]` **checkpoint 갱신.** Phase 0 checkpoint 이후 변경이 있었으면
   [`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §4.5를 다시 실행해 새 checkpoint를 만든다.
   모든 worktree를 대상으로 한다.
6. `[additive]` **격리 maintenance worktree에 adoption 브랜치를 만든다.**
   `--detach`가 아니라 `-b`로 만든다. 이유는 아래 상자에 있다.
   worktree 위치는 `$HOME/orca-maintenance/<repo>/<ts>`로 한다.
   임시 디렉터리보다 작업을 보존할 수 있는 경로를 사용한다. 선택한 경로와 소유자를
   [인벤토리](../INVENTORY_TEMPLATE.md)에 기록한다.

> **plan과 apply는 같은 worktree의 같은 브랜치에서 수행해야 한다.**
> `plan_digest`는 `worktree_path`와 `branch`를 포함하고, apply가 그 두 값을 다시 계산해
> 비교한다([`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §8.2, §8.6-3). 격리 worktree에서 plan을
> 만들고 주 worktree의 다른 브랜치에서 apply하면 **명세대로 apply가 중단된다.**
> 따라서 adoption 브랜치를 maintenance worktree에 먼저 만들고, plan → 검토 → apply → push를
> 그 worktree 안에서 끝낸다.

```bash
REPO_DIR="$WORKSPACE/projects/$REPO"
TS="$(date +%Y%m%dT%H%M%S)"
WT="$WORKSPACE-maintenance/$REPO/$TS"
BRANCH="harness/adopt-$TS"
# managed canary는 upgrade.rb, legacy canary는 adopt.rb를 선택한다.
INSTALLER="$KIT/engine/install/upgrade.rb"

# adoption 브랜치를 maintenance worktree에 직접 만든다.
# base는 §2.2 E-5에서 확정한 브랜치다. 주 worktree의 checkout에 영향을 주지 않는다.
git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WT" "$BASE_BRANCH"

# plan을 그 worktree에서 만든다. worktree_path와 branch가 plan에 기록된다.
ruby "$INSTALLER" --json \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  --approve-path "AGENTS.md=$CURRENT_AGENTS_DIGEST" \
  --merge-path "AGENTS.md=$EVIDENCE/AGENTS.merged.md" \
  "$WT" \
  > "$EVIDENCE/plan.json"

# 기록된 값이 실제 대상과 일치하는지 즉시 확인한다.
ruby -rjson -e 'p JSON.parse(File.read(ENV["EVIDENCE"]+"/plan.json")).dig("target")'
```

7. `[read-only]` **파일별 diff 검토.** plan의 각 항목에 대해 `current_digest`,
   `expected_digest`, `desired_digest`, `ownership`, `action`을 사람이 확인하고
   `evidence/phase3/<repo>/REVIEW.md`에 판단을 기록한다.
   기존 `project-owned` 항목의 `action`은 `skip`이어야 한다. 신규 three-tier scaffold인
   `.ai/local/.gitignore`와 `.ai/project/agents/README.md`의 reviewed `create`만 허용한다.
   그 외 project-owned non-skip가 있으면 중단한다.
   `AGENTS.md`는 `merge-owned`이면서 `approval_required_paths`에 있으므로
   현재 바이트의 `--approve-path`와 검토된 병합 결과의 `--merge-path`를 함께 제공한다.
   두 digest가 plan에 고정되지 않으면 `conflict`로 남는다(SPEC §5).

   검토에 시간이 걸리면 그동안의 변경으로 `dirty_snapshot_digest`가 달라져 apply가
   중단될 수 있다. 그때는 우회하지 않고 plan을 다시 만든다. 범위는 해소된 D-NEED-12
   결정대로 정확한 plan 대상 경로와 하네스 allowlist의 합집합이다.

8. `[mutating: 대상 저장소]` **같은 worktree에서 apply.** 6단계의 `$WT`와 `$BRANCH` 안에서
   `--plan-digest`로 apply한다. plan 이후 source나 target이 변했으면 apply가 중단된다
   ([`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §8.6).

```bash
ruby "$INSTALLER" --apply \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  --approve-path "AGENTS.md=$CURRENT_AGENTS_DIGEST" \
  --merge-path "AGENTS.md=$EVIDENCE/AGENTS.merged.md" \
  --plan-digest "$(ruby -rjson -e 'print JSON.parse(File.read(ENV["EVIDENCE"]+"/plan.json")).fetch("projects").first.fetch("plan_digest")')" \
  "$WT"
git -C "$WT" add -- .ai AGENTS.md .githooks \
  .github/workflows/agent-workflow-policy.yml

PLAN_DIGEST="$(ruby -rjson -e 'print JSON.parse(File.read(ENV["EVIDENCE"]+"/plan.json")).fetch("projects").first.fetch("plan_digest")')"
ruby "$WT/.ai/runtime/scripts/adoption_receipt.rb" generate \
  --plan-digest "$PLAN_DIGEST" "$WT"
git -C "$WT" add -- .ai/generated/adoption-receipt.json
ruby "$WT/.ai/runtime/scripts/adoption_receipt.rb" verify --source index "$WT"
git -C "$WT" commit -m "chore(harness): adopt kit $KIT_VERSION"
ruby "$WT/.ai/runtime/scripts/adoption_receipt.rb" verify --source HEAD "$WT"
```
9. `[read-only]` **business code diff 0 검증.** 하네스 경로 밖의 diff가 0이어야 한다.

```bash
# 하네스 경로 allowlist 밖의 변경을 열거한다. 출력이 있으면 실패다.
BASE_SHA="$(git -C "$WT" merge-base "$BASE_BRANCH" HEAD)"
git -C "$WT" diff --name-only "$BASE_SHA..HEAD" \
  | grep -vE '^(\.ai/|AGENTS\.md$|\.githooks/|\.github/workflows/agent-workflow-policy\.yml$)' \
  > "$EVIDENCE/diff-classification.txt"
test ! -s "$EVIDENCE/diff-classification.txt"
```

출력이 비어 있지 않으면 각 항목에 대해 사람의 명시적 승인을 `REVIEW.md`에 기록하고,
승인되지 않은 항목이 하나라도 있으면 PR을 진행하지 않는다(Acceptance #7).

10. `[read-only]` **project-owned 무변경 검증.** 4단계의 `project-owned` 목록에 대해
    apply 전후 SHA-256을 비교한다. 하나라도 다르면 실패다(Acceptance #5).
11. `[read-only]` **`.ai/tasks/**` 보존 검증.** apply 전후 `.ai/tasks` 하위 파일 수와
    각 파일 digest가 동일해야 한다(Acceptance #6).
12. `[mutating: 대상 저장소]` **CI job과 receipt 검증.** 이 phase에서 추가하는 CI는
    `validate-install` **하나뿐**이다. Phase 4의 `spec-gate`를 참조하지 않는다.
    중앙 reusable workflow `spec-gate.yml`은 [`PHASE_4`](PHASE_4_SPEC_FRESHNESS_GATE.md) §4.5에서
    만들어지므로, 지금 참조하면 존재하지 않는 workflow를 가리켜 job이 실패한다.

    `validate-install` job이 하는 일: lock 스키마 검증, `kit_bundle_digest` 재계산 및 lock 비교,
    설치된 kit-owned 파일 digest 비교, ownership 회귀 확인. Phase 1과 Phase 2 산출물만 쓴다.

    receipt(`.ai/generated/adoption-receipt.json`)에는 **자기 자신이 속한 commit의 SHA를
    기록하지 않는다.** SPEC S-07에 따라 저장소 파일에는 tree digest만 넣는다.

```json
{
  "receipt_schema": 1,
  "kit_version": "0.4.4",
  "kit_bundle_digest": "sha256:...",
  "rendered_install_digest": "sha256:...",
  "plan_digest": "sha256:...",
  "adopted_branch": "harness/adopt-20300101T000000",
  "harness_tree_digest_algo": "sha256-framed-git-tree-v1",
  "harness_tree_digest": "sha256:...",
}
```

`harness_tree_digest`는 `.ai/**`, `AGENTS.md`, `.githooks/**`에 대해 SPEC §4.4 알고리즘을
적용한 값이다. 이 값은 파일을 쓰기 전에 계산할 수 없으므로, **receipt 자신을 제외한**
경로 집합에 대해 계산한다. 제외 대상은 `.ai/generated/adoption-receipt.json` 하나다.
staged index에서 생성·검증한 뒤 commit하며, PR의 `validate-install` job은 동일 receipt를
`HEAD`에서 재검증한다.
13. `[read-only]` **프로젝트 test와 validator 실행.** 저장소 고유 테스트 명령과
    `engine/validators/validate_install.rb`를 실행한다. 결과를 `COMPLETION.md`에 기록한다.
14. `[read-only]` **hook 활성화 여부 기록.** `core.hooksPath`를 이 phase에서 바꾸지 않는다.
    현재 상태를 기록만 한다. 실제 강제 여부는 Phase 4의 required CI에서 확인한다
    ([`INVENTORY`](../INVENTORY_TEMPLATE.md) §5 Δ-04).
15. `[mutating: 대상 저장소]` **브랜치 push와 PR 생성.** apply와 commit이 끝난
    `$WT` 안에서 push한다. base 브랜치에는 push하지 않는다.

```bash
git -C "$WT" push -u origin "$BRANCH"
gh pr create --repo "$OWNER/$REPO" --base "$BASE_BRANCH" --head "$BRANCH" \
  --title "chore(harness): adopt kit $KIT_VERSION" --body-file "$EVIDENCE/REVIEW.md"
```

16. `[additive]` **maintenance worktree 정리.** push가 끝난 뒤
    `git worktree remove "$WT"`를 실행하고 `git worktree list`에 남지 않음을 확인한다.
    정리 결과를 `COMPLETION.md`에 기록한다.
    이 단계를 생략하면 실측에서 발견된 방치 worktree 문제가 재발한다.
    브랜치는 원격에 남아 있으므로 worktree를 지워도 PR은 유지된다.
17. `[read-only]` **merge 여부는 별도 결정.** PR 생성까지가 이 절차의 범위다.
    merge는 저장소 담당자가 별도로 결정한다. 이 phase는 merge를 자동화하지 않는다.
18. `[additive]` **분류 갱신.** merge까지 끝난 저장소를
    [`INVENTORY`](../INVENTORY_TEMPLATE.md) §7에서 `migrated`로 변경한다.
    merge 전에는 `deferred`를 유지한다.

### 4.4 nested clone은 이 phase에서 제거하지 않는다

adoption이 끝난 저장소에서도 `ai-agentic-workflow-kit/` nested clone은 남긴다.
제거는 [`PHASE_5`](PHASE_5_OPERATIONS_AND_RETIREMENT.md)의 별도 PR에서만 수행한다
(계획 문서 D-03, Acceptance #16).

## 5. 검증 명령

`$REPO`는 대상 저장소 이름, `$EVIDENCE`는 `evidence/phase3/$REPO`다.

| # | 명령 | 기대 결과 |
|---|---|---|
| V3-1 | `ruby -e 'require "json"; JSON.parse(File.read(ENV["EVIDENCE"]+"/plan.json"))'` | exit 0 |
| V3-2 | plan JSON에서 기존 `project-owned` 항목의 `action` 집합 | `["skip"]`만 나온다. missing three-tier scaffold의 reviewed `create`만 별도 허용 |
| V3-3 | plan JSON의 `activity.active_streams`와 `activity.lock_paths` | 둘 다 빈 배열 |
| V3-4 | `test ! -s "$EVIDENCE/diff-classification.txt"` | exit 0. 실패 시 `REVIEW.md`에 항목별 승인이 있어야 한다 |
| V3-5 | apply 전후 `project-owned` 파일 SHA-256 비교 | 전부 동일 |
| V3-6 | apply 전후 `.ai/tasks` 파일 수와 digest 비교 | 전부 동일 |
| V3-7 | `ruby "$KIT/engine/validators/validate_install.rb" "$REPO_DIR"` | exit 0 |
| V3-8 | `ruby "$KIT/engine/install/status.rb" --json "$REPO_DIR"` | `state`가 `current`, exit 0 |
| V3-9 | lock의 `kit_bundle_digest`와 release manifest 값 비교 | 동일 (Acceptance #2) |
| V3-10 | `git -C "$REPO_DIR" worktree list \| grep -c "orca-maintenance"` | 0 |
| V3-11 | `git -C "$REPO_DIR" worktree list \| grep -c "/private/tmp"` | 0. 남아 있으면 D-NEED-05가 미해소다 |
| V3-12 | `test -d "$REPO_DIR/ai-agentic-workflow-kit"` | exit 0. 이 phase에서 nested clone은 남아 있어야 한다 |
| V3-13 | 저장소 고유 테스트 명령 | 저장소별로 정의. 결과를 `COMPLETION.md`에 기록 |
| V3-14 | `git -C "$REPO_DIR" for-each-ref refs/harness-checkpoint/ \| wc -l` | 1 이상 |
| V3-15 | receipt JSON에 commit SHA 필드가 없음을 확인. `grep -cE '"(code_sha\|commit)"' "$REPO_DIR/.ai/generated/adoption-receipt.json"` | 0. SPEC S-07에 따라 저장소 파일은 자기 commit SHA를 참조하지 않는다 |
| V3-16 | receipt의 `harness_tree_digest`를 재계산해 비교(receipt 자신 제외) | 동일 |
| V3-17 | plan JSON의 `worktree_path`와 apply를 수행한 worktree 비교 | 동일. 다르면 apply가 중단되었어야 한다 |
| V3-18 | plan JSON의 `branch`와 `$BRANCH` 비교 | 동일 |
| V3-19 | `grep -c 'spec-gate' "$REPO_DIR/.github/workflows/agent-workflow-policy.yml"` | 0. Phase 3의 CI job은 Phase 4 workflow를 참조하지 않는다 |
| V3-20 | `git -C "$REPO_DIR" for-each-ref --format='%(refname:short)' refs/remotes/origin/ \| grep -c "$BASE_BRANCH"` 및 base 브랜치의 push 이력 | 자동화가 base 브랜치에 push하지 않았다 |

## 6. 종료조건

### 6.1 저장소별 종료조건

각 저장소에서 아래를 모두 충족해야 그 저장소의 adoption이 끝난다.

| # | 종료조건 | 검증 | 계획 문서 대응 |
|---|---|---|---|
| G3-1 | 격리 worktree에서 생성한 plan을 사람이 검토했다 | `REVIEW.md` 존재, V3-1, V3-2 | §11 Phase 3 |
| G3-2 | application business code의 비의도적 diff가 0이다 | V3-4 | Acceptance #7 |
| G3-3 | 기존 `project-owned` 파일이 한 바이트도 변하지 않았다. 승인된 missing scaffold 생성은 별도 기록된다 | V3-5 | Acceptance #5 |
| G3-4 | `.ai/tasks/**`가 보존되었다 | V3-6 | Acceptance #6 |
| G3-5 | required project tests와 validator가 통과했다 | V3-7, V3-13 | §11 Phase 3 |
| G3-6 | lock이 exact version과 `kit_bundle_digest`를 pin한다 | V3-9 | Acceptance #2 |
| G3-7 | receipt가 존재하고 자기 commit SHA를 참조하지 않으며 tree digest가 일치한다 | V3-15, V3-16 | SPEC S-07 |
| G3-7a | plan과 apply가 같은 worktree의 같은 브랜치에서 수행되었다 | V3-17, V3-18 | SPEC §8.6-3 |
| G3-7b | 이 phase의 CI job이 Phase 4 산출물을 참조하지 않는다 | V3-19 | phase 의존 순서 |
| G3-8 | rollback이 가능하다 | V3-14 및 §7 절차 문서화 | §11 Phase 3 |
| G3-9 | maintenance worktree가 정리되었다 | V3-10, V3-11 | 실측 결함 대응 |
| G3-10 | nested clone이 그대로 남아 있다 | V3-12 | Acceptance #16 |

### 6.2 phase 종료조건

| # | 종료조건 | 검증 |
|---|---|---|
| G3-11 | 트랙 A canary(`sample-api`)가 G3-1 ~ G3-10을 통과했다 | 해당 저장소 `COMPLETION.md` |
| G3-12 | 트랙 B canary(`sample-worker`)가 G3-1 ~ G3-10을 통과했다 | 해당 저장소 `COMPLETION.md` |
| G3-13 | 모든 대상 저장소가 `migrated` 또는 `deferred + reason`으로 기록되었다 | [`INVENTORY`](../INVENTORY_TEMPLATE.md) §7 |
| G3-14 | fleet apply가 한 번도 실행되지 않았다 | 실행 로그. 저장소별 PR 외의 일괄 적용 기록이 0건 |
| G3-15 | D-NEED-01 ~ D-NEED-06이 해소되었거나 해당 저장소가 `deferred`로 남았다 | [`INVENTORY`](../INVENTORY_TEMPLATE.md) §6 |

`deferred`로 남는 저장소가 있어도 이 phase는 종료할 수 있다. 계획 문서 Acceptance #15는
모든 프로젝트의 마이그레이션 완료가 아니라 **상태 기록**을 요구한다.

## 7. 롤백

롤백 단위는 저장소 하나다. 한 저장소의 롤백이 다른 저장소에 영향을 주지 않는다.

| 상황 | 되돌리는 방법 |
|---|---|
| PR merge 전 | 브랜치를 삭제한다. base 브랜치는 변하지 않았다 |
| PR merge 후 | `git revert -m 1 <merge commit>`으로 되돌린다. `reset --hard`와 force push는 사용하지 않는다 |
| apply 중 실패 | installer가 자체 rollback을 수행하고 `.ai/local/backups/kit-installation-<stamp>-<pid>`에 백업을 남긴다. 그 백업으로 복원한다 |
| dirty 작업 손실 | Phase 0/§4.5의 `refs/harness-checkpoint/<ts>/<worktree_id>`와 `$CHECKPOINT_ROOT`의 untracked 아카이브로 복원한다 |
| maintenance worktree 잔존 | `git worktree remove --force "$WT"` 후 `git worktree list`로 확인한다 |
| lock만 잘못된 경우 | `.ai/KIT_INSTALLATION.yaml`을 이전 커밋 버전으로 되돌린다. runtime 파일은 그 lock에 맞는 release로 다시 apply한다 |

되돌릴 수 없는 단계는 없다. 단 `.ai/tasks/**`의 사용자 작업 증거는 checkpoint로만
복원되므로, checkpoint 없이 착수하는 것을 §2.2 E-4가 금지한다.

## 8. 이 phase가 승인하지 않는 작업

[`HARNESS_GOVERNANCE_MIGRATION_PLAN.md`](../../HARNESS_GOVERNANCE_MIGRATION_PLAN.md) §14에서
이 phase가 해제하는 것은 **승인된 저장소 하나에 대한 `.ai/**`, `AGENTS.md`,
`validate-install` CI job 추가와 브랜치 push, PR 생성**뿐이다. 다음은 금지된다.

- 여러 저장소를 대상으로 하는 fleet apply, 일괄 스크립트 실행
- PR merge의 자동 수행. merge는 항상 사람의 별도 결정이다
- `deferred` 상태 저장소에 대한 apply
- nested clone `ai-agentic-workflow-kit/` 삭제
- `core.hooksPath` 설정 변경 또는 hook 활성화
- Phase 0 checkpoint 삭제
- `git reset --hard`, `git clean`, `git push --force`, 브랜치 강제 삭제
- base 브랜치로의 직접 push. push 대상은 항상 새 adoption 브랜치다
- Phase 4 산출물(`spec-gate` reusable workflow, `SPEC_REGISTRY`)에 대한 참조 추가
- production DB 접속, live provider 호출, 배포
- 전역 Codex/Claude/Kiro 설정 변경, MCP 등록 변경
- application business code의 수정. migration이 코드를 고치지 않는다(계획 문서 §3 표)

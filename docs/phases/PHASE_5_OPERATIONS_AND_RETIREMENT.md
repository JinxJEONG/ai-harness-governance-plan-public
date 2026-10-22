---
title: 'Phase 5: 운영 자동화와 nested clone 퇴역'
phase: 5
project_id: ai-harness-governance-plan
status: reference-template
depends_on: [4]
mutates_project_files: true
---

# Phase 5. 운영 자동화와 nested clone 퇴역

> 공개용 절차 템플릿입니다. 실제 프로젝트의 승인·완료 상태는 포함하지 않습니다.

## 1. 목적

fleet 상태를 주기적으로 읽어 drift를 가시화하고, 자동화가 직접 push하지 않고 PR만
만들도록 고정하고, release 채널을 stable/candidate로 나눈다. adoption과 baseline 복원
가능성이 확인된 저장소에서만 오래된 nested kit clone을 별도 PR로 제거한다.

이 phase는 마지막이다. nested clone은 과거 설치 baseline의 유일한 증거이므로,
Phase 3의 adoption acceptance와 Phase 4의 gate가 모두 성립한 뒤에만 폐기할 수 있다.

## 2. 전제조건

| # | 조건 | 검사 방법 |
|---|---|---|
| P5.pre-1 | Phase 4 종료조건 G4-1 ~ G4-16가 대상 저장소에서 충족 | [`PHASE_4`](PHASE_4_SPEC_FRESHNESS_GATE.md) §6 |
| P5.pre-2 | 대상 저장소가 `migrated` | [`INVENTORY`](../INVENTORY_TEMPLATE.md) §7 |
| P5.pre-3 | Phase 0 baseline 인벤토리가 보존되어 있다 | `evidence/<snap>/baseline/<repo>--nested-clone.sha256` 존재 |
| P5.pre-4 | Phase 0 checkpoint가 보존되어 있다 | `refs/harness-checkpoint/*`와 `$CHECKPOINT_ROOT` |
| P5.pre-5 | 저장소별 개별 승인 | nested clone 퇴역은 저장소마다 별도 승인. 실제 형태는 §4.5를 따른다 |
| P5.pre-6 | 자동화의 push 범위가 **구조적으로** 제한됨 | 브랜치 ref를 만들려면 `contents: write`가 필요하고 PR 생성에는 `pull-requests: write`가 필요하다. 따라서 권한을 빼는 방식으로는 제한할 수 없다. 대신 ruleset/branch protection으로 base 브랜치 push를 차단하고 그 설정을 API로 확인한다(§4.2-6a) |

## 3. 산출물

| 산출물 | 경로 | 종류 |
|---|---|---|
| fleet inventory 수집기 | 중앙 kit `engine/inventory/fleet_report.rb` | 신규 |
| fleet 리포트 | 이 계획 저장소 `evidence/fleet/<date>/report.json` + `report.md` | generated |
| drift 조회 뷰 | 이 계획 저장소 `docs/FLEET_STATUS.md` (리포트에서 생성) | generated |
| doc-gardener | 중앙 kit `engine/gardener/propose_drift_pr.rb` | 신규 |
| 채널 정의 | 중앙 kit `docs/RELEASE_CHANNELS.md`, `release-channels.json` | 신규 |
| GitHub Release 전환 | `source.kind`를 `github-release`로 바꾸는 PR (저장소별) | 대상 저장소 |
| nested clone 퇴역 영수증 | 이 계획 저장소 `evidence/phase5/<repo>/RETIREMENT_RECEIPT.md` | project-owned |
| nested clone bundle 보존 | `$CHECKPOINT_ROOT/<repo>/nested-clone-<baseline-sha>.bundle` | 저장소 밖 |
| `.gitignore` 정리 PR | 해당 해당 항목이 있는 저장소만 | 대상 저장소 |
| 제거 전 baseline 재현 증거 | `evidence/phase5/<repo>/baseline-restore.md` | project-owned |
| gardener 권한 설정 증거 | `evidence/phase5/<repo>/branch-protection.json` | generated |
| 완료 기록 | `evidence/phase5/<repo>/COMPLETION.md` | project-owned |

## 4. 실행 절차

### 4.1 P5-1. read-only scheduled fleet inventory

1. `[additive]` `engine/inventory/fleet_report.rb`를 만든다. 수집 항목은
   [`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §4.2의 `recheck()`와 같은 집합에
   아래를 더한다. 모든 명령은 read-only다.

| 항목 | 출처 |
|---|---|
| `desired_kit_version`, `desired_kit_bundle_digest` | 저장소 lock `.ai/KIT_INSTALLATION.yaml` |
| `installed_rendered_install_digest` | 같은 lock |
| `latest_stable_version`, `latest_candidate_version` | 중앙 `release-channels.json` |
| `drift_state` | `current` / `upgrade_available` / `blocked` / `legacy_unknown` / `invalid` |
| `spec_gate_present` | 저장소 CI caller 존재 여부와 참조 SHA |
| `registry_digest` | `.ai/SPEC_REGISTRY.yaml`의 SHA-256 |
| `worktrees` | `git worktree list` 전체. 휘발성 경로(`/private/tmp`, `/tmp`) 사용 시 경고 |
| `checkpoint_refs` | `refs/harness-checkpoint/*` |

2. `[additive]` 리포트는 이 계획 저장소의 `evidence/fleet/<date>/`에 쓴다.
   애플리케이션 저장소에는 쓰지 않는다.
3. `[additive]` `docs/FLEET_STATUS.md`를 리포트에서 생성한다.
   저장소별 desired/installed 버전과 drift 상태를 한 표로 보여준다(계획 문서 §11 Phase 5).
4. `[additive]` **금지 목록을 코드로 강제한다.** `fleet_report.rb`는 아래를 실행하지 않는다.
   실행 시도 자체가 없어야 한다: `git commit`, `git push`, `git checkout`, `git clean`,
   `git stash push`, `git worktree add`, installer apply/upgrade, `docker run`.
5. `[read-only]` 스케줄 실행은 로컬 스케줄러 또는 중앙 저장소의 워크플로에서 수행한다.
   애플리케이션 저장소의 CI에 스케줄을 넣지 않는다.

### 4.2 P5-2. doc-gardener

6. `[additive]` `engine/gardener/propose_drift_pr.rb`를 만든다. 동작은 다음으로 제한한다.
   - 격리 worktree(`$HOME/orca-maintenance/<repo>/<ts>`)를 만든다.
     `/private/tmp` 아래에 만들지 않는다([`INVENTORY`](../INVENTORY_TEMPLATE.md) §4.2(b)).
   - adoption과 같은 방식으로 **worktree에 새 브랜치를 만들고** 그 안에서 plan → apply를 한다
     ([`PHASE_3`](PHASE_3_CANARY_ADOPTION.md) §4.3-6). `plan_digest`가 `worktree_path`와
     `branch`를 결속하므로 다른 곳에서 apply하면 중단된다.
   - generated facts를 재생성해 drift가 있으면 그 파일만 갱신한다.
   - 새 브랜치를 push하고 **PR만 생성한다.** base 브랜치에 push하지 않는다.
   - 작업 후 `git worktree remove`로 정리한다.

6a. `[mutating: 대상 저장소 설정]` **권한 모델을 바로잡는다.** 브랜치 ref를 만들려면
    `contents: write`가 필요하고 PR 생성에는 `pull-requests: write`가 필요하다.
    따라서 "contents write 없이 PR만 생성"은 성립하지 않는다. 권한을 빼는 대신
    **base 브랜치 push를 구조적으로 차단**한다.

| 수단 | 설정 | 확인 방법 |
|---|---|---|
| 전용 GitHub App 또는 bot 계정 | `contents: write` + `pull-requests: write`만 부여 | 설치 권한 목록 |
| base 브랜치 보호 | PR 필수, 직접 push 금지, bypass 목록에 자동화 미포함 | `gh api "repos/$OWNER/$REPO/branches/$BASE/protection"` |
| ruleset | `creation`/`update` 규칙과 bypass actors 확인 | `gh api "repos/$OWNER/$REPO/rulesets"` |
| 사후 감사 | base 브랜치에 자동화 계정의 push 이력 0건 | `gh api "repos/$OWNER/$REPO/commits?sha=$BASE" --jq '[.[].committer.login] \| unique'` |

    수집 결과를 `evidence/phase5/<repo>/branch-protection.json`에 남긴다.

7. `[additive]` gardener가 건드릴 수 있는 경로를 allowlist로 고정한다.
   `.ai/generated/**`, `.ai/runtime/**`, `.ai/KIT_INSTALLATION.yaml`만 허용한다.
   `project-owned` 경로와 application code는 어떤 경우에도 변경하지 않는다.
   `AGENTS.md`는 `merge-owned`이지만 `approval_required_paths`에 있으므로 gardener가
   자동으로 바꾸지 않는다(SPEC §5).
8. `[additive]` **negative**: gardener가 `project-owned` 파일을 수정하도록 유도한 입력에서
   변경 0건이어야 한다.
9. `[additive]` **negative**: gardener에 `contents: write`가 있는 상태에서도
   base 브랜치 push가 **보호 설정에 의해** 거부되는지 확인한다.
   코드 경로 검사(`git push` 대상이 항상 새 브랜치)와 서버 측 거부를 모두 확인한다.
   코드만 검사하면 코드가 바뀌었을 때 방어가 사라진다.
10. `[additive]` gardener가 만든 PR도 Phase 4의 required gate를 통과해야 한다.
    gate를 우회하는 경로를 두지 않는다.

### 4.3 P5-3. stable / candidate 채널

11. `[additive]` `release-channels.json`을 만든다.

```json
{
  "channels_schema": 1,
  "stable": { "version": "0.4.1", "kit_bundle_digest": "sha256:...", "promoted_at": "2030-01-01T00:00:00Z" },
  "candidate": { "version": "0.5.0", "kit_bundle_digest": "sha256:...", "created_at": "2030-01-01T00:00:00Z" },
  "promotion_policy": {
    "requires_fixture_pass": true,
    "requires_canary_repos": ["sample-api", "sample-worker"],
    "requires_days_in_candidate": 7
  }
}
```

12. `[additive]` candidate → stable 승격 조건을 문서화한다. 합성 fixture 전체 통과,
    두 canary 저장소에서 gate 통과, 최소 대기 기간. 승격은 사람이 승인한다.
13. `[additive]` 프로젝트는 채널이 아니라 exact digest를 pin한다. 채널은 "무엇을 권하는가"만
    표현하며, lock을 자동으로 바꾸지 않는다(계획 문서 D-01).

### 4.4 P5-4. GitHub Release 전환

14. `[read-only]` [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §6의 전환표를 확인한다.
    바뀌는 필드는 `source.kind`와 `source.locator`뿐이고 `kit_bundle_digest`는 불변이다.
15. `[mutating: 중앙 kit]` tag를 원격에 push하고 GitHub Release에 tarball과
    `release-manifest.json`, `.sha256`을 첨부한다. 이 단계는 계획 문서 §14가 금지한
    "package/release 발행"을 이 phase에서 명시 승인으로 해제하는 지점이다.
16. `[mutating: 대상 저장소]` 저장소별 PR로 lock의 `source.kind`를 `github-release`로,
    `locator`를 릴리스 URL로 바꾼다. `kit_bundle_digest`는 그대로여야 한다.
17. `[read-only]` 전환 후 resolver가 다운로드한 내용으로 `kit_bundle_digest`를 재계산해
    lock과 비교하는지 확인한다(SPEC §6 resolver 요건).
18. `[additive]` **negative**: locator를 다른 내용의 tarball로 바꾼 PR → apply 거부.

### 4.5 P5-5. nested clone 퇴역

제거 대상은 현재 inventory에서 확인한 nested clone이다. 아래 절차를 대상별로 적용하며
프로젝트 수나 baseline SHA를 하드코딩하지 않는다.

### 4.5.1 nested clone의 추적 상태 확인

`git ls-files -- ai-agentic-workflow-kit`와 `git status`로 각 대상의 추적 상태를 확인한다.
ignored 또는 untracked clone의 로컬 삭제는 PR diff로 증명할 수 없다.
원본을 복원 가능한 bundle로 보존하고, 로컬 작업과 Git 변경을 구분해 기록한다.
이 공개 예시는 특정 저장소의 tracked 수나 dirty 상태를 보증하지 않는다.

따라서 퇴역은 세 부분으로 나눈다.

| 부분 | 성격 | 추적 방법 |
|---|---|---|
| (a) bundle 보존 | 로컬 파일 생성 | `$CHECKPOINT_ROOT/<repo>/nested-clone-<baseline-sha>.bundle` |
| (b) 디렉터리 제거 | **로컬 파일시스템 작업.** git 이력에 남지 않는다 | 이 계획 저장소의 `RETIREMENT_RECEIPT.md`(커밋되므로 검토 가능) |
| (c) `.gitignore` 정리 | PR | 항목이 있는 3개 저장소만 |

저장소별로 아래 전제조건을 **모두** 충족해야 퇴역을 시작할 수 있다.
하나라도 미충족이면 그 저장소의 nested clone은 남긴다.

| # | 전제조건 | 검증 |
|---|---|---|
| R-1 | 해당 저장소가 `migrated` | [`INVENTORY`](../INVENTORY_TEMPLATE.md) §7 |
| R-2 | [`PHASE_3`](PHASE_3_CANARY_ADOPTION.md) 종료조건 G3-1 ~ G3-10 충족 | `evidence/phase3/<repo>/COMPLETION.md` |
| R-3 | Phase 4 종료조건 G4-1 ~ G4-16 충족 | `evidence/phase4/<repo>/COMPLETION.md` |
| R-4 | **baseline 복원을 실제로 재현했다** | §4.5-19의 재현 절차 통과 기록 |
| R-5 | Phase 0 checkpoint가 보존되어 있다 | `refs/harness-checkpoint/*`, `$CHECKPOINT_ROOT` |
| R-6 | nested clone에 커밋되지 않은 고유 작업이 없다 | 해당 clone에서 `git status --porcelain`이 비어 있거나, 있는 내용이 bundle에 포함되었다 |
| R-7 | nested clone이 빌드·런타임에 참조되지 않는다 | §4.5-20의 검색 결과에 빌드·CI·import 참조가 0건 |

19. `[read-only]` **baseline 복원 재현.** nested clone을 지우기 전에, 그 clone이
    제공하던 baseline을 다른 방법으로 얻을 수 있음을 실제로 증명한다.

```bash
# 1) Phase 0이 기록한 baseline 목록을 읽는다
BASE="$EVIDENCE0/baseline/$REPO--nested-clone.sha256"
# 2) 중앙 kit에서 같은 SHA를 checkout한 임시 clone을 만든다(저장소 밖)
TMP="$HOME/orca-maintenance/$REPO/baseline-$TS"
git clone --no-checkout "$CENTRAL_KIT" "$TMP"
git -C "$TMP" checkout --detach <baseline-sha>
# 3) 파일 목록과 digest가 Phase 0 기록과 일치하는지 비교한다
git -C "$TMP" ls-tree -r <baseline-sha> > "$TMP/ls-tree.txt"
diff <(grep -v '^--' "$BASE") "$TMP/ls-tree.txt"
# 4) 결과를 evidence/phase5/<repo>/baseline-restore.md에 기록한다
rm -rf "$TMP"
```

중앙 kit에서 `<baseline-sha>`를 얻을 수 없으면 R-4는 미충족이다.

19a. `[additive]` **bundle 보존.** R-4 충족 여부와 무관하게, 제거 전에 nested clone
     자체를 bundle로 저장소 밖에 보존한다. 이것이 (b)의 유일한 되돌림 수단이다.

```bash
git -C "$REPO_DIR/ai-agentic-workflow-kit" bundle create \
  "$CHECKPOINT_ROOT/$REPO/nested-clone-<baseline-sha>.bundle" --all
chmod 600 "$CHECKPOINT_ROOT/$REPO/nested-clone-<baseline-sha>.bundle"
shasum -a 256 "$CHECKPOINT_ROOT/$REPO/nested-clone-<baseline-sha>.bundle"
```

20. `[read-only]` R-7 참조 검색. **출력이 비어 있어야 통과다.**

```bash
git -C "$REPO_DIR" grep -n -I -- 'ai-agentic-workflow-kit' \
  -- . ':(exclude)ai-agentic-workflow-kit' ':(exclude).ai/tasks' ':(exclude)*.md' \
  > "$EVIDENCE/nested-references.txt" || true
# 빌드·CI·import 참조만 남긴 뒤 빈 파일인지 확인한다
test ! -s "$EVIDENCE/nested-references.txt"
```

문서와 과거 task 기록의 언급은 제거 대상이 아니므로 `*.md`를 제외했다.
출력이 비어 있지 않으면 먼저 그 참조를 제거하는 별도 PR을 만든다.

21. `[mutating: 로컬 파일시스템]` **디렉터리 제거.** git 작업이 아니다.
    `$REPO_DIR/ai-agentic-workflow-kit`를 제거한다. 이 작업은 어떤 PR에도 나타나지 않으므로
    22단계의 영수증이 유일한 추적 수단이다.
22. `[additive]` **retirement receipt 작성.** 이 계획 저장소에
    `evidence/phase5/<repo>/RETIREMENT_RECEIPT.md`를 만들고 커밋한다.
    이 계획 저장소는 tracked 저장소이므로 영수증은 검토와 이력 추적이 가능하다.

```yaml
repo: sample-api
nested_clone_path: ai-agentic-workflow-kit
was_git_tracked: false            # 예시: 실제 대상에서 다시 확인
gitignore_entry: '.gitignore:13'  # 없으면 null
head_before_removal: <baseline-sha>
ls_tree_digest_before: 'sha256:...'   # Phase 0 baseline 기록과 동일해야 한다
bundle_path: $CHECKPOINT_ROOT/sample-api/nested-clone-<baseline-sha>.bundle
bundle_sha256: 'sha256:...'
uncommitted_in_clone: 0
baseline_restore_verified: true
removed_at: '2030-01-01T00:00:00Z'
removed_by: '<actor>'
approvals: ['<approver>']
gitignore_cleanup_pr: 'https://github.com/<org>/<repo>/pull/<n>'   # 없으면 null
```

23. `[mutating: 대상 저장소]` **`.gitignore` 정리 PR.** `.gitignore`에 항목이 있는
    3개 저장소(`sample-api`, `sample-worker`, `sample-web`)에서만
    해당 한 줄을 제거하는 PR을 만든다. 다른 변경을 섞지 않는다.
    항목이 없는 3개 저장소에서는 이 단계를 건너뛰고 그 사실을 영수증에 기록한다.
24. `[read-only]` 제거 후 저장소 테스트와 Phase 4 gate가 통과함을 확인한다.
25. `[additive]` `evidence/phase5/<repo>/COMPLETION.md`에 R-1 ~ R-7 충족 근거,
    baseline 재현 결과, bundle digest, 영수증 경로, `.gitignore` PR 링크를 기록한다.

### 4.6 P5-6. 잔여 정리

26. `[additive]` [`INVENTORY`](../INVENTORY_TEMPLATE.md) §6의 D-NEED 항목 중 남은 것을
    종료 처리하거나 후속 결정 항목으로 이관한다.
27. `[additive]` `docs/FLEET_STATUS.md`가 모든 저장소의 desired/installed/drift를
    보여주는지 확인한다.
28. `[read-only]` `/private/tmp` 아래에 남은 maintenance worktree가 0건임을 확인한다.
    임시 디렉터리의 maintenance worktree가 이 시점까지
    남아 있으면 D-NEED-05가 미해소다.

## 5. 검증 명령

| # | 명령 | 기대 결과 |
|---|---|---|
| V5-1 | `ruby "$KIT/engine/inventory/fleet_report.rb" --out evidence/fleet/$(date +%F)` | exit 0, `report.json`과 `report.md` 생성 |
| V5-2 | `grep -rnE '\bgit (commit\|push\|checkout\|clean\|stash push\|worktree add)\b' "$KIT/engine/inventory/fleet_report.rb"` | 출력 없음 |
| V5-3 | fleet 리포트 실행 전후 각 애플리케이션 저장소의 `git status --porcelain \| shasum -a 256` | 전부 동일 |
| V5-4 | `ruby -rjson -e 'd=JSON.parse(File.read("evidence/fleet/<date>/report.json")); abort unless d["repos"].all? { \|r\| r.key?("drift_state") }'` | exit 0 |
| V5-5 | `grep -c 'drift_state' docs/FLEET_STATUS.md` | 1 이상. 저장소 수만큼 행이 있다 |
| V5-6 | `grep -rnE '\bgit push\b' "$KIT/engine/gardener/propose_drift_pr.rb"` | push 대상이 항상 새 브랜치 변수임을 코드로 확인. base 브랜치 리터럴이 없다 |
| V5-6a | `gh api "repos/$OWNER/$REPO/branches/$BASE/protection" --jq '.allow_force_pushes, .required_pull_request_reviews'` | 보호가 설정되어 있고 자동화가 bypass 목록에 없다 |
| V5-6b | **negative**: 자동화 계정으로 base 브랜치에 push 시도 | 서버 측에서 거부된다. 코드 검사만으로는 부족하다 |
| V5-6c | `gh api "repos/$OWNER/$REPO/commits?sha=$BASE" --jq '[.[].committer.login] \| unique'` | 자동화 계정이 목록에 없다 |
| V5-7 | **negative**: gardener를 `project-owned` 파일이 drift한 fixture에 실행 | 변경 0건 |
| V5-7a | **negative**: gardener를 `AGENTS.md`가 drift한 fixture에 실행 | 변경 0건. `approval_required_paths`에 있다 |
| V5-8 | gardener 실행 후 `git worktree list \| grep -c orca-maintenance` | 0 |
| V5-9 | gardener가 만든 PR에 대해 Phase 4 gate 실행 | 통과 또는 정당한 실패. gate 우회 경로 없음 |
| V5-10 | `ruby -rjson -e 'JSON.parse(File.read("release-channels.json"))'` | exit 0 |
| V5-11 | lock의 `source.kind`를 `github-release`로 바꾼 뒤 `kit_bundle_digest` 비교 | 전환 전후 동일 (SPEC §6.2) |
| V5-12 | **negative**: locator를 다른 tarball로 교체해 apply | 거부 (SPEC §6.1-4) |
| V5-13 | 각 저장소에서 `diff <(baseline 기록) <(<baseline-sha> ls-tree)` | 차이 0건. R-4 |
| V5-13a | `git -C "$REPO_DIR" ls-files -- ai-agentic-workflow-kit \| wc -l` | 0. 실측과 일치한다. 0이 아니면 §4.5.1의 전제가 깨졌으므로 절차를 재검토한다 |
| V5-14 | `test ! -s "$EVIDENCE/nested-references.txt"` | exit 0. **파일이 비어 있어야 통과다.** R-7 |
| V5-15 | `test -f "$EVIDENCE/RETIREMENT_RECEIPT.md"` 및 `ruby -ryaml -e '...'`로 필수 키 확인 | 영수증이 존재하고 `bundle_sha256`, `ls_tree_digest_before`, `removed_at`, `approvals`가 채워져 있다 |
| V5-15a | `test -f "$CHECKPOINT_ROOT/$REPO/nested-clone-<baseline-sha>.bundle"` 및 digest 비교 | 존재하고 영수증의 `bundle_sha256`과 일치 |
| V5-15b | `git bundle verify "$CHECKPOINT_ROOT/$REPO/nested-clone-<baseline-sha>.bundle"` | exit 0. bundle이 실제로 복원 가능하다 |
| V5-15c | `.gitignore` 항목이 있던 3개 저장소의 정리 PR diff | `.gitignore` 한 줄만 변경 |
| V5-16 | 제거 후 `test -d "$REPO_DIR/ai-agentic-workflow-kit"` | 실패해야 한다(디렉터리 없음) |
| V5-17 | 제거 후 저장소 테스트와 gate | 통과 |
| V5-18 | `for r in <all repos>; do git -C $r worktree list; done \| grep -c '/private/tmp'` | 0 |
| V5-19 | `ls "$CHECKPOINT_ROOT"` | Phase 0 checkpoint가 여전히 존재한다 |

## 6. 종료조건

| # | 종료조건 | 검증 | 계획 문서 대응 |
|---|---|---|---|
| G5-1 | fleet inventory가 read-only로 동작하고 애플리케이션 저장소를 변경하지 않는다 | V5-2, V5-3 | §11 Phase 5 |
| G5-2 | 저장소별 desired/installed 버전과 drift 상태를 조회할 수 있다 | V5-1, V5-4, V5-5 | §11 Phase 5 |
| G5-3 | 자동화가 애플리케이션 저장소의 base 브랜치에 push하지 못한다. 권한 제거가 아니라 **보호 설정으로** 차단된다 | V5-6, V5-6a, V5-6b, V5-6c | §11 Phase 5 |
| G5-4 | doc-gardener가 `project-owned`와 승인 필요 경로를 변경하지 않는다 | V5-7, V5-7a | Acceptance #5 |
| G5-5 | gardener가 만든 격리 worktree가 정리된다 | V5-8 | 실측 결함 대응 |
| G5-6 | stable/candidate 채널이 정의되고 승격에 사람 승인이 필요하다 | V5-10 | §11 Phase 5 |
| G5-7 | GitHub Release 전환이 `kit_bundle_digest`를 바꾸지 않는다 | V5-11, V5-12 | [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §6.2 |
| G5-8 | 각 퇴역 대상에 대해 R-1 ~ R-7이 기록되었다 | `evidence/phase5/<repo>/COMPLETION.md` | Acceptance #16 |
| G5-9 | baseline 복원이 실제로 재현되었고 bundle이 검증되었다 | V5-13, V5-15a, V5-15b | Acceptance #16 |
| G5-10 | **퇴역이 커밋된 영수증으로 추적된다.** nested clone은 tracked 파일이 아니므로 PR diff로는 표현되지 않는다 | V5-13a, V5-15, V5-15c | Acceptance #16 |
| G5-11 | 제거 후에도 저장소 테스트와 gate가 통과한다 | V5-16, V5-17 | §11 Phase 5 |
| G5-12 | 모든 제거 대상의 baseline과 rollback 증거가 보존되었다 | V5-19 | §11 Phase 5 |
| G5-13 | 휘발성 경로의 maintenance worktree가 0건이다 | V5-18 | D-NEED-05 |
| G5-14 | 남은 D-NEED 항목이 종료 또는 이관되었다 | [`INVENTORY`](../INVENTORY_TEMPLATE.md) §6 | §12 |

R-1 ~ R-7을 충족하지 못한 저장소의 nested clone은 남긴 채로 이 phase를 종료할 수 있다.
그 사실을 `FLEET_STATUS.md`에 명시한다. 제거하지 않는 것이 실패가 아니다.
증거 없이 제거하는 것이 실패다.

## 7. 롤백

| 상황 | 되돌리는 방법 |
|---|---|
| fleet 리포트가 잘못된 경우 | 리포트 파일 삭제. 애플리케이션 저장소에는 영향이 없다 |
| gardener PR이 잘못된 경우 | PR을 닫고 브랜치를 삭제한다. base는 변하지 않았다 |
| gardener가 잘못 apply한 경우 | PR merge 전이면 브랜치 폐기. merge 후면 `git revert -m 1` |
| 채널 승격이 잘못된 경우 | `release-channels.json`의 `stable`을 이전 버전으로 되돌린다. 프로젝트 lock은 자동으로 따라가지 않으므로 저장소 영향이 없다 |
| GitHub Release 전환 실패 | lock의 `source.kind`를 `local`로, `locator`를 파일 경로로 되돌린다. `kit_bundle_digest`는 그대로이므로 재검증이 통과한다 |
| nested clone 제거 후 문제 발생 | **`git revert`로는 되돌릴 수 없다.** tracked 파일이 아니므로 제거가 git 이력에 없다. `$CHECKPOINT_ROOT`의 bundle에서 복원한다: `git clone "$CHECKPOINT_ROOT/$REPO/nested-clone-<baseline-sha>.bundle" "$REPO_DIR/ai-agentic-workflow-kit"` |
| `.gitignore` 정리 PR 문제 | 그 PR만 `git revert`한다. 디렉터리 존재 여부와 무관하다 |
| GitHub Release 게시 취소 | Release를 unpublish한다. 이미 다운로드된 artifact는 회수할 수 없다 |

되돌리기 어려운 단계는 두 개다.

1. **GitHub Release 게시**(§4.4-15). 게시 후 다운로드된 artifact는 회수할 수 없다.
   그러나 정체성이 `kit_bundle_digest`이므로, 잘못된 release는 채널에서 내리고
   새 버전을 게시하는 방식으로 무효화한다.
2. **nested clone 디렉터리 제거**(§4.5-21). 이것은 로컬 파일시스템 작업이며 git 이력에
   남지 않으므로 `revert`가 통하지 않는다. **유일한 복원 수단은 §4.5-19a의 bundle이다.**
   그래서 bundle 생성과 `git bundle verify` 통과를 종료조건 G5-9에 넣었고,
   R-4를 별도로 요구한다.

## 8. 이 phase가 승인하지 않는 작업

[`HARNESS_GOVERNANCE_MIGRATION_PLAN.md`](../../HARNESS_GOVERNANCE_MIGRATION_PLAN.md) §14에서
이 phase가 해제하는 것은 **중앙 kit tag의 원격 push와 GitHub Release 게시, 승인된 저장소의
nested clone 로컬 제거와 `.gitignore` 정리 PR**이다. 다음은 금지된다.

- 자동화의 애플리케이션 저장소 base 브랜치 push, force push, 브랜치 보호 우회
- 자동화의 PR 자동 merge
- R-1 ~ R-7 중 하나라도 미충족인 저장소의 nested clone 제거
- bundle(§4.5-19a) 없이 nested clone 디렉터리를 제거하는 것. 복원 수단이 사라진다
- 영수증(§4.5-22) 없이 제거하는 것. 추적 불가능해진다
- Phase 0 checkpoint 또는 `$CHECKPOINT_ROOT` 삭제
- `deferred` 상태 저장소에 대한 gardener 실행
- `project-owned` 경로에 대한 자동 변경
- production DB 접속, live provider 호출, 실제 배포 실행
- required gate 우회 또는 관리자 권한 merge
- 전역 설정과 hook 활성화 변경
- application business code 수정

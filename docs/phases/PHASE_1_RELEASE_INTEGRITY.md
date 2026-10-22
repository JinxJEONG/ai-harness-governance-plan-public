---
title: 'Phase 1: 중앙 kit release integrity'
phase: 1
project_id: ai-harness-governance-plan
status: reference-template
depends_on: [0]
target_repository: $WORKSPACE/ai-agentic-workflow-kit
mutates_project_files: false
---

# Phase 1. 중앙 kit release integrity

> 공개용 절차 템플릿입니다. 실제 프로젝트의 승인·완료 상태는 포함하지 않습니다.

## 1. 목적

중앙 kit이 불변 release artifact를 만들고, 그 artifact만이 적용될 수 있게 하고,
plan과 apply를 하나의 digest로 결속한다. project-owned 파일이 사람 승인 없이
변경·삭제되지 않음을 회귀 테스트로 고정한다.

Phase 2 이후는 이 phase 없이는 불가능하다. pin할 `kit_bundle_digest`가 없으면
프로젝트 lock이 성립하지 않고, 두 버전 side-by-side 실행도 정의되지 않는다.

이 phase의 변경 대상은 `$WORKSPACE/ai-agentic-workflow-kit` 하나다.
어떤 애플리케이션 저장소도 건드리지 않는다.

## 2. 전제조건

| # | 조건 | 검사 방법 |
|---|---|---|
| P1.pre-1 | Phase 0 종료조건 G0-1 ~ G0-9 전부 충족 | [`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §6 |
| P1.pre-2 | [`RELEASE_ARTIFACT_SPEC`](../RELEASE_ARTIFACT_SPEC.md) 승인 | 문서 status가 `normative` |
| P1.pre-3 | 중앙 kit 수정 승인 | 사람 승인. 계획 문서 §14가 금지한 항목을 이 phase에 한해 해제하는 명시적 승인이 필요하다 |
| P1.pre-4 | `rake` 기본 태스크가 현재 통과 | `cd $WORKSPACE/ai-agentic-workflow-kit && rake` (변경 전 baseline 확보) |
| P1.pre-5 | Docker 사용 가능 | `docker info`. Phase 1에서는 필수가 아니지만 Phase 2 준비를 위해 확인한다 |
| P1.pre-6 | 현재 dirty 작업의 처분과 release 버전 결정 | dirty 파일을 검토하고 commit 또는 별도 브랜치로 보존한다. §4.1이 이를 다룬다 |

## 3. 산출물

| 산출물 | 경로 | 종류 |
|---|---|---|
| baseline tag (pin 불가) | 중앙 kit `refs/tags/baseline/pre-integrity-<date>` | git ref |
| **release tag (pin 대상)** | 중앙 kit `refs/tags/v0.4.0` | git ref |
| release 빌드 태스크 | `Rakefile`의 `release:build`, `release:verify` | 신규 |
| digest 계산 모듈 | `engine/release/release_digest.rb` + `installer/lib/release_digest.rb` 호환 wrapper | 신규 |
| dirty snapshot 모듈 | `engine/release/dirty_snapshot.rb` + `installer/lib/dirty_snapshot.rb` 호환 wrapper | 신규 |
| release manifest 생성기 | `engine/release/release_manifest.rb` + `installer/release_manifest.rb` CLI | 신규 |
| release artifact | `$HOME/orca/releases/ai-agentic-workflow-kit-0.4.0.tar.gz` + `.sha256` + `.manifest.json`(sidecar) | 저장소 밖 |
| 수정된 상태 판정 | `installer/status.rb` | 수정 |
| 수정된 plan/apply | `installer/bootstrap_project.rb` | 수정 |
| 수정된 upgrade 진입점 | `installer/upgrade.rb` | 수정 |
| 수정된 검증기 | `installer/validate_install.rb` | 수정 |
| 신규 회귀 테스트 | `test/release_digest_test.rb`, `test/plan_binding_test.rb`, `test/ownership_policy_test.rb`, `test/source_gate_test.rb`, `test/dirty_snapshot_test.rb` | 신규 |
| 기존 테스트 갱신 | `test/installer_test.rb`, `test/upgrade_test.rb` | 수정 |
| Phase 1 완료 보고 | 이 계획 저장소 `evidence/phase1/COMPLETION.md` | project-owned |

## 4. 실행 절차

작업 항목 순서는 임의가 아니다. 두 가지 제약이 순서를 결정한다.

- **tag가 없으면 release 생성 경로를 시험할 수 없다.** 따라서 baseline tag를 먼저 만든다.
- **`kit_bundle_digest`는 tag의 tree에서 계산된다**([`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §3.1).
  그러므로 무결성 코드를 구현하기 전에 만든 tag의 release에는 수정 전 installer가 담긴다.
  그 release는 프로젝트가 pin해서는 안 된다. **pin 대상 release tag는 P0 구현과 테스트가
  끝난 뒤에 새로 만든다.**

```text
P1-1 baseline tag (channel=bootstrap, pinnable=false)
  └→ P1-2 release build와 kit_bundle_digest
        └→ P1-3 rendered_install_digest와 상태 판정 (P0-02, P0-03)
              └→ P1-4 plan/apply binding (P0-04)
                    └→ P1-5 dirty/untagged apply 차단 (P0-01)
                          └→ P1-6 ownership 4분류와 tombstone (P0-05)
                                └→ P1-7 최종 release tag (pinnable=true) + 회귀 테스트 확정
```

baseline tag와 release tag의 차이는 SPEC §7.2에 정의되어 있다.

### 4.1 P1-1. baseline tag

현재 tag 목록을 확인하고 bootstrap이 필요한지 판정한다.

1. `[read-only]` 현재 dirty 파일의 내용을 확인하고, baseline에 포함할 변경인지 판정한다.
2. `[mutating: 중앙 kit]` 포함할 변경은 작업 브랜치에 commit 한다. 포함하지 않을 변경은
   별도 브랜치로 분리한다. `git clean`은 사용하지 않는다.
3. `[mutating: 중앙 kit]` annotated baseline tag를 만든다.
   이름은 `baseline/pre-integrity-<date>`다. `VERSION`은 아직 올리지 않는다.
4. `[read-only]` baseline tag의 tree에 symlink(`120000`)나 submodule(`160000`)이 없음을
   확인한다. 있으면 release 생성이 종료 코드 3으로 거부된다(SPEC §3.2).
5. `[additive]` 이 tag에서 만든 release manifest는 `channel: "bootstrap"`,
   `pinnable: false`를 갖는다. **어떤 프로젝트 lock도 이 digest를 pin할 수 없다**
   (SPEC §6.1-6). baseline은 release 생성 경로와 fixture 검증에만 쓴다.

이 단계는 release **생성** 경로만 사용하고 어떤 프로젝트에도 apply하지 않는다.
`kit_bundle_digest`는 tag의 tree에서 계산되므로 working tree가 dirty해도 결정론적이다.

### 4.2 P1-2. release build와 `kit_bundle_digest`

6. `[additive]` `engine/release/release_digest.rb`와 얇은
   `installer/lib/release_digest.rb` wrapper를 만든다. SPEC §3.2의 **Ruby 규범 구현**을
   그대로 구현한다. shell 파이프라인 변형을 쓰지 않는다. 이유는 SPEC §3.2.1에 있다.
   요건: `git ls-tree -r -z`로 NUL 구분 읽기, 경로 바이트열 기준 정렬,
   비일반 항목에서 부분 결과 없이 종료 코드 3, Ruby 2.6 호환.
7. `[additive]` 같은 모듈에 부속 digest를 구현한다(SPEC §3.5):
   `template_tree_digest`(`core/project-template/**`), `engine_digest`(`installer/**`),
   `test_tree_digest`(`test/**`).
7a. `[additive]` `engine/release/dirty_snapshot.rb`와 얇은
    `installer/lib/dirty_snapshot.rb` wrapper를 만든다. SPEC §8.4의
    `dirty_snapshot_algo: 4`를 구현한다. `git status --porcelain=v1 -z`를 NUL 구분으로 읽고
    worktree entry type, regular file byte, symlink target byte, staged blob을 분리해 digest한다.
    symlink는 따라가지 않고 `readlink`의 raw byte를 해시한다. porcelain 문자열만 해시하지 않는다.
    기존 Phase 0 algo 3 checkpoint 호환은 Phase 0 verifier가 소유하며, 중앙 kit의 새
    release/plan은 algo 4만 출력한다.
    Phase 0 구현을 runtime에 import하지는 않지만, 이 계획 저장소의
    `test/dirty_snapshot_test.rb`와 같은 conformance case를 중앙 kit에서도 통과해야 한다.
8. `[additive]` `engine/release/release_manifest.rb`와 `installer/release_manifest.rb` CLI를
   만들어 SPEC §5 스키마의
   sidecar manifest(`<name>.manifest.json`)를 생성한다. manifest는 tarball 안이 아니라
   **옆에** 둔다. `channel`과 `pinnable`을 반드시 채운다.
9. `[mutating: 중앙 kit]` `Rakefile`에 태스크를 추가한다.
   - `release:build[ref]` — tarball, `.sha256`, sidecar manifest 생성
   - `release:verify[ref]` — tarball을 임시 디렉터리에 풀어 제외 목록 적용 후
     `kit_bundle_digest`를 재계산해 manifest 값과 비교
10. `[additive]` `test/release_digest_test.rb`와 `test/dirty_snapshot_test.rb`를 만든다.
    최소 테스트:
    - 같은 ref에서 2회 계산 시 동일 (SPEC VR-1)
    - working tree를 dirty하게 만든 뒤에도 동일 (VR-2)
    - 다른 디렉터리로 clone 후에도 동일 (VR-3)
    - tarball 왕복 후에도 동일 (VR-4)
    - **negative**: tree에 symlink가 있으면 종료 코드 3이고 **stdout에 digest가 없다**
      (부분 결과 금지. SPEC S-06, VR-10)
    - **negative**: 경로 순서와 digest 순서가 어긋나는 두 파일에서 경로 정렬 결과와 일치 (VR-11)
    - **negative**: 개행이 포함된 경로에서도 정상 계산 (VR-16)
    - **negative**: 같은 파일을 서로 다른 내용으로 두 번 수정하면
      `dirty_snapshot_digest`가 달라진다 (VR-14)
    - **negative**: staged와 worktree 내용이 다르면 구분해 반영한다 (VR-15)
    - **negative**: 같은 path의 symlink target만 바꾸면 digest가 달라지고 stdout에는 target이 없다
    - **negative**: 빈 regular file과 symlink는 entry type 때문에 같은 digest가 될 수 없다
    - **negative**: 제외 목록의 파일만 바뀌면 digest가 변하지 않고,
      제외 목록 자체가 바뀌면 `bundle_digest_algo`를 올리지 않는 한 실패

### 4.3 P1-3. `rendered_install_digest`와 상태 판정 (P0-02, P0-03)

검사해야 할 실패 사례:

- `installer/bootstrap_project.rb:234` `template_digest(plans)`는 **렌더링된 plan**에서
  계산되는데, 그 값이 plan JSON의 `source.template_digest`와 manifest의 `template_digest`
  양쪽에 쓰인다. 즉 release 정체성과 렌더링 결과가 한 필드에 뒤섞여 있다.
- `installer/status.rb`의 `classify`는 `schema_version`과 `kit_version` 문자열만 비교한다.
  digest 비교 분기가 없으므로 같은 버전의 template drift는 `current`로 판정된다
  (Acceptance #4 위반).
- `installer/status.rb`의 `source_dirty?`는 값을 계산해 출력만 하고 판정에 쓰이지 않는다.

11. `[mutating: 중앙 kit]` `bootstrap_project.rb`에서 `template_digest`를
    `rendered_install_digest`로 개칭하고 SPEC §4.2 알고리즘으로 바꾼다.
    digest 라인에 ownership을 포함하고, `project-owned`와 `generated`는 제외한다.
12. `[mutating: 중앙 kit]` plan JSON과 manifest에 `kit_bundle_digest`를 별도 필드로 추가한다.
    값은 release manifest에서 읽는다. release가 아니라 dev source로 실행 중이면
    `kit_bundle_digest`를 `null`로 두고 `provenance.bootstrap_exception`을 채운다.
13. `[mutating: 중앙 kit]` 결정론 요건(SPEC §4.3)을 만족시킨다. `installed_at`,
    `updated_at`, `workspace_root`는 manifest에 남기되 `rendered_install_digest`
    계산에서 제외하고, 제외 필드 목록을 manifest에 명시한다.
    현재 `manifest["workspace_root"] = target_root`는 절대 경로이므로 digest에서 반드시 제외한다.
14. `[mutating: 중앙 kit]` `status.rb`의 `classify`를 계획 문서 §5 P0-02대로 확장한다.
    아래 중 하나라도 불일치하면 `current`가 아니다.

| 비교 항목 | 출처 |
|---|---|
| exact `kit_version` | manifest ↔ release manifest |
| `schema_version` | manifest ↔ `MANIFEST_SCHEMA_VERSION` |
| `kit_bundle_digest` | manifest ↔ release manifest |
| `rendered_install_digest` | manifest ↔ 지금 계산한 값 |
| managed file digest | manifest `installed_files[].sha256` ↔ 디스크 실제 값 |
| plan counts | `create` / `update` / `delete` / `conflict` 중 0이 아닌 것이 있으면 `upgrade_available` 이상 |
| active lock/stream | `activity.active_streams`, `activity.lock_paths`가 비어 있지 않으면 `blocked` |

15. `[mutating: 중앙 kit]` digest를 계산할 수 없거나 release manifest를 찾을 수 없으면
    `current`가 아니라 `blocked`로 판정한다(SPEC S-05).
16. `[additive]` 상태 판정 negative 테스트를 `test/upgrade_test.rb`에 추가한다.
    - **negative**: `kit_version`은 같고 `core/project-template/**`의 한 파일만 바꾼 뒤
      `status.rb --json`이 `current`를 반환하면 실패. `upgrade_available`이어야 한다
      (Acceptance #4)
    - **negative**: 설치된 kit-owned 파일 1바이트를 바꾼 뒤 `current`면 실패
    - **negative**: release manifest가 없는 상태에서 `current`면 실패(`blocked`여야 한다)

### 4.4 P1-4. plan/apply binding (P0-04)

검사해야 할 실패 사례:

- `bootstrap_project.rb`의 `OptionParser`에는 `--plan-digest`가 없다.
  `status.rb`의 `bootstrap_plan`은 `--dry-run --json`을 자식 프로세스로 호출할 뿐이다.
- `plan_payload`는 `current_sha256`와 `desired_sha256`만 내보낸다. `expected` 값이 없다.
  다만 `previous_entry`가 manifest의 `template_sha256` / `baseline_sha256`를 읽을 수 있으므로
  자료는 이미 존재한다.

17. `[mutating: 중앙 kit]` `plan_payload`에 SPEC §8.2의 필드를 추가한다.
    파일별로 `expected_digest`(= 이전 manifest의 `template_sha256`)를 노출하고,
    `action`을 `create` / `update` / `delete` / `skip` / `conflict`로 정규화한다.
18. `[mutating: 중앙 kit]` `repository_fingerprint`(SPEC §8.3)를 계산해 plan에 넣는다.
    `worktree_path`와 `branch`도 함께 넣어 linked worktree와 브랜치를 구분한다.
    `sample-worker`과 `sample-worker-preview`가 같은 fingerprint에 다른
    `worktree_path`를 갖는 실제 사례다([`INVENTORY`](../INVENTORY_TEMPLATE.md) §4.2(a)).
19. `[mutating: 중앙 kit]` `dirty_snapshot_digest`를 SPEC §8.4의 `dirty_snapshot_algo: 4`로
    계산해 plan에 넣고, `dirty_snapshot_scope`를 함께 기록한다. scope는 해소된
    D-NEED-12 해소 결정대로 **정확한 plan 대상 경로 ∪ 하네스 allowlist**다. Phase 0 checkpoint는
    복원 검증을 위해 전체 scope를 쓰므로 범위가 같다고 가정하지 않고, 알고리즘과
    conformance vector만 공유한다([`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §4.5).
20. `[mutating: 중앙 kit]` SPEC §8.5 정규화 직렬화로 `plan_digest`를 계산해 plan JSON에 넣고,
    `digest_excluded_fields`를 명시한다.
21. `[mutating: 중앙 kit]` `--plan-digest <value>` 옵션을 추가한다. 값이 주어지면
    SPEC §8.6의 5단계 재검증을 수행하고, 하나라도 불일치하면 파일을 건너뛰지 않고
    **apply 전체를 중단**한다. 3단계가 `worktree_path`와 `branch`를 비교하므로
    plan과 apply는 같은 worktree의 같은 브랜치에서 수행해야 한다.
22. `[mutating: 중앙 kit]` `--plan-digest` 없이 실행하는 apply는 dev 경로로만 허용하고,
    production 경로에서는 필수로 만든다. `upgrade.rb`가 plan → apply를 이 옵션으로 잇는다.
23. `[additive]` `test/plan_binding_test.rb`를 만든다.
    - 같은 fixture에 2회 plan 시 `plan_digest` 동일 (SPEC VR-6)
    - **negative**: plan 후 대상 파일 1개를 수정하고 apply → 중단 (VR-7)
    - **negative**: plan 후 source release를 다른 digest로 교체하고 apply → 중단 (VR-8)
    - **negative**: plan 후 `git commit`으로 HEAD를 바꾸고 apply → 중단
    - **negative**: plan 후 untracked 파일 1개를 추가해 `dirty_snapshot_digest`를 바꾸고
      apply → 중단
    - **negative**: **plan을 만든 worktree와 다른 worktree에서 apply → 중단**
      (`worktree_path` 불일치. Phase 3 절차의 근거)
    - **negative**: 같은 worktree에서 브랜치만 바꿔 apply → 중단
    - **negative**: `plan_digest`를 한 글자 바꿔 전달 → 중단

### 4.5 P1-5. dirty/untagged apply 차단 (P0-01)

24. `[mutating: 중앙 kit]` production apply 경로에서 SPEC §6.1 resolver 요건 7단계를
    구현한다. 특히 다음 두 가지를 지킨다.
    - 가져온 내용으로 `kit_bundle_digest`를 **재계산**해 **lock 값과** 비교한다.
      manifest의 값과만 비교하지 않는다. 그러지 않으면 manifest와 tarball을 함께 바꾼
      공격이 통과한다(SPEC §6.1-4, §6.1-5).
    - `pinnable`이 `false`인 release는 거부한다. baseline tag가 이 경우다(SPEC §7.2).
25. `[mutating: 중앙 kit]` working tree를 source로 하는 apply는 기본 거부한다.
    `status.rb`가 이미 계산하는 `source_dirty?`를 판정에 연결한다.
26. `[mutating: 중앙 kit]` `--dev-source` 예외를 SPEC §7.3 조건 전부와 함께 구현한다.
    target이 `fixtures/**` 밖이면 거부한다. `installation_state`는 `dev_unmanaged`로 쓴다.
27. `[additive]` `test/source_gate_test.rb`를 만든다.
    - **negative**: dirty working tree를 source로 임시 프로젝트에 apply → 거부
    - **negative**: tag가 없는 commit을 source로 release 생성 시도 → 거부
    - **negative**: `--dev-source`로 `fixtures/**` 밖 경로에 apply → 거부
    - **negative**: release manifest의 `kit_bundle_digest`를 위조해 apply → 거부
    - positive: 정상 release로 fixture에 apply → 성공하고 manifest에
      `installation_state: managed`가 기록된다

### 4.6 P1-6. ownership 4분류와 tombstone (P0-05)

검사해야 할 실패 사례:

- `bootstrap_project.rb:282` `file_ownership`은 두 값만 반환한다.
  `AGENTS.md`와 `.ai/canonical/**`는 `"project"`, **그 밖의 모든 경로는 `"kit"`**이다.
  따라서 `.ai/tasks/**`, `.ai/project/**`, `.ai/local/**`가 모두 `kit`으로 분류된다.
  계획 문서 §8의 4분류와 Acceptance #6(`.ai/tasks/**`는 삭제 대상이 아니다)을
  코드가 표현하지 못한다.
- `merge-owned`와 `generated` 개념이 없다. `AGENTS.md`는 해소된 D-NEED-14 결정에서
  **`merge-owned` + `approval_required_paths`로 확정되었으나** 현재 코드는 `project`를 반환한다.
  헌장 §8의 예시 목록도 이번에 함께 정정되었다.
- `--replace-project-owned` 옵션이 존재하며 `--force`와 함께 쓰면
  project-owned 파일을 교체한다(`bootstrap_project.rb:345`, `:405`, `:422`, `:429`).
  기존 테스트 `test/installer_test.rb:155`, `:180`이 이 경로를 사용한다.
- `delete` 액션과 tombstone 개념이 아직 없다. 현재 status 값은
  `create` / `update` / `replace` / `preserve` / `unchanged` / `conflict`다.

28. `[mutating: 중앙 kit]` `file_ownership`을 release manifest의 `ownership_rules`
    (SPEC §5)로 대체한다. 4분류를 반환하고, 가장 구체적인 glob이 이긴다.
    구체성이 같고 결과가 다르면 fail-closed 한다.
29. `[mutating: 중앙 kit]` `.ai/tasks/**`, `.ai/canonical/**`, `.ai/local/**`를
    `protected_paths`로 고정한다. 이 경로들은 `delete` 액션을 가질 수 없다.
30. `[mutating: 중앙 kit]` `delete` 액션과 tombstone 검증을 구현한다.
    삭제는 release manifest의 `tombstones`에 항목이 있고, `expected_digest`가
    디스크 현재 값과 일치하고, 사람 승인이 plan의 `protected_path_approvals`에
    기록된 경우에만 수행한다. 세 조건 중 하나라도 없으면 삭제하지 않는다.
31. `[mutating: 중앙 kit]` `--replace-project-owned`를 다음으로 대체한다.
    경로별 승인 목록(`--approve-path <path>=<expected_sha256>`)만 허용하고,
    승인 목록에 없는 project-owned 파일은 어떤 플래그로도 변경되지 않게 한다.
    fleet 경로에서는 이 옵션 자체를 금지한다(계획 문서 §5 P0-05).
31a. `[mutating: 중앙 kit]` manifest의 `approval_required_paths`(SPEC §5)를 구현한다.
     `AGENTS.md`는 `merge-owned`이지만 이 목록에 있으므로 구조화 merge 결과를 적용할 때도
     `--approve-path` 승인이 필요하다. 승인이 없으면 `conflict`로 남기고 변경하지 않는다.
     이로써 소유권을 `merge-owned`로 바꾸면서도 Acceptance #5의 보호 수준을 유지한다.
32. `[mutating: 중앙 kit]` `test/installer_test.rb:155`, `:180`의 기존 기대값을
    새 정책으로 갱신한다. 기존 동작을 보존하지 않는다. 이 변경은 의도된 breaking change이며
    `CHANGELOG.md`에 기록한다. `AGENTS.md` 소유권이 `project` → `merge-owned`로
    바뀌는 것도 같은 항목에 기록한다.
33. `[additive]` `test/ownership_policy_test.rb`를 만든다.
    - **negative**: `.ai/canonical/**` 파일이 수정된 상태로 apply → 그 파일은
      한 바이트도 변하지 않는다(before/after SHA-256 동일). Acceptance #5
    - **negative**: `.ai/tasks/**`에 사용자 파일을 두고 apply/upgrade → 삭제되지 않는다.
      Acceptance #6
    - **negative**: release manifest에 tombstone이 없는 상태에서 kit-owned 파일 삭제 시도 → 거부
    - **negative**: tombstone은 있지만 `expected_digest`가 디스크와 다르면 → 거부
    - **negative**: 승인 없이 project-owned 파일 교체 시도 → 거부
    - **negative**: **승인 없이 `AGENTS.md` merge 결과 적용 시도 → `conflict`, 파일 불변**
    - **negative**: ownership 규칙 두 개가 같은 구체성으로 충돌 → `blocked`
    - positive: 승인된 경로 1개만 교체되고 다른 project-owned 파일은 불변

### 4.7 P1-7. 최종 release tag와 회귀 테스트 확정

여기서 만드는 tag가 **프로젝트가 pin하는 유일한 대상**이다. baseline tag는 이 시점 이후
release 생성 경로 시험 기록으로만 남는다.

34. `[read-only]` 전체 테스트를 실행한다. `rake` 기본 태스크는
    `syntax` → `workflow_yaml` → `test` → `security` 순으로 돈다.
    전부 통과하지 않으면 release tag를 만들지 않는다.
35. `[mutating: 중앙 kit]` `VERSION`을 `0.4.0`으로 갱신하고 `CHANGELOG.md`에 항목을
    추가한다(해소된 D-NEED-07). P0-01 ~ P0-05, ownership 4분류, `AGENTS.md` 소유권 변경,
    `--replace-project-owned` 제거를 breaking change로 기록한다.
36. `[mutating: 중앙 kit]` annotated release tag `v0.4.0`을 만든다.
    lightweight tag는 쓰지 않는다. tag가 가리키는 commit의 `VERSION`이 tag 이름과 일치해야 한다.
37. `[read-only]` release tag가 SPEC §7.2의 요건을 만족하는지 확인한다.
    - `git show <tag>:engine/release/release_digest.rb`가 성공한다(P0 구현이 tree에 있다)
    - `engine_digest`가 baseline tag의 값과 **다르다**
    - manifest의 `channel`이 `candidate` 또는 `stable`이고 `pinnable`이 `true`다
38. `[read-only]` release tag에서 만든 release로 fixture apply와 전체 회귀 테스트를 다시 통과한다.
    baseline release로 통과한 것은 이 요건을 대신하지 않는다.
39. `[additive]` 이 계획 저장소에 `evidence/phase1/COMPLETION.md`를 쓴다.
    포함 항목: 확정된 버전 번호, **baseline tag와 release tag 두 이름과 commit**,
    두 tag의 `kit_bundle_digest`와 `engine_digest`(서로 달라야 한다),
    부속 digest 3종, sidecar manifest의 SHA-256, 테스트 실행 로그 요약,
    §4.6-32에서 변경한 기존 테스트 목록.
40. `[additive]` [`PHASE_0`](PHASE_0_FREEZE_AND_INVENTORY.md) §4.1의
    `evidence/FREEZE_NOTICE.md`에 해제 조건 충족 사실을 추가 기록한다.
    동결 자체는 Phase 3의 첫 프로젝트 apply 승인 시점에 해제한다.

## 5. 검증 명령

검증은 승인된 격리 중앙 kit worktree에서 실행한다. 기존 dirty 중앙
checkout에서 이 명령을 실행하지 않는다.
`$BASE`는 baseline tag, `$REL`은 확정 release tag `v0.4.0`을 뜻한다.

| # | 명령 | 기대 결과 |
|---|---|---|
| V1-1 | `git tag --list \| wc -l` | 2 이상. baseline tag와 release tag가 모두 있다 |
| V1-2 | `git cat-file -t "$(git rev-parse $REL)"` 및 `... $BASE` | 둘 다 `tag`. `commit`이면 lightweight이므로 실패 |
| V1-3 | `git show "$REL:VERSION"` | release tag 이름과 일치하는 버전 문자열 |
| V1-3a | `git show "$REL:engine/release/release_digest.rb" \| head -1` | 성공. release tag tree에 P0 구현이 있다 |
| V1-3b | `$BASE`와 `$REL`의 `engine_digest` 비교 | **두 값이 달라야 한다.** 같으면 무결성 코드가 release에 없다 |
| V1-3c | `$BASE`의 manifest에서 `channel`, `pinnable` 확인 | `bootstrap`, `false` |
| V1-3d | `$REL`의 manifest에서 `channel`, `pinnable` 확인 | `candidate` 또는 `stable`, `true` |
| V1-4 | `rake release:build[$REL]` 2회 실행 후 두 manifest의 `kit_bundle_digest` 비교 | 두 값 동일 (SPEC VR-1) |
| V1-5 | 아무 파일을 수정해 dirty로 만든 뒤 `rake release:build[$REL]` | `kit_bundle_digest`가 V1-4와 동일 (VR-2) |
| V1-6 | `rake release:verify[$REL]` | exit 0. tarball 왕복 후 digest 일치 (VR-4) |
| V1-6a | release 산출물 3종 존재 확인 | `.tar.gz`, `.tar.gz.sha256`, `.manifest.json`. manifest는 tarball 밖 sidecar다 |
| V1-7 | `ruby -Itest test/release_digest_test.rb` | 전부 pass |
| V1-7a | `ruby -Itest test/dirty_snapshot_test.rb` | 전부 pass (VR-14 ~ VR-16) |
| V1-7b | symlink 포함 tree로 `release:build` 실행 후 `echo $?`와 stdout | exit 3이고 **stdout에 digest가 없다**(부분 결과 금지. SPEC S-06) |
| V1-8 | `ruby -Itest test/plan_binding_test.rb` | 전부 pass |
| V1-9 | `ruby -Itest test/source_gate_test.rb` | 전부 pass |
| V1-10 | `ruby -Itest test/ownership_policy_test.rb` | 전부 pass |
| V1-11 | `ruby -Itest test/installer_test.rb` | 전부 pass (§4.6-32의 갱신 반영) |
| V1-12 | `ruby -Itest test/upgrade_test.rb` | 전부 pass |
| V1-13 | `rake` | 전체 pass. `syntax`, `workflow_yaml`, `test`, `security` 모두 |
| V1-14 | `ruby installer/status.rb --json <fixture>` 후 `template_drift` 시나리오 | `state`가 `current`가 아니다 |
| V1-15 | `grep -rn 'replace-project-owned' installer/` | 출력 없음 또는 fleet 금지 가드와 함께만 등장 |
| V1-16 | `grep -c 'kit_bundle_digest' installer/*.rb installer/lib/*.rb` | 1 이상  |
| V1-17 | `ruby installer/bootstrap_project.rb --help` | `--plan-digest`, `--dev-source`, `--approve-path`가 목록에 있다 |
| V1-18 | dirty working tree를 source로 임시 프로젝트에 apply | 0이 아닌 exit code로 거부 |
| V1-19 | `$BASE`의 digest를 lock에 pin해 fixture apply | 거부(`pinnable: false`. SPEC VR-13) |
| V1-20 | manifest와 tarball을 함께 교체해 apply | 거부. lock의 `kit_bundle_digest`와 불일치 (SPEC VR-12) |
| V1-21 | `grep -rnE 'ls-tree -r [^z-]' engine/release/release_digest.rb` | 출력 없음. NUL 구분(`-z`)을 쓴다 |
| V1-22 | 승인 없이 `AGENTS.md` merge 결과 적용 시도 | `conflict`로 남고 파일이 변하지 않는다 |

## 6. 종료조건

| # | 종료조건 | 검증 | 계획 문서 대응 |
|---|---|---|---|
| G1-1 | baseline tag와 release tag가 모두 annotated이고 release tag의 `VERSION`이 일치한다 | V1-1, V1-2, V1-3 | §5 전제 |
| G1-1a | **release tag의 tree에 P0 구현이 포함되어 있고 `engine_digest`가 baseline과 다르다** | V1-3a, V1-3b | [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §7.2 |
| G1-1b | baseline release는 `pinnable: false`이고 pin 시도가 거부된다 | V1-3c, V1-19 | SPEC §6.1-6 |
| G1-1c | release release는 `pinnable: true`이고 fixture apply와 전체 회귀를 통과했다 | V1-3d, V1-13 | SPEC §7.2 |
| G1-2 | clean tag에서만 stable release가 생성된다 | V1-6, V1-9 | §11 Phase 1 종료조건 |
| G1-2a | release 산출물이 tarball + checksum + **sidecar manifest** 3종으로 생성된다 | V1-6a | SPEC §5 |
| G1-3 | `kit_bundle_digest`가 재현 가능하고 working tree 상태와 무관하다 | V1-4, V1-5, V1-7 | P0-03 |
| G1-3a | 규범 구현이 NUL-safe이고 거부 시 부분 결과를 내보내지 않는다 | V1-7b, V1-21 | SPEC S-06, §3.2.1 |
| G1-3b | `dirty_snapshot_digest`가 내용 변화를 감지한다 | V1-7a | SPEC §8.4 |
| G1-4 | `kit_bundle_digest`와 `rendered_install_digest`가 분리되었다 | V1-16, V1-7 | P0-03 |
| G1-5 | 같은 version의 template drift가 `current`로 판정되지 않는다 | V1-14, V1-12 | Acceptance #4 |
| G1-6 | digest 계산 불가 또는 release manifest 부재 시 `blocked`로 판정한다 | V1-12 | SPEC S-05 |
| G1-7 | plan과 apply가 `plan_digest`로 결속되고, 불일치 시 전체 중단한다 | V1-8, V1-17 | P0-04 |
| G1-8 | dirty 또는 untagged source에서 apply가 실패한다 | V1-9, V1-18 | Acceptance #3 |
| G1-9 | `--dev-source`가 `fixtures/**` 밖에서 거부된다 | V1-9 | SPEC §7.3 |
| G1-10 | project-owned 파일이 승인 없이 한 바이트도 변경·삭제되지 않는다 | V1-10 | Acceptance #5 |
| G1-11 | `.ai/tasks/**`가 upgrade 삭제 대상이 아니다 | V1-10 | Acceptance #6 |
| G1-12 | ownership이 4분류로 판정되고 충돌 시 fail-closed 한다 | V1-10 | 계획 문서 §8 |
| G1-13 | tombstone 3조건(manifest 항목 + expected digest + 사람 승인) 없이는 삭제되지 않는다 | V1-10 | P0-05 |
| G1-13a | `AGENTS.md`가 `merge-owned`이면서 승인 없이는 변경되지 않는다 | V1-22 | 해소된 D-NEED-14, SPEC §5 |
| G1-14 | 자동 전체 교체 옵션이 fleet 경로에서 제거되었다 | V1-15 | P0-05 |
| G1-14a | manifest와 tarball 동시 교체 공격이 거부된다 | V1-20 | SPEC §6.1-5 |
| G1-15 | `rake` 전체가 통과한다 | V1-13 | 회귀 없음 |
| G1-16 | 완료 증거가 두 tag의 digest를 포함해 기록되었다 | `evidence/phase1/COMPLETION.md` | §4.7 |

## 7. 롤백

이 phase는 중앙 kit을 수정하므로 Phase 0과 달리 되돌릴 대상이 있다.

| 단계 | 되돌리는 방법 | 되돌릴 수 없는 부분 |
|---|---|---|
| P1-1 baseline tag 생성 | `git tag -d baseline/pre-integrity-<date>`. 원격에 push하지 않았다면 로컬 삭제로 충분하다 | 없음 |
| P1-7 release tag 생성 | `git tag -d v0.4.0`. 마찬가지 | 없음 |
| P1-1 commit | 작업 브랜치에서 `git revert`. `reset --hard`는 사용하지 않는다 | 없음 |
| P1-2 ~ P1-6 코드 수정 | 작업은 `<existing-work-branch>`이 아닌 새 브랜치에서 수행한다. 브랜치를 버리면 원복된다 | 없음 |
| release artifact | `$HOME/orca/releases/**` 삭제 | 없음 |
| 기존 테스트 기대값 변경(§4.6-32) | 브랜치 폐기로 원복. 다만 정책 결정 자체는 문서로 남는다 | 정책 결정 |
| `evidence/phase1/**` | 이 계획 저장소에서 삭제 | 없음 |

전제: 모든 코드 변경은 **새 브랜치**에서 수행한다. 두 tag는 그 브랜치의 commit에 붙인다.
tag를 원격에 push하는 것은 이 phase의 승인 범위가 아니다.

apply 대상이 fixture뿐이므로 애플리케이션 저장소 롤백은 필요하지 않다.
만약 실수로 실제 프로젝트에 apply했다면 Phase 0의
`refs/harness-checkpoint/<ts>/<worktree_id>`와 `$CHECKPOINT_ROOT`의 untracked 아카이브로 복원한다.

## 8. 이 phase가 승인하지 않는 작업

[`HARNESS_GOVERNANCE_MIGRATION_PLAN.md`](../../HARNESS_GOVERNANCE_MIGRATION_PLAN.md) §14에서
이 phase가 해제하는 것은 **중앙 kit 저장소의 수정과 로컬 tag 생성 두 가지뿐**이다.
나머지는 그대로 금지된다. 특히 다음을 금지한다.

- 실제 프로젝트(`$WORKSPACE/projects/**`)에 대한 plan 이외의 apply·upgrade 실행
- 중앙 kit tag/브랜치의 원격 push, GitHub Release 게시, 패키지 발행
- 기존 프로젝트의 `.ai/**`, `AGENTS.md`, `.githooks`, CI 변경
- 전역 설정, `core.hooksPath`, hook 활성화 변경
- `git reset --hard`, `git clean`, `git push --force`
- Phase 0 checkpoint(`refs/harness-checkpoint/*`, `$CHECKPOINT_ROOT`)의 삭제
- nested clone 삭제 또는 fetch
- production DB 접속, live provider 호출, 배포

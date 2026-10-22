---
title: AI Harness Governance and Migration Plan
project_id: ai-harness-governance-plan
status: reference-template
last_verified_at: 'YYYY-MM-DD'
revision: 13
scope: phases-0-4-fleet-eligibility-and-canaries
owns: decisions, principles, acceptance criteria, risks, phase index
delegates: per-phase execution procedure and gates to docs/phases/PHASE_0..5
---

# AI 하네스 거버넌스 및 마이그레이션 계획

## 0. 문서 인덱스

이 문서는 헌장이다. 결정, 원칙, acceptance criteria, 위험을 소유한다.
각 phase의 실행 절차·검증 명령·종료조건·롤백은 아래 phase 문서가 소유한다.

| 문서 | 역할 |
|---|---|
| [`docs/TEMPLATE_PHASE.md`](docs/TEMPLATE_PHASE.md) | phase 문서 작성 규칙과 8개 표준 절 |
| [`docs/INVENTORY_TEMPLATE.md`](docs/INVENTORY_TEMPLATE.md) | 적용 환경에서 작성하는 인벤토리 템플릿 |
| [`docs/RELEASE_ARTIFACT_SPEC.md`](docs/RELEASE_ARTIFACT_SPEC.md) | digest 정의, 정규화 규칙, release manifest 스키마, source 추상화 |
| [`docs/phases/PHASE_0_FREEZE_AND_INVENTORY.md`](docs/phases/PHASE_0_FREEZE_AND_INVENTORY.md) | Phase 0. 동결과 인벤토리 |
| [`docs/phases/PHASE_1_RELEASE_INTEGRITY.md`](docs/phases/PHASE_1_RELEASE_INTEGRITY.md) | Phase 1. 중앙 kit release integrity |
| [`docs/phases/PHASE_2_THREE_TIER_AND_FIXTURES.md`](docs/phases/PHASE_2_THREE_TIER_AND_FIXTURES.md) | Phase 2. 3계층 구조와 합성 fixture |
| [`docs/phases/PHASE_3_CANARY_ADOPTION.md`](docs/phases/PHASE_3_CANARY_ADOPTION.md) | Phase 3. canary와 순차 adoption |
| [`docs/phases/PHASE_4_SPEC_FRESHNESS_GATE.md`](docs/phases/PHASE_4_SPEC_FRESHNESS_GATE.md) | Phase 4. 명세 최신성 required gate |
| [`docs/phases/PHASE_5_OPERATIONS_AND_RETIREMENT.md`](docs/phases/PHASE_5_OPERATIONS_AND_RETIREMENT.md) | Phase 5. 운영 자동화와 nested clone 퇴역 |

이 문서 안에서 자주 찾는 절:

- §4 적용 전 인벤토리
- §11 phase 경계와 의존 관계
- §12 Acceptance Criteria 18개, §12.1 Acceptance ↔ Phase 매핑과 해석 주석
- §14 적용 권한과 범위
- §16 적용 순서
- §17 적용 시 작성할 결정 원장

## 1. 문서 목적

이 문서는 Orca에서 운영 중인 여러 프로젝트의 `ai-agentic-workflow-kit`, Codex/Claude/Kiro 지침, Git 명세, MemSearch, Obsidian Mind를 다음 원칙으로 재구성하기 위한 실행 계획이다.

1. 공통 하네스는 한 번 개발하고 불변 릴리스로 배포한다.
2. 프로젝트별 사실과 명세는 각 Git 저장소가 소유한다.
3. 기존 프로젝트의 파일은 재설치 과정에서 자동 삭제하거나 덮어쓰지 않는다.
4. 명세 최신성은 프롬프트가 아니라 required CI와 배포 receipt에서 최종 강제한다.
5. 프로젝트 정보가 불완전하거나 서로 충돌하면 추측하지 않고 fail-closed 한다.

이 문서는 계획 명세다. 승인된 실행 결과는 phase별 `evidence/**/COMPLETION.md`에 기록하며,
계획 자체가 전역 설정, hook 활성화, provider/DB/deploy 또는 승인 범위 밖 저장소 변경을
허가하지 않는다.

## 2. 최종 결정

### D-01. 2계층이 아니라 3계층으로 분리한다

```text
Machine Global Harness
  ├─ MemSearch
  ├─ Obsidian Mind 실행기
  ├─ Orca/Codex 공통 project resolver
  └─ 설치된 공통 Skill/plugin 및 release cache
             │
             ▼
Shared Organization Harness
  ├─ ai-agentic-workflow-kit release artifact
  ├─ validator / migration / schema
  ├─ FastAPI / Next.js / PostgreSQL adapter
  ├─ CI receipt schema
  └─ Codex / Claude / Kiro adapter
             │
             ▼
Project Harness
  ├─ exact kit version/digest lock
  ├─ AGENTS.md와 project overrides
  ├─ PROJECT_MAP / ENV_MATRIX / context-map
  ├─ SPEC_REGISTRY
  ├─ canonical spec / ADR / runbook
  └─ 프로젝트 전용 tests / release gate
```

`ai-agentic-workflow-kit`은 전역 하네스 전체가 아니다. 여러 프로젝트가 공유하는 **조직 공통 하네스의 개발·릴리스 원본**이다. 실행 파일과 여러 버전의 artifact는 전역에 한 번 설치할 수 있지만, 실제로 어떤 버전을 사용할지는 각 프로젝트 lock이 결정한다.

### D-02. 프로젝트 상세 정보는 전역에 복사하지 않는다

전역 설정에는 다음을 넣지 않는다.

- 프로젝트 절대경로를 전제로 한 DB 연결 정보
- 실제 secret 값
- 프로젝트별 테이블·API·함수 목록의 수기 복사본
- 프로젝트별 배포 완료 여부
- 여러 저장소의 canonical spec을 합친 거대한 `AGENTS.md`

전역/공통 하네스는 프로젝트 정보를 **어떻게 찾고 검증할지**만 안다. 실제 DB, API, 함수, 운영 환경 정보는 현재 Git root의 project harness에서 읽는다.

### D-03. 기존 설치는 삭제 후 재설치하지 않는다

기존 프로젝트는 one-time adoption을 거친다. 오래된 nested kit clone은 baseline 복원에 사용한 뒤, adoption 검증이 끝난 프로젝트에서만 별도 PR로 제거한다.

### D-04. 최종 강제점은 PR/CI와 배포 경계다

- 전역 `AGENTS.md`: 보편 행동 원칙과 project resolver 안내
- 프로젝트 `AGENTS.md`: 프로젝트 진입점과 금지사항
- 로컬 hook: 빠른 피드백
- required CI: merge 차단
- deploy gate: 검증된 exact SHA가 아니면 배포 차단

### D-05. 기억 계층은 canonical truth가 아니다

MemSearch와 Obsidian Mind는 과거 결정과 작업 맥락을 찾는 보조 계층이다. 기억과 현재 Git 명세 또는 생성된 사실이 충돌하면 현재 Git과 validator 결과가 우선한다.

## 3. 질문에 대한 확정 답변

### 질문 1. `ai-agentic-workflow-kit` 프로젝트만 수정하는가?

아니다. 실제 구현 시 변경 대상은 세 종류이지만, 변경 방식은 서로 다르다.

| 대상 | 필요한 변경 | 변경 성격 |
|---|---|---|
| `ai-agentic-workflow-kit` | installer, status, digest, ownership, validator, migration, immutable release | 중앙에서 한 번 개발 |
| 전역 설정 | 공통 Skill/plugin 등록, project resolver, read-only doctor | 최소한으로 한 번 설정 |
| 기존 프로젝트 | version lock, project manifest, `SPEC_REGISTRY`, CI caller, project adapter | 프로젝트별 1회 adoption PR |
| 애플리케이션 비즈니스 코드 | 원칙적으로 없음 | migration이 자동 수정해서는 안 됨 |

중앙 kit만 수정해도 이미 설치된 프로젝트가 자동으로 안전해지지는 않는다. 각 프로젝트가 새 릴리스를 명시적으로 채택하고 required CI를 연결해야 효력이 생긴다.

공통 kit 변경과 프로젝트 적용은 서로 다른 변경 범위다. 각각의 소유권과 검증 결과를 기록한다.

### 질문 2. 이미 kit를 설치하거나 적용한 프로젝트는 어떻게 하는가?

다음 순서로 프로젝트별 one-time adoption을 수행한다.

1. active stream/lock, open work, dirty 상태를 확인한다.
2. 불안정하면 해당 프로젝트는 `deferred + reason`으로 기록하고 수정하지 않는다.
3. nested kit clone SHA `<baseline-sha>`와 현재 `.ai/**`를 이용해 기존 baseline을 복원한다.
4. 파일별로 `kit-owned`, `merge-owned`, `project-owned`, `generated` 소유권을 판정한다.
5. 전체 dirty-worktree checkpoint를 남긴다.
6. 격리 maintenance worktree에서 read-only plan과 파일별 diff를 생성한다.
7. project-owned 파일은 자동 변경·삭제하지 않는다.
8. 프로젝트별 PR 하나로 manifest, runtime, validator, CI caller를 채택한다.
9. 프로젝트 test와 spec gate가 통과한 뒤 merge 여부를 별도로 결정한다.
10. baseline 복원 가능성과 adoption acceptance가 확인된 후에만 nested clone을 별도 PR로 제거한다.

각 프로젝트는 한 번에 하나씩 처리한다. 여러 저장소를 직접 일괄 덮어쓰는 fleet apply는 사용하지 않는다.

### 질문 3. `ai-agentic-workflow-kit`은 광역 하네스가 되는가?

정확히는 **Shared Organization Harness의 원본**이 된다.

- 전역에 한 번 설치할 수 있는 것: launcher, resolver, release cache, 공통 Skill/plugin
- 중앙 kit가 제공하는 것: 규칙 schema, validator, migration, framework adapter
- 프로젝트가 고르는 것: exact version, profile, protected paths, project-specific checks
- 프로젝트가 소유하는 것: DB/API/함수의 현재 사실, canonical spec, ADR, runbook

즉, `0.4.0`과 `0.4.1`을 전역 cache에 나란히 보관하고 프로젝트 A는 `0.4.0`, 프로젝트 B는 `0.4.1`을 pin할 수 있다. 업데이트는 중앙 파일 복사가 아니라 프로젝트 lock을 바꾸는 PR로 수행한다.

## 4. 적용 전 인벤토리

공개 배포본에는 실제 조직의 프로젝트 목록이나 작업 상태를 포함하지 않는다.
[인벤토리 템플릿](docs/INVENTORY_TEMPLATE.md)을 복사해 대상 저장소에서 현재 상태를 수집한다.
실측 결과와 checkpoint는 비공개 위치에 보관한다. 이전 실행의 성공이나 승인 기록을
새 프로젝트의 실행 권한으로 사용하지 않는다.

각 저장소는 `migrated`, `deferred + reason`, `excluded` 중 하나로 분류한다.
branch, dirty scope, active work, lock, remote 및 설치 버전은 실행 직전에 다시 확인한다.

## 5. 중앙 kit의 필수 요구사항

현재 중앙 checkout으로 fleet apply를 실행하지 않는다.

선행 수정의 확정 버전은 `0.4.0`이다(D-NEED-07 해소).

### P0-01. dirty/untagged source 차단

- release artifact가 아닌 working tree에서 production apply를 기본 거부한다.
- 개발용 예외는 명시적 flag와 비운영 fixture에서만 허용한다.
- `VERSION`, tag, release manifest, artifact digest가 일치해야 한다.

### P0-02. 상태 판정 수정

다음 중 하나라도 다르면 `current`가 아니라 `upgrade_available` 또는 `blocked`다.

- exact version
- schema version
- `kit_bundle_digest`
- `rendered_install_digest`
- managed file digest
- plan의 `create/update/delete/conflict`
- active lock/stream

### P0-03. digest 분리

- `kit_bundle_digest`: 프로젝트와 날짜에 무관한 불변 release artifact digest
- `rendered_install_digest`: 프로젝트별 렌더링 결과 digest

### P0-04. plan과 apply 결합

plan에 다음을 포함하고 `apply --plan-digest`에서 다시 검증한다.

- source artifact digest
- target repository fingerprint와 HEAD
- dirty snapshot digest
- 파일별 current/expected/desired digest
- 소유권과 선택된 action
- protected path 승인

source 또는 target이 plan 이후 변하면 apply를 중단한다.

### P0-05. 안전한 삭제 정책

- project-owned와 `.ai/tasks/**`에는 tombstone을 적용하지 않는다.
- kit-owned 파일도 release에 명시된 tombstone, expected current digest, 사람 승인 없이는 삭제하지 않는다.
- 자동 전체 교체 옵션은 fleet 경로에서 금지한다.

## 6. 목표 파일 구조

### 중앙 kit repository

```text
ai-agentic-workflow-kit/
├─ engine/
│  ├─ validators/
│  ├─ migrations/
│  ├─ generators/
│  └─ receipts/
├─ schemas/
│  ├─ kit-installation.schema.yaml
│  ├─ spec-registry.schema.yaml
│  └─ generated-facts.schema.yaml
├─ adapters/
│  ├─ fastapi-alembic/
│  ├─ nextjs-typescript/
│  └─ postgresql/
├─ skills/
├─ vendors/
│  ├─ codex/
│  ├─ claude/
│  └─ kiro/
├─ fixtures/
└─ release-manifest.json
```

### 각 project repository

```text
project/
├─ AGENTS.md                       # 짧은 진입점
├─ .ai/
│  ├─ KIT_INSTALLATION.yaml        # exact version/digest/profile
│  ├─ runtime/**                   # kit-owned
│  ├─ project/**                   # project override
│  ├─ canonical/**                 # project-owned
│  ├─ tasks/**                     # project-owned evidence
│  ├─ SPEC_REGISTRY.yaml           # code-to-spec mapping
│  └─ generated/**                 # commit-bound generated facts
└─ .github/workflows/
   └─ agent-workflow-policy.yml    # org ruleset이 없을 때만 얇은 caller
```

## 7. 프로젝트 정보를 정확히 인식하는 프로토콜

“오류가 절대 발생하지 않는다”를 LLM의 추론만으로 보장할 수는 없다. 대신 모르면 실행하지 않는 fail-closed 방식으로 정확성을 확보한다.

에이전트 또는 CI가 프로젝트에 진입할 때 다음 절차를 수행한다.

1. `git rev-parse --show-toplevel`로 현재 root를 확정한다.
2. repository fingerprint, project ID, remote identity를 manifest와 비교한다.
3. 프로젝트가 pin한 exact kit version과 `kit_bundle_digest`를 검증한다.
4. `AGENTS.md`는 지도 역할만 하고 `PROJECT_MAP`, `ENV_MATRIX`로 실제 service/DB/environment를 확인한다.
5. 변경 경로를 `context-map`과 `SPEC_REGISTRY`에 대입한다.
6. 필요한 canonical spec, ADR, runbook, agent profile만 선택적으로 로드한다.
7. route, DB schema, exports/symbols, 환경변수 이름을 코드로부터 생성한다.
8. generated facts의 `source_tree_digest`, generator version, `content_digest`가 현재 tree에서
   재계산한 값과 일치하는지 확인한다. commit SHA는 파일에 기록하지 않는다(§12.1 해석 주석).
9. 수기 명세, generated facts, 실제 코드가 충돌하면 관련 작업과 merge를 중단한다.
10. 통과한 code SHA, spec digest, kit digest를 receipt로 고정한다.

### 프로젝트 간 context 혼입 방지

- resolver는 세션 시작과 Git root 변경 때 project context를 다시 초기화한다.
- memory 검색에는 project ID/collection scope를 붙인다.
- 다른 프로젝트에서 가져온 절대경로와 DB 식별자는 현재 project manifest가 허용하지 않으면 거부한다.
- 두 프로젝트를 연속으로 열어도 이전 프로젝트의 DB/API/배포 규칙이 남지 않는 negative test를 둔다.

### 함수 정보 관리 원칙

모든 함수 이름을 Markdown에 수기로 나열하지 않는다. 이는 빠르게 outdated 된다.

| 사실 | 생성 방식 | 사람이 쓰는 명세의 역할 |
|---|---|---|
| FastAPI route | decorator/OpenAPI inventory | API의 의미, 권한, 실패 계약 |
| Next.js route | `route.ts`와 HTTP method export inventory | 공개/관리자 경계와 비즈니스 계약 |
| Python symbol/import | AST 기반 index | 핵심 service/port의 책임 설명 |
| TypeScript export/module | TypeScript compiler API 기반 index | 모듈 경계와 허용 dependency |
| DB schema | migration checksum + disposable DB introspection | 데이터 불변조건, PII, 복구 정책 |
| 환경변수 | 설정 schema와 실제 참조 이름 수집 | 환경별 source와 금지 정책 |
| 배포 입력 | Compose/runtime manifest digest | 승인·rollback·운영 경계 |

generated fact에는 최소한 `source_tree_digest`, `generator_version`, `generated_at`, `content_digest`를 기록한다. `source_commit`은 gate 입력이 아니며, 필요하면 `source_commit_hint`로 비검사 참고값만 둔다(§12.1 해석 주석). secret 값과 실제 운영 credential은 수집하지 않는다.

## 8. 소유권 모델

| 소유권 | 예시 | upgrade 동작 |
|---|---|---|
| `kit-owned` | validator runtime, 공통 schema, `.ai/runtime/agents/base/**` | expected digest가 일치할 때 업데이트 가능 |
| `merge-owned` | 공통 agent base + project override, **`AGENTS.md`** | 구조화된 merge 후 명시적 diff 검토. `approval_required_paths`에 있으면 경로별 승인 필요 |
| `project-owned` | canonical spec, ADR, runbook, task evidence, `.ai/project/**` | 자동 덮어쓰기·삭제 금지 |
| `generated` | route/schema/symbol inventory | 현재 코드에서 재생성하고 digest 비교 |

`AGENTS.md`의 소유권은 해소된 D-NEED-14 결정에서 **`merge-owned`로 확정**되었다. kit이 템플릿을
배포하므로 갱신 경로가 필요하고, 아래 설명대로 두 계층을 가리키는 adapter이기 때문이다.
다만 [`docs/RELEASE_ARTIFACT_SPEC.md`](docs/RELEASE_ARTIFACT_SPEC.md) §5의
`approval_required_paths`에 포함되므로, merge 결과를 적용할 때도 경로별 사람 승인이
필요하다. 따라서 Acceptance #5의 보호 수준은 `project-owned`와 동일하게 유지된다.

공통 agent 지식과 프로젝트 지식을 한 파일에 섞지 않는다.

- `.ai/runtime/agents/base/**`: kit-owned 공통 역할
- `.ai/project/agents/**`: project-owned 역할 보강
- `AGENTS.md`: 두 계층과 canonical source를 가리키는 짧은 adapter

## 9. 명세 최신성 설계

### 9.1 `SPEC_REGISTRY.yaml`

각 프로젝트는 코드 경로와 관련 명세·검증기를 명시적으로 연결한다.

```yaml
schema_version: 1
project_id: example-project
rules:
  - id: database-contract
    source_globs:
      - db/migrations/**
      - src/lib/db/**
    canonical_specs:
      - .ai/canonical/PROJECT_MAP.yaml
      - .ai/canonical/contracts/database.md
    generated_facts:
      - .ai/generated/database-schema.json
    checks:
      - migration-checksum
      - disposable-database-introspection
    impact_policy: spec_update_or_approved_no_impact
```

새로운 high-risk 경로가 어느 rule에도 매핑되지 않으면 “영향 없음”으로 간주하지 않고 CI를 실패시킨다.

### 9.2 docs impact 규칙

관련 코드가 바뀌면 다음 중 하나를 요구한다.

1. 연결된 spec 변경과 `verified_against.source_tree_digest` 갱신
2. `docs-impact: none`의 구체 사유, change-set digest, CODEOWNER 승인

기본 `no impact` 문구를 미리 채워두지 않는다. 의미 없는 문서 touch만으로 통과하지 못하도록 generated facts와 결정론적 검사를 함께 사용한다.

### 9.3 강제 계층

| 계층 | 역할 | 우회 시 영향 |
|---|---|---|
| Global/project instructions | 무엇을 읽고 갱신할지 안내 | advisory |
| Repo-local hook | commit 전 빠른 검사 | `--no-verify` 등으로 우회 가능 |
| Required PR CI | spec/route/schema/digest 검사와 merge 차단 | ruleset 권한 없이는 merge 불가 |
| Deploy gate | exact SHA와 receipt 검증 | 미검증 artifact 배포 차단 |

조직 ruleset workflow를 사용할 수 있으면 중앙 required workflow를 적용한다. 사용할 수 없으면 각 저장소의 얇은 caller가 중앙 reusable workflow의 exact commit SHA를 참조한다.

### 9.4 배포 receipt

배포 가능한 artifact에는 다음을 결합한다.

- Git commit SHA
- kit version과 `kit_bundle_digest`
- `SPEC_REGISTRY` digest
- generated facts digest
- required check 결과
- DB migration head/checksum
- 프로젝트 전용 release evidence

라이브 배포는 receipt에 기록된 exact artifact만 허용한다.

## 10. 프로젝트 유형별 작동 예시

아래는 가상의 구조 예시이며 실제 서비스의 구성이나 운영 상태를 나타내지 않는다.

### 10.1 API 서비스

공통 adapter는 route, symbol, migration 정보를 생성한다. 프로젝트 registry는
각 경로를 API 명세와 테스트에 연결한다. DB 변경은 disposable 환경에서 검증하고,
실제 provider 호출과 배포는 해당 프로젝트의 권한과 검증 절차를 따른다.

### 10.2 Worker 서비스

작업 큐, 재시도, idempotency와 provider 경계를 프로젝트 명세가 소유한다.
공통 kit은 변경 범위와 증거 형식을 검사한다. 로컬 테스트 통과를 운영 배포의 증거로
해석하지 않는다.

### 10.3 Web 서비스

route와 TypeScript export 목록을 생성하고, UI/API/DB 변경을 해당 명세와 연결한다.
인증·개인정보·배포 설정은 프로젝트가 소유한다. 다른 프로젝트의 context를 재사용하지 않는다.

### 10.4 미분류 프로젝트

구조나 소유권이 불분명하면 read-only inventory부터 수행한다. 추정한 DB·인증·배포
설정을 적용하지 않고, 프로젝트 담당자가 확인한 사실을 registry에 기록한다.

## 11. 기존 프로젝트 마이그레이션 순서

각 phase의 실행 절차, 검증 명령, 종료조건, 롤백은 아래 phase 문서가 소유한다.
이 절은 phase 경계와 의존 관계만 규정한다. phase 승인 단위는 문서 하나와 1:1로 대응한다.

모든 phase 문서는 같은 8개 절을 갖는다: 목적 / 전제조건 / 산출물 / 실행 절차 /
검증 명령 / 종료조건 / 롤백 / 이 phase가 승인하지 않는 작업.
작성 규칙은 [`docs/TEMPLATE_PHASE.md`](docs/TEMPLATE_PHASE.md)에 있다.

| phase | 문서 | 무엇을 성립시키는가 | 변경 대상 | 종료조건 ID |
|---|---|---|---|---|
| 0 | [`PHASE_0`](docs/phases/PHASE_0_FREEZE_AND_INVENTORY.md) | 독립 도구로 동결·인벤토리와 되돌릴 수 있는 baseline 증거 확보 | 이 계획 저장소 도구/evidence + git checkpoint ref + 외부 archive | G0-1 ~ G0-9 |
| 1 | [`PHASE_1`](docs/phases/PHASE_1_RELEASE_INTEGRITY.md) | 불변 release artifact와 digest 정체성, plan/apply 결속 | 중앙 kit | G1-1 ~ G1-16 |
| 2 | [`PHASE_2`](docs/phases/PHASE_2_THREE_TIER_AND_FIXTURES.md) | 3계층 분리, lock 스키마, 합성 fixture, context 격리 | 중앙 kit | G2-1 ~ G2-15 |
| 3 | [`PHASE_3`](docs/phases/PHASE_3_CANARY_ADOPTION.md) | 실제 저장소 canary와 순차 adoption | 저장소별 PR | G3-1 ~ G3-15 |
| 4 | [`PHASE_4`](docs/phases/PHASE_4_SPEC_FRESHNESS_GATE.md) | 명세 최신성 required gate와 deploy receipt | 저장소별 PR | G4-1 ~ G4-16 |
| 5 | [`PHASE_5`](docs/phases/PHASE_5_OPERATIONS_AND_RETIREMENT.md) | 운영 자동화, release 채널, nested clone 퇴역 | 중앙 kit + 저장소별 PR | G5-1 ~ G5-14 |

의존 관계는 선형이다. 각 phase는 직전 phase의 종료조건 전부가 충족된 뒤에만 시작한다.

```text
Phase 0 ─→ Phase 1 ─→ Phase 2 ─→ Phase 3 ─→ Phase 4 ─→ Phase 5
   │           ▲
   │           │
   ├─ plan repo의 독립 dirty/checkpoint 도구
   └──── docs/RELEASE_ARTIFACT_SPEC.md (공통 알고리즘 계약)
```

Phase 0의 구현은 이 계획 저장소의
`lib/ai_harness_governance/{dirty_snapshot,checkpoint}.rb`와 `bin/{dirty-snapshot,harness-checkpoint}`다.
Phase 0은 미래의 Phase 1 경로를 호출하지 않는다. Phase 1은 중앙 kit 안에 별도 runtime
구현을 두고 같은 SPEC과 회귀 벡터를 통과시킨다. 이 경계로 `Phase 0 → Phase 1 helper →
Phase 0 종료` 순환 의존을 제거한다.

Phase 0 checkpoint는 완전한 복원을 위해 worktree 전체 dirty 상태를 기록한다. 반면 Phase 1
plan/apply의 `dirty_snapshot_scope`는 **정확한 plan 대상 경로 ∪ 하네스 allowlist**로
확정한다. scope 값 자체를 plan에 넣고 apply가 같은 scope로 재계산하므로, 범위를 바꾸는
것도 plan 불일치다.

실행 순서상 두 가지가 계획 초안과 달라졌다. 근거는
[`docs/INVENTORY_TEMPLATE.md`](docs/INVENTORY_TEMPLATE.md) §3, §5다.

1. Phase 1은 **baseline tag 생성**부터 시작하고 **최종 release tag는 P0 구현 이후**에 만든다.
   중앙 kit에 tag가 하나도 없어서, dirty/untagged apply 차단을 먼저 넣으면 release를
   만들 수단이 사라진다. 그리고 `kit_bundle_digest`는 tag의 tree에서 계산되므로,
   구현 전 tag의 release에는 수정 전 installer가 담긴다. baseline tag는 `pinnable: false`다.
2. Phase 3의 canary는 하나가 아니라 두 트랙이다. managed upgrade는 `sample-api`,
   legacy adoption은 `sample-worker`이다. 한 트랙의 통과가 다른 트랙을 증명하지 않는다.

## 12. Acceptance Criteria

1. 전역 설정에 프로젝트 secret, DB 연결값, 함수 목록의 수기 복사본이 없다.
2. 각 Git 프로젝트는 exact kit version과 artifact digest를 pin한다.
3. dirty 또는 untagged kit source에서 apply가 실패한다.
4. 같은 version의 template drift도 `upgrade_available`로 감지한다.
5. project-owned 파일은 명시적 사람 승인 없이는 한 바이트도 변경·삭제되지 않는다.
6. `.ai/tasks/**`는 kit upgrade 삭제 대상이 아니다.
7. migration 전후 application code diff가 0이거나 모든 차이가 명시적으로 승인된다.
8. high-risk source glob은 최소 하나의 canonical/generated contract에 연결된다.
9. route/API/DB/generated fact는 현재 commit과 digest가 일치한다.
10. 불완전한 `PROJECT_MAP`에서는 DB/auth/deploy 작업이 fail-closed 된다.
11. 서로 다른 두 프로젝트를 연속 진입하는 negative test에서 context가 섞이지 않는다.
12. PR은 spec 변경 또는 승인된 `docs-impact:none` 없이는 merge되지 않는다.
13. 배포 artifact SHA는 spec gate를 통과한 SHA와 동일하다.
14. MemSearch/Obsidian의 기억이 canonical spec을 덮어쓸 수 없다.
15. 기존 프로젝트는 `migrated`, `deferred + reason`, `excluded` 중 하나로 기록된다.
16. nested clone 제거는 baseline 복원과 migration acceptance 이후 별도 PR에서만 수행된다.
17. provider 호출, production DB 접속, deployment는 각각 별도 승인 gate를 유지한다.
18. global hook을 우회해도 required CI와 deploy gate가 정책 위반을 막는다.

### 12.1 Acceptance ↔ Phase 매핑

각 기준이 어느 phase에서 충족되고, 어떤 검증으로 확인되며, 어디에 증거가 남는지를 고정한다.
검증 ID는 각 phase 문서 §5의 표를, 종료조건 ID는 §6의 표를 가리킨다.

| # | 기준 요약 | 충족 phase | 종료조건 | 검증 | 증거 경로 |
|---|---|---|---|---|---|
| 1 | 전역 설정에 프로젝트 secret·DB 연결값·함수 목록 수기 복사본 없음 | 0(현황 고정), 2(구조 분리) | G0-9, G2-1 | V0-15, V0-16, V2-1 | `evidence/$SNAP/global-config-scan.txt` |
| 2 | 각 프로젝트가 exact kit version과 artifact digest를 pin | 3 | G3-6 | V3-9 | 저장소 `.ai/KIT_INSTALLATION.yaml` |
| 3 | dirty 또는 untagged source에서 apply 실패 | 1 | G1-8 | V1-9, V1-18 | `test/source_gate_test.rb` 실행 로그 |
| 4 | 같은 version의 template drift도 `upgrade_available`로 감지 | 1, 2 | G1-5, G2-5 | V1-14, V2-6 | `evidence/phase1/COMPLETION.md` |
| 5 | project-owned 파일은 승인 없이 한 바이트도 변경·삭제되지 않음 | 1, 3, 5 | G1-10, G3-3, G5-4 | V1-10, V3-5, V5-7 | `evidence/phase3/<repo>/ownership.txt` |
| 6 | `.ai/tasks/**`는 kit upgrade 삭제 대상이 아님 | 1, 3 | G1-11, G3-4 | V1-10, V3-6 | `test/ownership_policy_test.rb`, `evidence/phase3/<repo>/COMPLETION.md` |
| 7 | migration 전후 application code diff 0 또는 전건 승인 | 3 | G3-2 | V3-4 | `evidence/phase3/<repo>/diff-classification.txt` |
| 8 | high-risk source glob이 최소 하나의 contract에 연결 | 4 | G4-2, G4-3 | V4-5, V4-6 | 저장소 `.ai/SPEC_REGISTRY.yaml` |
| 9 | route/API/DB/generated fact가 현재 코드 tree와 digest가 일치 | 4 | G4-4, G4-4a, G4-4b | V4-3, V4-4, V4-4a, V4-7a, V4-8 | 저장소 `.ai/generated/**` + CI 실행 기록 |
| 10 | 불완전한 `PROJECT_MAP`에서 DB/auth/deploy가 fail-closed | 2, 4 | G2-11, G4-14 | V2-17 | `test/fixture_lifecycle_test.rb` 실행 로그 |
| 11 | 두 프로젝트 연속 진입 negative test에서 context 미혼입 | 2 | G2-9, G2-10 | V2-9, V2-15, V2-18 | `test/context_isolation_test.rb` 실행 로그 |
| 12 | spec 변경 또는 승인된 `docs-impact:none` 없이 merge 불가 | 4 | G4-5, G4-7 | V4-7, V4-7b, V4-10, V4-11 | required check 실행 기록 |
| 13 | 배포 artifact SHA = spec gate 통과 SHA | 4 | G4-10 | V4-14, V4-14a, V4-15, V4-16, V4-16a, V4-16b | GitHub check-runs API 응답 + (Tier 2) artifact attestation |
| 14 | MemSearch/Obsidian 기억이 canonical spec을 덮어쓸 수 없음 | 2(격리), 4(gate 입력 배제) | G2-9, G4-16 | V2-9(I-7), V4-21, V4-22 | `test/context_isolation_test.rb`, gate 입력 목록 |
| 15 | 모든 기존 프로젝트가 `migrated`/`deferred + reason`/`excluded`로 기록 | 0, 3 | G0-2, G3-13 | V0-13, V0-14 | [`docs/INVENTORY_TEMPLATE.md`](docs/INVENTORY_TEMPLATE.md) §7 |
| 16 | nested clone 제거는 baseline 복원과 acceptance 이후 별도 PR에서만 | 3(보존), 5(제거) | G3-10, G5-8, G5-9, G5-10 | V3-12, V5-13, V5-15 | `evidence/phase5/<repo>/baseline-restore.md` |
| 17 | provider 호출, production DB 접속, deployment가 각각 별도 승인 gate | 2, 4, 5 | G4-13 및 각 phase §8 | V2-10, V4-20 | 각 phase 문서 §8, 승인 기록 |
| 18 | global hook을 우회해도 required CI와 deploy gate가 위반을 막음 | 4 | G4-9, G4-10 | V4-12 | required check 실행 기록 |

#### 해석 주석: commit SHA를 파일에 기록할 수 없다

기준 #9의 "현재 commit과 digest가 일치한다"와 #13의 "배포 artifact SHA"는
**저장소 파일 안에 자기 commit SHA를 적는 방식으로는 달성할 수 없다.**
값을 파일에 쓰면 그 커밋의 SHA가 다시 바뀌므로 고정점이 존재하지 않는다
([`docs/RELEASE_ARTIFACT_SPEC.md`](docs/RELEASE_ARTIFACT_SPEC.md) S-07).

따라서 두 기준은 아래와 같이 해석한다. 기준 문구 자체는 변경하지 않는다.

| 무엇 | 어디에 기록하는가 | 무엇으로 검증하는가 |
|---|---|---|
| 코드와 명세의 대응 | 저장소 파일의 `source_tree_digest` | gate가 PR head tree에서 재계산해 비교(SPEC §4.4) |
| generated fact의 최신성 | 저장소 파일의 `content_digest` | gate가 코드에서 재생성해 비교 |
| commit SHA와 check 결과 | 저장소 밖. GitHub check-runs API 응답 | deploy gate가 배포 시점에 API 조회 |
| 배포 artifact provenance | (Tier 2) artifact attestation | `gh attestation verify`. 도입 여부는 D-NEED-13 |


기준 #1과 #17은 "없음"과 "분리되어 있음"을 증명하는 항목이므로, 단일 명령의 성공이 아니라
read-only 점검 결과와 각 phase의 금지 목록으로 확인한다. 나머지 16개는 실행 가능한
검증 명령 하나 이상에 연결되어 있다.

## 13. 주요 위험과 대응

| 위험 | 대응 |
|---|---|
| 중앙 kit dirty 변경이 정식 release처럼 설치됨 | clean/tagged artifact와 bundle digest 강제 |
| project-owned 명세 덮어쓰기 | 소유권 분리, expected SHA, 자동 교체 금지 |
| 제거된 kit 파일이 orphan으로 남음 | 명시적 tombstone과 별도 검토 |
| hook 우회 | required CI와 deploy receipt |
| AI가 다른 프로젝트 정보를 혼합 | repository fingerprint, context reset, negative test |
| 수기 함수/DB 문서 drift | AST/compiler/migration 기반 generated facts |
| 기억이 현재 사실처럼 사용됨 | Git canonical 우선순위와 source/date 표시 |
| active feature 중 migration 충돌 | deferred 상태와 격리 maintenance worktree |
| 여러 프로젝트 batch 중 부분 실패 | 프로젝트별 PR, 순차 rollout, 프로젝트 단위 rollback |

## 14. 적용 권한과 범위

이 문서는 재사용 가능한 설계 자료다. 특정 조직이나 저장소의 실행 승인을 포함하지 않는다.
대상 저장소의 소유자가 코드 변경, checkpoint, PR, merge, release 및 배포 범위를 정한다.
한 프로젝트의 승인을 다른 프로젝트에 적용하지 않는다.

전역 설정 변경, credential 사용, production DB 접근, 유료 서비스 사용, 배포,
기존 작업 삭제는 각각 실제 작업 범위와 권한을 확인한 뒤 수행한다.
실행 기록과 승인 증거는 해당 조직의 비공개 저장소에서 관리한다.

## 15. 근거 자료

### 구현 참조

공통 kit의 `engine/install/`, `engine/release/`, `engine/validators/`와
`docs/MIGRATION.md`를 참조한다. 이 저장소의 checkpoint 구현은
`lib/ai_harness_governance/`에 있다. 프로젝트별 명세는 대상 저장소에서 확인한다.

### 공식 권고

- OpenAI Harness Engineering: https://openai.com/index/harness-engineering/
- OpenAI AGENTS.md: https://learn.chatgpt.com/docs/agent-configuration/agents-md
- OpenAI Hooks: https://learn.chatgpt.com/docs/hooks
- Anthropic Claude Code best practices: https://code.claude.com/docs/en/best-practices
- Anthropic Claude Code settings: https://code.claude.com/docs/en/settings
- Anthropic plugins: https://code.claude.com/docs/en/plugins
- GitHub ruleset workflow rules: https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- GitHub reusable workflows: https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows
- Kiro Steering: https://kiro.dev/docs/steering/
- Kiro Specs best practices: https://kiro.dev/docs/specs/best-practices/

## 16. 적용 순서

새 환경에서는 Phase 0부터 현재 상태를 수집하고 각 phase의 종료조건을 검증한다.
이 공개본의 문서 상태는 설계 준비 상태이며, 특정 fleet의 완료 상태가 아니다.

1. 대상과 권한을 확정하고 복원 가능한 checkpoint를 만든다.
2. 개인정보가 없는 release artifact와 exact version/digest를 검증한다.
3. 합성 fixture와 독립된 canary에서 검증한다.
4. 실제 required checks와 배포 경계가 적용되는지 확인한다.
5. 프로젝트별 검증 결과를 비공개 evidence로 남긴다.

## 17. 적용 시 작성할 결정 원장

아래 항목은 적용 환경별로 결정한다. 이 공개본은 과거 조직의 결정·승인 원장을 제공하지 않는다.

| 항목 | 기록할 내용 |
|---|---|
| 대상과 제외 | 프로젝트 소유자, 현재 branch, active work, 제외 이유 |
| canary | managed upgrade와 legacy adoption의 독립 검증 대상 |
| release | 공개 가능한 버전, commit, artifact digest와 검증 결과 |
| 권한 | merge, required checks, provider, DB, 배포 권한 |
| 복원 | checkpoint 위치, 복원 테스트와 보존 기간 |
| 예외 | 승인자, 정확한 범위, 만료 시점, 잔여 위험 |

공통 설계 결정은 다음과 같다.

- plan/apply snapshot 범위는 정확한 대상 경로와 하네스 allowlist의 합집합이다.
- `AGENTS.md`는 merge-owned이며 경로별 검토가 필요하다.
- 안전한 상대 symlink는 versioned snapshot 정책으로 보존한다.
- memory와 개인 MCP 설정은 검증의 신뢰 입력이 아니다.
- 실제 값이 없는 공개 예시는 완료 증거로 사용할 수 없다.

Phase 문서가 참조하는 결정 ID는 아래 주제의 기록 위치를 뜻한다. 각 적용 환경에서
담당자와 결론을 기록하며, 이 표 자체가 결정의 승인이나 완료 증거는 아니다.

| ID | 적용 환경에서 확인할 결정 |
|---|---|
| D-NEED-01 | linked worktree의 보존과 적용 기준 branch |
| D-NEED-02 | 대상 프로젝트 집합과 제외 범위 |
| D-NEED-03 | 실제 Git root와 단순 디렉터리의 구분 |
| D-NEED-04 | active lock의 소유자와 유효성 |
| D-NEED-05 | 임시 worktree의 복원 가능한 보존 방법 |
| D-NEED-06 | 큰 dirty scope의 검토·보존 기준 |
| D-NEED-07 | 최초 pin 가능한 release 버전 |
| D-NEED-08 | side-by-side 검증에 사용할 두 release |
| D-NEED-09 | 실제 required workflow/check 강제 방식 |
| D-NEED-10 | artifact 서명 정책 |
| D-NEED-11 | 프로젝트별 초기 registry rule |
| D-NEED-12 | plan 대상 경로와 하네스 allowlist의 합집합 |
| D-NEED-13 | provenance attestation의 적용 범위 |
| D-NEED-14 | AGENTS.md의 merge-owned 소유권과 경로별 검토 |
| D-NEED-15 | versioned snapshot의 안전한 상대 symlink 정책 |
| D-NEED-16 | 실행 직전 입력을 다시 확인하고 drift를 처리하는 방법 |

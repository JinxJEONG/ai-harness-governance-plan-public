---
title: 'Phase 2: 3계층 구조와 합성 fixture'
phase: 2
project_id: ai-harness-governance-plan
status: reference-template
depends_on: [1]
target_repository: $WORKSPACE/ai-agentic-workflow-kit
mutates_project_files: false
---

# Phase 2. 3계층 구조와 합성 fixture

> 공개용 절차 템플릿입니다. 실제 프로젝트의 승인·완료 상태는 포함하지 않습니다.

## 1. 목적

중앙 kit을 계획 문서 D-01의 3계층 구조에 맞게 분리하고, 프로젝트가 exact version을
pin하는 lock 스키마를 확정한다. 실제 저장소를 건드리지 않고 legacy와 managed 두 상태를
재현하는 합성 fixture를 만들어, 두 kit 버전 side-by-side 실행과 프로젝트 간 context
격리를 테스트로 고정한다.

Phase 3은 이 phase 없이는 불가능하다. 실제 프로젝트에 처음 apply하기 전에
"legacy 상태에서 apply가 안전하다"와 "다른 프로젝트 정보가 새지 않는다"를
합성 환경에서 증명해야 한다.

## 2. 전제조건

| # | 조건 | 검사 방법 |
|---|---|---|
| P2.pre-1 | Phase 1 artifact 종료조건과 baseline/current reader 재현 충족 | [`PHASE_1`](PHASE_1_RELEASE_INTEGRITY.md) §6. YYYY-MM-DD 재검사에서 발견한 legacy baseline reader 호환 수정을 이 phase의 첫 commit으로 적용한 뒤 두 ref verify를 재실행 |
| P2.pre-2 | pinnable annotated `v0.4.0` 존재 + `v0.4.1` 생성 가능 | non-pinnable baseline은 side-by-side project release로 세지 않는다 |
| P2.pre-3 | Docker 사용 가능 | `docker info` exit 0 |
| P2.pre-4 | disposable PostgreSQL 이미지 확보 | 실행 직전 `postgres:16-alpine`을 재검사하고 `sha256:<sha256>` linux/arm64에서 실제 검증 완료 |
| P2.pre-5 | 중앙 kit 수정 승인 | 격리 worktree의 순서화된 commit, local tag/artifact, fixture, Docker만 포함. 실제 프로젝트는 대상이 아니다 |

## 3. 산출물

| 산출물 | 경로 | 종류 |
|---|---|---|
| 3계층 디렉터리 구조 | 중앙 kit `engine/`, `schemas/`, `adapters/`, `skills/`, `vendors/`, `fixtures/` | 신규 |
| lock 스키마 | `schemas/kit-installation.schema.yaml` | 신규 |
| legacy fixture | `fixtures/legacy-unknown/` | 신규 |
| managed fixture | `fixtures/managed-current/` | 신규 |
| 2개 프로젝트 격리 fixture | `fixtures/isolation-alpha/`, `fixtures/isolation-beta/` | 신규 |
| fixture 생성기 | `fixtures/build_fixture.rb` | 신규 |
| side-by-side resolver | `engine/resolver/release_cache.rb` | 신규 |
| 격리 테스트 | `test/context_isolation_test.rb` | 신규 |
| fixture 통합 테스트 | `test/fixture_lifecycle_test.rb` | 신규 |
| DB adapter 검증 | `test/adapter_postgres_test.rb` | 신규 |
| `--dev-source` 제거 | `installer/bootstrap_project.rb` | 수정 |
| Phase 2 완료 보고 | 이 계획 저장소 `evidence/phase2/COMPLETION.md` | project-owned |

## 4. 실행 절차

### 4.1 P2-1. 재편 매핑 확정

아래 매핑은 이전 설치 구조를 다루는 예시다. 대상 버전의 실제 경로를 먼저 확인한다.

1. `[read-only]` 아래 매핑표를 검토하고 확정한다. 파일 이동은 `git mv`로 수행해
   이력을 보존한다.

| 현재 경로 | 목표 경로 | 계층 | 소유권(설치 시) |
|---|---|---|---|
| `installer/bootstrap_project.rb` | `engine/install/bootstrap_project.rb` | Shared Org | 설치 대상 아님 |
| `installer/status.rb` | `engine/install/status.rb` | Shared Org | 설치 대상 아님 |
| `installer/upgrade.rb` | `engine/install/upgrade.rb` | Shared Org | 설치 대상 아님 |
| `installer/validate_install.rb` | `engine/validators/validate_install.rb` | Shared Org | 설치 대상 아님 |
| `installer/inventory.rb` | `engine/inventory/inventory.rb` | Shared Org | 설치 대상 아님 |
| `installer/discover_project.rb` | `engine/resolver/discover_project.rb` | Shared Org | 설치 대상 아님 |
| `installer/adopt.rb` | `engine/install/adopt.rb` | Shared Org | 설치 대상 아님 |
| `engine/release/release_digest.rb` (Phase 1 신규) | 위치 유지 | Shared Org | `installer/lib` wrapper는 호환 진입점 |
| `engine/release/dirty_snapshot.rb` (Phase 1 신규) | 위치 유지 | Shared Org | `installer/lib` wrapper는 호환 진입점 |
| `engine/release/release_manifest.rb` (Phase 1 신규) | 위치 유지 | Shared Org | `installer/release_manifest.rb`는 CLI 진입점 |
| `core/project-template/.ai/scripts/**` (16개) | `core/project-template/.ai/runtime/scripts/**` | Project 설치물 | `kit-owned` |
| `core/project-template/.ai/canonical/agents/**` (6개) | `core/project-template/.ai/runtime/agents/base/**` | Project 설치물 | `kit-owned` |
| `core/project-template/.ai/templates/**` | `core/project-template/.ai/runtime/templates/**` | Project 설치물 | `kit-owned` |
| `core/project-template/.githooks/**` | `core/project-template/.ai/runtime/githooks/**` | Project 설치물 | `kit-owned` |
| `core/project-template/.ai/canonical/PROJECT_MAP.yaml` | 위치 유지 | Project 사실 | `project-owned` |
| `core/project-template/.ai/canonical/ENV_MATRIX.yaml` | 위치 유지 | Project 사실 | `project-owned` |
| `core/project-template/.ai/canonical/context-map.yaml` | 위치 유지 | Project 사실 | `project-owned` |
| `core/project-template/.ai/canonical/PROJECT_RULES.md` | 위치 유지 | Project 사실 | `project-owned` |
| `core/project-template/.ai/canonical/{architecture,decisions,feature-history,runbooks}/**` | 위치 유지 | Project 사실 | `project-owned` |
| `core/project-template/.ai/local/.gitignore` | 위치 유지 | Project 로컬 | `project-owned` |
| `core/project-template/AGENTS.md` | 위치 유지 | 진입점 | `merge-owned` |
| (신규) | `core/project-template/.ai/project/agents/README.md` | Project override | `project-owned` |
| (신규) | `core/project-template/.ai/generated/.gitignore` | 생성 사실 | `generated` |
| `core/project-template/.github/workflows/agent-workflow-policy.yml` | 위치 유지 | CI caller | `merge-owned` |
| `examples/generic/**` | `fixtures/reference-generic/**` | 검증 자산 | 설치 대상 아님 |
| `.github/workflows/ci.yml` | 위치 유지 | 중앙 CI | 설치 대상 아님 |

2. `[read-only]` 이 매핑이 해결하는 실제 결함을 기록한다.

현재 `core/project-template/.ai/canonical/agents/`에는 kit이 저술한 공통 역할 파일
6개(`ai-worker.md`, `architect.md`, `backend.md`, `frontend.md`, `pm.md`, `reviewer.md`)가 있다.
그런데 `installer/bootstrap_project.rb:282`의 `file_ownership`은 `.ai/canonical/**`를
`"project"`로 판정한다. 결과적으로 **kit이 만든 공통 agent 정의가 project-owned로
분류되어 upgrade에서 영구히 `preserve`된다.** 공통 역할을 개선해도 기존 프로젝트에
도달하지 않는다. 계획 문서 §8이 요구한 분리
(`.ai/runtime/agents/base/**`는 kit-owned, `.ai/project/agents/**`는 project-owned)를
이 매핑이 실현한다.

3. `[mutating: 중앙 kit]` 이동 이력이 보이도록 순서화된 commit으로 `git mv`를
   수행하고, Phase 1에서 만든 `ownership_rules`(release manifest)를 새 경로에
   맞게 갱신한다. `v0.4.0` tree에 engine wrapper/runtime agent 복제본이 이미 있으므로,
   첫 commit에서 중복 destination을 정리하고 다음 commit에서 source를 정본 destination으로
   이동한 후 compatibility wrapper를 둔다. 하나의 M/D snapshot을 이력 보존으로 간주하지 않는다.
4. `[mutating: 중앙 kit]` 경로 이동은 `kit_bundle_digest`를 바꾸므로 새 버전을 올린다.
   기존 설치본에 대해서는 **경로 이동 migration**이 필요하다. 이 migration은
   `.ai/canonical/agents/**`를 삭제하지 않는다. 새 위치에 kit-owned 파일을 설치하고,
   기존 파일은 tombstone 없이 그대로 남긴 뒤 Phase 3의 프로젝트별 PR에서
   사람이 검토해 정리한다(계획 문서 §5 P0-05).

### 4.2 P2-2. lock 스키마

5. `[additive]` `schemas/kit-installation.schema.yaml`을 만든다.
   [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §6의 lock 구조를 스키마로 고정한다. 필수 필드:
   `schema_version`, `project_id`, `kit_version`, `kit_bundle_digest`,
   `bundle_digest_algo`, `rendered_digest_algo`, `source.kind`, `source.locator`,
   `repository_fingerprint`, `profile`, `protected_paths`.
6. `[additive]` `schemas/spec-registry.schema.yaml`과 `schemas/generated-facts.schema.yaml`의
   자리만 만든다. 내용은 [`PHASE_4`](PHASE_4_SPEC_FRESHNESS_GATE.md)가 채운다.
7. `[mutating: 중앙 kit]` `engine/validators/validate_install.rb`가 lock을 스키마로
   검증하게 한다. 스키마 위반이면 `invalid`로 판정한다.

### 4.3 P2-3. 합성 fixture

8. `[additive]` `fixtures/build_fixture.rb`를 만든다. fixture는 실행 시점에
   임시 디렉터리에 git 저장소로 생성한다. 저장소에 커밋되는 것은 생성기와 시드 데이터뿐이다.
   `test/test_helper.rb`의 `with_project`가 이미 같은 방식(`Dir.mktmpdir` + `git init -b main`)을
   쓰므로 그 헬퍼를 재사용한다.

| fixture | 재현하는 실제 상태 | 시드 내용 |
|---|---|---|
| `legacy-unknown` | `sample-worker` 계열. manifest 없음, `.ai/**`와 `AGENTS.md`는 존재, `.githooks` 있으나 `core.hooksPath` 미설정 | `<baseline-sha>` baseline에서 갈라진 `.ai/canonical/**` 수정 3건, dirty 파일 2건 |
| `managed-current` | `sample-api` 계열. schema 2 / managed / 이전 버전 pin | 이전 release의 `installed_files` digest가 정확히 일치하는 상태 |
| `managed-drifted` | 같은 `kit_version`인데 template만 바뀐 상태 | Acceptance #4 검증용. `kit_version` 동일, `template_tree_digest` 상이 |
| `blocked-active` | `sample-web` 계열. `ACTIVE_CONTEXT`가 `streams_in_progress`, LOCK 6건 | plan 자체가 `blocked`여야 한다 |
| `linked-worktree` | `sample-worker` + `sample-worker-preview` | 같은 `repository_fingerprint`, 다른 `worktree_path`. [`INVENTORY`](../INVENTORY_TEMPLATE.md) §4.2(a) |
| `volatile-worktree` | `sample-api`의 `/private/tmp` worktree | linked worktree가 dirty이고 주 worktree는 clean인 상태. §4.2(b) |
| `isolation-alpha` | 서로 다른 DB/API를 가진 프로젝트 A | PostgreSQL DB 이름 `alpha_db`, API prefix `/api/alpha` |
| `isolation-beta` | 서로 다른 DB/API를 가진 프로젝트 B | PostgreSQL DB 이름 `beta_db`, API prefix `/api/beta` |
| `unknown-project` | `PROJECT_MAP`이 불완전한 상태 | `PROJECT_MAP.yaml`의 services가 빈 값. fail-closed 검증용 |

9. `[additive]` `test/fixture_lifecycle_test.rb`를 만든다. 각 fixture에 대해
   plan → apply → validate → status의 전체 왕복을 검증한다.
   - `legacy-unknown`: apply 후 수정된 `.ai/canonical/**` 3건의 SHA-256이 불변
   - `managed-current`: status가 `current`
   - `managed-drifted`: status가 `current`가 **아니다**(`upgrade_available`)
   - `blocked-active`: plan이 `blocked`이고 apply가 거부된다
   - `linked-worktree`: 두 worktree의 `repository_fingerprint`가 같고 `worktree_path`가 다르다
   - `volatile-worktree`: 주 worktree가 clean이어도 linked worktree가 dirty면
     `dirty_snapshot_digest`가 그 사실을 반영한다
   - `unknown-project`: DB/auth/deploy 관련 작업이 fail-closed 된다(Acceptance #10)

### 4.4 P2-4. side-by-side 두 버전

10. `[mutating: 중앙 kit]` 두 번째 annotated tag를 만든다. 해소된 D-NEED-08 결정에 따라
    side-by-side 대상은 `v0.4.0`과 `v0.4.1`이다.
11. `[additive]` `engine/resolver/release_cache.rb`를 만든다.
    캐시 주소는 버전 문자열이 아니라 digest다:
    `$KIT_RELEASE_CACHE/<kit_bundle_digest>/`(기본
    `$HOME/.cache/orca/kit-releases/<digest>/`). [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §6.
12. `[read-only]` 두 release를 캐시에 넣고, `isolation-alpha`는 앞 버전을,
    `isolation-beta`는 뒷 버전을 pin한다. 두 fixture에 각각 apply한다.
13. `[additive]` 검증: 두 fixture의 `KIT_INSTALLATION.yaml`의 `kit_version`과
    `kit_bundle_digest`가 서로 다르고, 각자 pin한 값과 일치한다.
    한 fixture를 apply하는 동안 다른 fixture의 파일이 하나도 변하지 않는다
    (apply 전후 `git status --porcelain` digest 비교).

### 4.5 P2-5. cross-project context isolation

계획 문서 Acceptance #11이 요구하는 negative test다. 판정 기준을 값 수준으로 고정한다.

14. `[additive]` `test/context_isolation_test.rb`를 만든다. 시나리오:
    한 프로세스 또는 연속된 두 프로세스에서 `isolation-alpha` → `isolation-beta` 순으로
    진입한 뒤, beta의 context에 alpha의 값이 남아 있으면 **실패**로 판정한다.

**섞였다고 판정하는 구체 기준.** beta 진입 후 아래 중 **하나라도** 나타나면 실패다.

| # | 검사 대상 | 실패 조건 |
|---|---|---|
| I-1 | resolver가 보고한 `git rev-parse --show-toplevel` | `isolation-alpha` 경로를 포함한다 |
| I-2 | `repository_fingerprint` | alpha의 fingerprint와 같다 |
| I-3 | 로드된 `PROJECT_MAP.yaml`의 `services` 키 | `alpha`로 시작하는 service 이름을 포함한다 |
| I-4 | 해석된 DB 이름 | `alpha_db` 문자열을 포함한다 |
| I-5 | 해석된 API prefix | `/api/alpha` 문자열을 포함한다 |
| I-6 | 로드된 canonical spec 파일 경로 목록 | `isolation-alpha/.ai/**` 경로를 포함한다 |
| I-7 | memory 검색 scope | alpha의 `project_id`를 포함한다 |
| I-8 | 환경변수 이름 목록 | alpha fixture에만 존재하는 `ALPHA_ONLY_VAR`를 포함한다 |
| I-9 | plan JSON의 `target`/`worktree_path` | alpha 경로를 포함한다 |

15. `[additive]` 반대 방향(beta → alpha)도 같은 기준으로 검증한다.
    한 방향만 통과하는 상태를 통과로 인정하지 않는다.
16. `[additive]` **negative**: 격리 로직을 일부러 무력화한(예: resolver 캐시를
    프로세스 전역으로 만든) 변형에서 위 검사가 실제로 실패하는지 확인한다.
    실패하지 않으면 테스트 자체가 무의미하다.
17. `[additive]` **negative**: `unknown-project` fixture에서 DB/auth/deploy 작업 요청 →
    fail-closed. 추측으로 채워진 값이 하나라도 있으면 실패(Acceptance #10).
18. `[additive]` resolver 요건을 고정한다. 세션 시작 시점과 Git root가 바뀌는 시점에
    project context를 다시 초기화한다(계획 문서 §7). 다른 프로젝트에서 온 절대경로와
    DB 식별자는 현재 lock이 허용하지 않으면 거부한다.

### 4.6 P2-6. Docker disposable PostgreSQL

19. `[additive]` `adapters/postgresql/introspect.rb`를 만든다. 대상은 항상
    일회용 컨테이너이며, 운영 DB에 접속하지 않는다.
20. `[additive]` `test/adapter_postgres_test.rb`를 만든다.

```bash
# 테스트가 사용하는 일회용 컨테이너. 이름에 PID를 넣어 충돌을 막는다.
CID="$(docker run -d --rm \
  --label org.example.workflow-kit.disposable=true \
  -e POSTGRES_PASSWORD=disposable -e POSTGRES_DB=fixture_db \
  -p 127.0.0.1::5432 postgres:16-alpine)"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
# 준비 대기
until docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
PORT="$(docker port "$CID" 5432/tcp | sed -n 's/^127\.0\.0\.1://p')"
# introspection → generated facts
WORKFLOW_KIT_REAL_POSTGRES_TEST=1 \
DISPOSABLE_DATABASE_CONTAINER_ID="$CID" \
DISPOSABLE_DATABASE_URL="postgres://postgres:disposable@127.0.0.1:$PORT/fixture_db" \
  ruby -Itest test/adapter_postgres_integration_test.rb
docker rm -f "$CID"
trap - EXIT
```

21. `[additive]` 검증 항목:
    - 같은 스키마에서 introspection을 2회 실행하면 `content_digest`가 동일하다
    - migration 1건을 적용하면 `content_digest`가 변한다
    - **negative**: 컨테이너가 없으면 introspection이 추측값을 만들지 않고 실패한다
    - **negative**: 접속 URL이 `127.0.0.1`이나 컨테이너가 아니면 거부한다
      (운영 DB 접속 차단. 계획 문서 §14)
    - 수집 결과에 비밀번호, 사용자 데이터, 행 내용이 포함되지 않는다

### 4.7 P2-7. `--dev-source` 제거

22. `[read-only]` [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §7.4의 만료 조건 3개가
    충족되었는지 확인한다.
23. `[mutating: 중앙 kit]` `--dev-source` 옵션과 관련 분기를 제거한다.
    fixture 테스트가 release 경로만으로 통과해야 한다.
24. `[additive]` `evidence/phase2/COMPLETION.md`에 두 release의 digest,
    fixture 목록, 격리 테스트 결과를 기록한다.

## 5. 검증 명령

작업 디렉터리는 승인된 격리 중앙 kit worktree다. 기존 dirty 중앙
checkout에서 이 명령을 실행하지 않는다.

| # | 명령 | 기대 결과 |
|---|---|---|
| V2-1 | `ls -d engine schemas adapters skills vendors fixtures` | 6개 모두 존재 |
| V2-2 | 순서화된 commit 후 `git log --follow --oneline -- engine/install/bootstrap_project.rb` | 이동 전 `installer/bootstrap_project.rb` 이력이 보인다. 후보의 커밋 전 M/D만으로는 통과하지 않는다 |
| V2-3 | `ruby -e 'require "yaml"; YAML.safe_load(File.read("schemas/kit-installation.schema.yaml"))'` | exit 0 |
| V2-4 | `find core/project-template/.ai/runtime/agents/base -type f \| wc -l` | 6 |
| V2-5 | `ruby engine/install/status.rb --json <managed-current fixture>` | `state`가 `current` |
| V2-6 | `ruby engine/install/status.rb --json <managed-drifted fixture>` | `state`가 `current`가 **아니다** |
| V2-7 | `ruby engine/install/status.rb --json <blocked-active fixture>` | `state`가 `blocked`, exit code 30 |
| V2-8 | `ruby -Itest test/fixture_lifecycle_test.rb` | 전부 pass |
| V2-9 | `ruby -Itest test/context_isolation_test.rb` | 전부 pass |
| V2-10 | `ruby -Itest test/adapter_postgres_test.rb` | 전부 pass. Docker 없이 fail-closed 계약 검증 |
| V2-10a | §4.6 일회용 컨테이너로 `ruby -Itest test/adapter_postgres_integration_test.rb` | skip 0, 결정론·migration digest 변화·행/secret 미수집 통과 |
| V2-11 | 두 fixture의 lock에서 `kit_bundle_digest` 추출 후 비교 | 두 값이 다르고 각자 pin과 일치 |
| V2-12 | 실제 release 통합 test의 caller-owned isolated cache 검사 | 실행 중 정확히 두 64-hex payload, 성공/cleanup 뒤 child 0개 |
| V2-13 | alpha 재apply 전후 beta의 `git status --porcelain=v1 -z` bytes와 전체 repository-tree digest 비교 | 두 값 모두 동일 |
| V2-14 | `grep -rn 'dev-source\|dev_source' engine/ installer/ 2>/dev/null` | 출력 없음 |
| V2-15 | `grep -rn 'ALPHA_ONLY_VAR' <beta fixture 실행 로그와 생성물>` | 출력 없음 |
| V2-16 | `rake` | 전체 pass |
| V2-17 | `ruby engine/install/status.rb --json <unknown-project fixture>` | DB/auth/deploy 관련 필드가 추측값 없이 비어 있고 `state`가 `blocked` 또는 `review_required` |
| V2-18 | 격리 무력화 변형에서 `ruby -Itest test/context_isolation_test.rb` | **실패해야 한다**. 통과하면 테스트가 무효다 |

## 6. 종료조건

| # | 종료조건 | 검증 | 계획 문서 대응 |
|---|---|---|---|
| G2-1 | `engine` / `schemas` / `adapters` / `skills` / `vendors` / `fixtures` 구조가 존재하고 이력이 보존되었다 | V2-1, V2-2 | §6 목표 구조 |
| G2-2 | 공통 agent 정의가 kit-owned 경로로 분리되었다 | V2-4 | §8 |
| G2-3 | lock 스키마가 존재하고 검증에 사용된다 | V2-3 | Acceptance #2 |
| G2-4 | legacy와 managed fixture가 plan → apply → validate → status 왕복을 통과한다 | V2-8 | §11 Phase 2 |
| G2-5 | 같은 version의 template drift가 `current`로 판정되지 않는다(fixture 재확인) | V2-6 | Acceptance #4 |
| G2-6 | active stream/lock 상태의 fixture에서 apply가 차단된다 | V2-7 | P0-02 |
| G2-7 | 두 kit 버전을 side-by-side로 실행할 수 있다 | V2-11, V2-12 | §11 Phase 2 |
| G2-8 | 한 fixture apply가 다른 fixture를 변경하지 않는다 | V2-13 | §11 Phase 2 |
| G2-9 | 서로 다른 두 fixture의 DB/API context가 섞이지 않는다. I-1 ~ I-9 전부 통과 | V2-9, V2-15 | Acceptance #11 |
| G2-10 | 격리 테스트가 무력화 변형에서 실제로 실패한다 | V2-18 | 테스트 유효성 |
| G2-11 | unknown project는 fail-closed 된다 | V2-17 | Acceptance #10 |
| G2-12 | disposable PostgreSQL introspection이 결정론적이고 secret을 수집하지 않는다 | V2-10, V2-10a | §7 함수 정보 관리 |
| G2-13 | `--dev-source` 예외가 제거되었다 | V2-14 | [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) §7.4 |
| G2-14 | `rake` 전체가 통과한다 | V2-16 | 회귀 없음 |
| G2-15 | 완료 증거가 기록되었다 | `evidence/phase2/COMPLETION.md` | §4.7 |

## 7. 롤백

| 단계 | 되돌리는 방법 | 되돌릴 수 없는 부분 |
|---|---|---|
| P2-1 경로 이동 | 새 브랜치에서 작업하므로 브랜치 폐기로 원복 | 없음 |
| P2-4 두 번째 tag | `git tag -d`. push하지 않았으므로 로컬 삭제로 충분 | 없음 |
| release cache | caller-owned isolated cache의 exact digest payload와 metadata만 제거하고 root가 빈 상태인지 확인 | 없음 |
| fixture | 임시 디렉터리에 생성되므로 테스트 종료 시 자동 삭제 | 없음 |
| Docker 컨테이너 | `docker rm -f <cid>`. `--rm`으로 실행하므로 정상 종료 시 자동 정리 | 없음 |
| `--dev-source` 제거 | 브랜치 폐기로 원복 | 없음 |

경로 이동은 기존 설치본에 영향을 주는 유일한 변경이다. 그러나 이 phase는 실제
프로젝트에 apply하지 않으므로, 롤백 시점에 영향받는 실제 저장소는 없다.
경로 이동 migration의 실제 적용은 Phase 3의 프로젝트별 PR에서 처음 일어난다.

## 8. 이 phase가 승인하지 않는 작업

[`HARNESS_GOVERNANCE_MIGRATION_PLAN.md`](../../HARNESS_GOVERNANCE_MIGRATION_PLAN.md) §14를
상속한다. Phase 1과 마찬가지로 해제되는 것은 중앙 kit 저장소 수정과 로컬 tag 생성뿐이다.
추가로 다음을 금지한다.

- 실제 프로젝트에 대한 apply, upgrade, 경로 이동 migration 적용
- 운영 PostgreSQL 또는 로컬 개발 DB에 대한 introspection. 대상은 일회용 컨테이너뿐이다
- 컨테이너 외부 host의 DB 포트 접속, `127.0.0.1` 이외 주소 접속
- live provider(X, Instagram, Kakao, OpenAI) 호출
- 중앙 kit tag/브랜치 원격 push, GitHub Release 게시
- `.ai/canonical/agents/**` 기존 파일의 삭제. tombstone 없이 남긴다
- 전역 설정과 hook 변경
- Phase 0 checkpoint 삭제

---
title: 'Phase 4: 명세 최신성 required gate'
phase: 4
project_id: ai-harness-governance-plan
status: reference-template
depends_on: [3]
mutates_project_files: true
---

# Phase 4. 명세 최신성 required gate

> 공개용 절차 템플릿입니다. 실제 프로젝트의 승인·완료 상태는 포함하지 않습니다.

## 1. 목적

코드 경로를 명세와 검증기에 명시적으로 연결하고, 명세 갱신 없이는 merge되지 않게 하며,
검증된 exact SHA가 아니면 배포되지 않게 한다. 사실은 프롬프트가 아니라 코드에서 생성하고
digest로 비교한다.

Phase 5는 이 phase 없이는 불가능하다. 자동화가 만드는 drift PR이 통과할 수 있는지
판정하려면 required gate가 먼저 존재해야 한다.

이 phase의 전제는 hook이 아니다. 실측에서 `core.hooksPath`가 설정된 저장소는 7개 중
3개뿐이다([`INVENTORY`](../INVENTORY_TEMPLATE.md) §5 Δ-04). 따라서 강제는
required CI와 deploy gate에만 의존하도록 설계한다. hook은 있으면 빠른 피드백을 주는
보조 수단이며, 없어도 정책이 성립해야 한다.

## 2. 전제조건

| # | 조건 | 검사 방법 |
|---|---|---|
| P4.pre-1 | Phase 3에서 최소 2개 저장소(트랙 A/B canary)가 `migrated` | [`PHASE_3`](PHASE_3_CANARY_ADOPTION.md) §6.2 G3-11, G3-12 |
| P4.pre-2 | 대상 저장소에 lock과 receipt가 존재 | `.ai/KIT_INSTALLATION.yaml`, `.ai/generated/adoption-receipt.json` |
| P4.pre-3 | Docker disposable PostgreSQL 사용 가능 | `docker info` exit 0 |
| P4.pre-4 | 저장소별 required check 설정 권한 확인 | 조직 ruleset 사용 가능 여부를 저장소별로 확인한다. 불가하면 §4.5의 caller 방식을 쓴다 |
| P4.pre-5 | CODEOWNERS를 설정할 권한 | 저장소 설정 권한 확인 |
| P4.pre-6 | 저장소별 개별 승인 | Phase 3과 동일. 일괄 적용하지 않는다 |

## 3. 산출물

| 산출물 | 경로 | 소유권 |
|---|---|---|
| registry 스키마 | 중앙 kit `schemas/spec-registry.schema.yaml` | kit |
| generated facts 스키마 | 중앙 kit `schemas/generated-facts.schema.yaml` | kit |
| 기본 고위험 감지 규칙 | 중앙 kit `engine/validators/high_risk_paths.yaml` | kit |
| registry 검증기 | 중앙 kit `engine/validators/validate_spec_registry.rb` | kit |
| freshness 검증기 | 중앙 kit `engine/validators/validate_spec_freshness.rb` | kit |
| generated facts 생성기 7종 | 중앙 kit `adapters/**/generate_*.rb` | kit |
| reusable workflow | 중앙 kit `.github/workflows/spec-gate.yml` | kit |
| receipt 스키마 | 중앙 kit `schemas/deploy-receipt.schema.yaml` | kit |
| 프로젝트 registry | 각 저장소 `.ai/SPEC_REGISTRY.yaml` | `project-owned` |
| 프로젝트 generated facts | 각 저장소 `.ai/generated/**` | `generated` |
| 프로젝트 CI caller | 각 저장소 `.github/workflows/agent-workflow-policy.yml` | `merge-owned` |
| CODEOWNERS | 각 저장소 `.github/CODEOWNERS` | `project-owned` |
| deploy receipt | 각 저장소 `.ai/generated/deploy-receipt.json` | `generated` |
| 완료 기록 | 이 계획 저장소 `evidence/phase4/<repo>/COMPLETION.md` | project-owned |

## 4. 실행 절차

### 4.1 P4-1. `SPEC_REGISTRY.yaml`

1. `[additive]` `schemas/spec-registry.schema.yaml`을 만든다. 계획 문서 §9.1의 구조를
   스키마로 고정한다. 필수 필드: `schema_version`, `project_id`, `rules[].id`,
   `rules[].source_globs`, `rules[].canonical_specs`, `rules[].checks`,
   `rules[].impact_policy`. `generated_facts`는 선택이지만, `checks`에
   generated 기반 검사가 있으면 필수다.
2. `[additive]` 저장소별 초기 rule을 작성한다. 아래 경로는 YYYY-MM-DD에 존재를 확인했다.

프로젝트 유형별로 rule을 설계한다. 아래 구조는 합성 예시다.

| 예시 | source globs | 명세 |
|---|---|---|
| sample-api | `src/api/**`, `migrations/**` | API와 데이터 계약 |
| sample-worker | `src/jobs/**`, `src/providers/**` | 재시도와 provider 경계 |
| sample-web | `src/app/**`, `src/components/**` | route와 UI 계약 |

실제 경로·파일 수는 대상 저장소에서 수집한다. 구조가 다른 프로젝트에 같은 rule을
강제로 적용하지 않는다.

3. `[additive]` 예시 registry(sample-web):

```yaml
schema_version: 1
project_id: sample-web
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
  - id: deployment-contract
    source_globs:
      - deploy/**
    canonical_specs:
      - .ai/canonical/runbooks/release.md
    generated_facts:
      - .ai/generated/deploy-inputs.json
    checks:
      - runtime-input-manifest-digest
      - release-wrapper-required
    impact_policy: spec_update_or_approved_no_impact
```

4. `[mutating: 대상 저장소]` registry를 저장소에 추가한다. `project-owned`이므로
   kit이 덮어쓰지 않는다.

### 4.2 P4-2. generated facts 7종

5. `[additive]` 계획 문서 §7의 표대로 생성기를 만든다. 모든 생성기의 출력에
   `source_tree_digest`, `generator_version`, `generated_at`, `content_digest`,
   `source_commit_hint`를 넣는다.

   **`source_commit`을 gate 입력으로 쓰지 않는다.** 파일에 자기 commit SHA를 기록하면
   기록하는 순간 SHA가 바뀌므로 고정점이 없다([`SPEC`](../RELEASE_ARTIFACT_SPEC.md) S-07).
   대신 그 fact가 파생된 코드 경로의 tree digest(SPEC §4.4)를 기록한다.
   `source_commit_hint`는 사람이 읽는 참고값이며 검사하지 않는다.
   `generated_at`도 `content_digest` 계산에서 제외한다.

```json
{
  "generated_schema": 2,
  "rule_id": "database-contract",
  "source_digest_algo": 1,
  "source_tree_digest": "sha256:...",
  "generator_version": "1.0.0",
  "generated_at": "2030-01-01T00:00:00Z",
  "content_digest": "sha256:...",
  "source_commit_hint": "<commit-sha>",
  "facts": {}
}
```

| 사실 | 생성기 | 출력 |
|---|---|---|
| FastAPI route | `adapters/fastapi-alembic/generate_routes.rb` | `.ai/generated/api-routes.json` |
| Next.js route | `adapters/nextjs-typescript/generate_routes.rb` | `.ai/generated/web-routes.json` |
| Python symbol | `adapters/fastapi-alembic/generate_symbols.rb` | `.ai/generated/python-symbols.json` |
| TypeScript export | `adapters/nextjs-typescript/generate_exports.rb` | `.ai/generated/ts-exports.json` |
| DB schema | `adapters/postgresql/generate_schema.rb` | `.ai/generated/database-schema.json` |
| 환경변수 이름 | `adapters/common/generate_env_names.rb` | `.ai/generated/env-names.json` |
| 배포 입력 | `adapters/common/generate_deploy_inputs.rb` | `.ai/generated/deploy-inputs.json` |

6. `[additive]` **secret 미수집 규칙.** 생성기는 이름만 수집하고 값을 수집하지 않는다.
   환경변수는 참조된 이름 목록만, DB는 스키마 구조만, 배포는 manifest digest만 남긴다.
   행 내용, 비밀번호, 토큰, 실제 credential은 어떤 출력에도 포함하지 않는다.
7. `[additive]` **결정론 요건.** 같은 commit에서 2회 생성하면 `content_digest`가 같아야 한다.
   정렬되지 않은 해시 순회, 절대 경로, 시각, 호스트명이 출력에 들어가면 이 요건이 깨진다.

### 4.3 P4-3. 매핑 커버리지 판정

registry가 고위험 판정의 유일한 근거가 되면, registry에서 빠뜨린 경로가 자동으로
"영향 없음"이 된다. 이를 막기 위해 **kit이 registry와 독립적으로 고위험을 감지**한다.

8. `[additive]` `engine/validators/high_risk_paths.yaml`에 기본 감지 규칙을 둔다.
   프로젝트가 이 목록을 축소할 수 없다. 확장만 할 수 있다.

```yaml
schema_version: 1
high_risk_globs:
  - '**/migrations/**'
  - '**/*.sql'
  - 'db/**'
  - '**/lib/db/**'
  - 'deploy/**'
  - '**/auth/**'
  - '**/authz/**'
  - '.github/workflows/**'
  - '**/Dockerfile'
  - '**/docker-compose*.yml'
  - '**/*.tf'
  - '**/secrets*'
```

9. `[additive]` `engine/validators/validate_spec_freshness.rb`의 판정 로직:

```text
changed          := git diff --name-only <base>..<head>
registry         := load(.ai/SPEC_REGISTRY.yaml)
default_high     := load(engine/validators/high_risk_paths.yaml).high_risk_globs
project_high     := registry.additional_high_risk_globs (선택, 축소 불가)
high_risk_globs  := default_high ∪ project_high

for path in changed:
    matched_rules := [r for r in registry.rules if glob_any(r.source_globs, path)]
    is_high       := glob_any(high_risk_globs, path)

    if is_high and matched_rules is empty:
        FAIL "unmapped_high_risk_path: {path}"        # 영향 없음으로 간주하지 않는다

    for r in matched_rules:
        # 재귀 금지 검사. spec 또는 generated fact가 자신의 source_globs에 들어가면
        # 값을 기록하는 순간 digest가 바뀌어 고정점이 사라진다(SPEC §4.4-1, §4.4-2).
        for p in r.canonical_specs + r.generated_facts:
            if glob_any(r.source_globs, p):
                FAIL "self_referencing_rule: rule={r.id} path={p}"

        # 현재 PR head tree에서 rule의 source_globs에 대한 digest를 다시 계산한다.
        actual := source_tree_digest(head_tree, r.source_globs)      # SPEC §4.4

        if r.impact_policy == "spec_update_or_approved_no_impact":
            verified_ok := all(
                read_front_matter(spec).verified_against.source_tree_digest == actual
                for spec in r.canonical_specs
            )
            exemption := read_pr_exemption()          # docs-impact: none 블록
            if not verified_ok and not exemption_valid(exemption, changed):
                FAIL "spec_update_required: rule={r.id}"

        for check in r.checks:
            run_check(check)                          # 실패 시 즉시 FAIL

for gf in registry.all_generated_facts():
    rule       := registry.rule_of(gf)
    actual     := source_tree_digest(head_tree, rule.source_globs)
    regenerated := run_generator(gf)
    if regenerated.content_digest != read(gf).content_digest:
        FAIL "generated_facts_stale: {gf}"
    if read(gf).source_tree_digest != actual:
        FAIL "generated_facts_source_mismatch: {gf}"
```

10. `[additive]` **무의미한 문서 touch가 통과하지 못하는 이유를 두 겹으로 만든다.**
    - 첫째, `verified_against.source_tree_digest`가 **현재 PR head tree에서 재계산한
      값과 정확히 일치**해야 한다. 코드가 한 바이트라도 바뀌면 이 값이 달라지므로
      spec을 갱신하지 않으면 통과할 수 없다. commit SHA를 쓰지 않으므로 §S-07의
      자기참조 역설이 발생하지 않는다. spec 파일 자체는 rule의 `source_globs`에
      포함될 수 없으므로(위 `self_referencing_rule` 검사) spec을 고쳐도 digest는 안정적이다.
    - 둘째, generated facts 검사가 남는다. 문서를 건드려도 `content_digest`는 코드에서
      재생성한 값과 비교되므로, 코드가 바뀌었는데 generated facts를 갱신하지 않으면
      `generated_facts_stale`로 실패한다. 즉 문서 touch는 generated drift를 숨기지 못한다.
    - 두 겹 모두 저장소 안의 값만으로 판정된다. commit SHA와 CI 결과는 §4.7의
      저장소 밖 증거가 담당한다.

### 4.4 P4-4. docs-impact 규칙

11. `[additive]` `docs-impact: none`을 쓰려면 아래를 **모두** 만족해야 한다.
    하나라도 없으면 gate는 실패한다.

| 요건 | 형식 | 이유 |
|---|---|---|
| 구체 사유 | 자유 서술 40자 이상. 템플릿 문구 금지 | 계획 문서 §9.2 |
| change-set digest | `sha256`. 아래 §4.4-12의 계산식 | 다른 PR에서 복사한 면제를 무효화한다 |
| CODEOWNER 승인 | 해당 rule의 CODEOWNER가 PR을 승인 | 사람 책임 고정 |
| 대상 rule id | 면제 대상 rule을 명시 | 전체 면제를 금지한다 |

12. `[additive]` change-set digest 계산식. PR 내용이 한 바이트라도 바뀌면 값이 변한다.

```bash
{ git diff --name-status "$BASE..$HEAD" | LC_ALL=C sort
  git diff "$BASE..$HEAD" | shasum -a 256 | awk '{print $1}'
} | shasum -a 256 | awk '{print $1}'
```

13. `[additive]` PR 템플릿에 `docs-impact` 블록을 **미리 채워두지 않는다.**
    빈 상태로 두고, 기재 시 위 4요건을 모두 요구한다.
14. `[additive]` **negative**: 다른 PR의 면제 블록을 복사해 붙이면
    change-set digest 불일치로 실패한다.

### 4.5 P4-5. required CI

조직 ruleset 권한을 전제하지 않는다. 두 경로를 모두 문서화하고, 사용 가능한 쪽을 쓴다.
저장소별 경로 선택은 D-NEED-09에서 결정한다.

15. `[additive]` 중앙 kit에 reusable workflow `.github/workflows/spec-gate.yml`을 만든다.
    입력: `kit_version`, `kit_bundle_digest`. 수행: lock 검증 → registry 스키마 검증 →
    generated facts 재생성 및 digest 비교 → rule별 checks → docs-impact 판정.
    이 workflow는 Phase 4의 산출물이다. Phase 3의 CI job은 이것을 참조하지 않는다
    ([`PHASE_3`](PHASE_3_CANARY_ADOPTION.md) §4.3-12).
15a. `[additive]` **check-run 이름을 고정한다.** required check는 이름 문자열로 지정되므로
     job 이름이 흔들리면 required 지정이 조용히 깨진다. reusable workflow의 job에
     `name: spec-gate`를 명시하고, 그 이름을 저장소별 기록에 남긴다.
16. `[mutating: 대상 저장소]` 경로 A(조직 ruleset 사용 가능): 중앙 required workflow를
    ruleset에 등록한다. 저장소별 caller는 두지 않는다.
17. `[mutating: 대상 저장소]` 경로 B(ruleset 불가): Phase 3이 넣은 `validate-install` job에
    **`spec-gate` job을 추가**한다. 중앙 reusable workflow를 **exact commit SHA**로 참조한다.
    태그나 브랜치로 참조하지 않는다. `validate-install`은 유지한다.

```yaml
name: agent-workflow-policy
on:
  pull_request:
  push:
    branches: [main]
jobs:
  # Phase 3에서 이미 존재하는 job. 유지한다.
  validate-install:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<40-hex-commit-sha>
      - run: ruby engine/validators/validate_install.rb .

  # Phase 4에서 추가하는 job. required check 이름은 'spec-gate'로 고정한다.
  spec-gate:
    name: spec-gate
    # 태그가 아니라 commit SHA로 고정한다. 중앙 workflow가 바뀌어도 무단으로 따라가지 않는다.
    uses: <org>/ai-agentic-workflow-kit/.github/workflows/spec-gate.yml@<40-hex-commit-sha>
    with:
      kit_version: '0.4.1'
      kit_bundle_digest: 'sha256:...'
```

18. `[mutating: 대상 저장소]` 해당 job을 required check로 지정한다.
    **지정 사실을 화면 확인이 아니라 API 응답으로 증거화한다.** 아래 세 값을 수집해
    `evidence/phase4/<repo>/required-checks.json`에 저장한다.

```bash
# 1) ruleset 적용 여부와 내용
gh api "repos/$OWNER/$REPO/rulesets" > "$EVIDENCE/rulesets.json"
# 2) 브랜치 보호의 required status check 목록
gh api "repos/$OWNER/$REPO/branches/$BASE_BRANCH/protection/required_status_checks" \
  > "$EVIDENCE/required-checks.json"
# 3) 실제로 생성되는 check-run 이름. 위 목록과 문자열이 일치해야 한다.
gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" \
  --jq '.check_runs[].name' | LC_ALL=C sort > "$EVIDENCE/check-run-names.txt"
```

18a. `[read-only]` 2번의 required check 이름 집합이 3번의 실제 check-run 이름 집합에
     포함되는지 확인한다. 포함되지 않으면 required 지정이 실제로는 아무것도 막지 못한다.
19. `[additive]` **hook 우회 검증.** `git commit --no-verify`로 커밋한 PR에서도
    required check가 실패해야 한다(Acceptance #18). hooksPath 미설정 저장소
    4개에서는 애초에 hook이 없으므로 이 경로가 기본값이다.

### 4.6 P4-6. CODEOWNERS

20. `[mutating: 대상 저장소]` `.github/CODEOWNERS`에 최소 다음을 보호한다.

```text
/.ai/SPEC_REGISTRY.yaml      @owner
/.ai/canonical/              @owner
/.ai/KIT_INSTALLATION.yaml   @owner
/.github/workflows/          @owner
```

21. `[additive]` rule별 CODEOWNER를 registry에 기록해, §4.4-11의 승인 주체를 확정한다.

### 4.7 P4-7. deploy receipt와 신뢰 모델

저장소에 커밋된 JSON은 PR 작성자가 편집할 수 있다. 따라서 `required_checks: success`를
그 파일에서 읽으면 **자기주장을 증거로 쓰는 것**이 된다. receipt를 두 층으로 나눈다.

| 층 | 어디에 있는가 | 무엇을 담는가 | 신뢰 근거 |
|---|---|---|---|
| Tier 1 (항상) | 저장소 `.ai/generated/deploy-receipt.json` | digest 입력만. 재계산으로 검증 가능한 값 | 파일을 손으로 고치면 재계산 불일치로 실패한다 |
| Tier 1 (항상) | GitHub API | check-run 결과, PR 승인, base commit | 저장소 파일이 아니라 API 응답 |
| Tier 2 (가용 시) | artifact attestation | **배포 대상 artifact**의 빌드 provenance | 서명 검증 |

22. `[additive]` `schemas/deploy-receipt.schema.yaml`을 만든다. Tier 1 파일에는
    **`code_sha`와 `required_checks`를 넣지 않는다.** 자기참조 금지(SPEC S-07)와
    자기주장 금지 때문이다.

```json
{
  "receipt_schema": 2,
  "kit_version": "0.4.1",
  "kit_bundle_digest": "sha256:...",
  "rendered_install_digest": "sha256:...",
  "spec_registry_digest": "sha256:...",
  "source_digest_algo": 1,
  "rules": [
    { "rule_id": "database-contract", "source_tree_digest": "sha256:..." }
  ],
  "generated_facts": [
    { "path": ".ai/generated/database-schema.json", "content_digest": "sha256:..." }
  ],
  "db_migration": { "head": "...", "checksum": "sha256:..." },
  "project_release_evidence": { "wrapper": "deploy/release.rb", "artifact_digest": "sha256:..." },
  "note": "code SHA와 check 결과는 이 파일에 없다. deploy gate가 API로 조회한다."
}
```

23. `[mutating: 대상 저장소]` **deploy gate는 배포 시점에 API를 조회한다.**
    receipt 파일의 주장을 읽지 않는다.

```bash
# 1) 배포 대상 commit의 check-run 결과를 API에서 직접 확인한다
gh api "repos/$OWNER/$REPO/commits/$DEPLOY_SHA/check-runs" \
  --jq '{check_runs: [.check_runs[] | {name, status, conclusion, head_sha, app: {id: .app.id}}]}' \
  > /tmp/checks.json
# 2) required 목록, exact-SHA check-run, 실제 artifact bytes와 receipt를 함께 검증한다.
#    verifier는 각 required 이름이 정확히 하나이고 completed/success이며 DEPLOY_SHA에
#    결속되고 양수 app.id를 가진 경우만 허용한다.
ruby engine/validators/verify_deploy_receipt.rb \
  --root "$PROJECT_ROOT" \
  --sha "$DEPLOY_SHA" \
  --required-checks "$EVIDENCE/required-checks.json" \
  --check-runs /tmp/checks.json \
  --artifact "$ARTIFACT"
```

23a. `[additive]` **Tier 2.** artifact attestation은 in-repo JSON이 아니라
     **배포 대상 artifact**에 건다. receipt는 그 attestation을 가리키는 포인터만 갖는다.
     도입 여부는 D-NEED-13에서 결정한다. 도입하면 배포 전에 검증까지 수행한다.

```bash
# 빌드 측: 배포 artifact에 provenance를 붙인다
gh attestation verify "$ARTIFACT" --owner "$OWNER"   # 배포 측: 검증까지 해야 효력이 있다
```

24. `[additive]` **negative**: receipt 없이 배포 시도 → 거부.
    **negative**: required check 중 하나가 `failure`인 commit으로 배포 시도 → 거부.
    **negative**: receipt의 digest를 손으로 고쳐 배포 시도 → 재계산 불일치로 거부.
    **negative**: receipt에 `required_checks: success`를 직접 써 넣고 배포 시도 →
    gate가 그 필드를 읽지 않으므로 효과가 없고, 스키마 검증에서 미허용 필드로 거부.
    **negative**: attestation을 도입한 뒤 서명 없는 artifact로 배포 시도 → 거부.
25. `[read-only]` `sample-web`은 전용 `deploy/release.rb`가 있고 raw
    `docker compose`를 배포 증거로 인정하지 않는다(계획 문서 §10.3). receipt의
    `project_release_evidence.wrapper`가 그 wrapper를 가리키는지 검사한다.

### 4.8 P4-8. DB 검증 명령

26. `[additive]` migration checksum과 disposable introspection을 실제 명령으로 고정한다.
    운영 DB에 접속하지 않는다. 컨테이너는 일회용이며 `127.0.0.1`만 허용한다.

```bash
# migration checksum: 파일 내용에서 결정론적으로 계산한다
find db/migrations -type f -name '*.sql' | LC_ALL=C sort | while read -r f; do
  printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"
done | shasum -a 256 | awk '{print $1}'

# disposable introspection
CID="$(docker run -d --rm -e POSTGRES_PASSWORD=disposable -e POSTGRES_DB=gate_db \
  -p 127.0.0.1:0:5432 postgres:16-alpine)"
until docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
PORT="$(docker port "$CID" 5432/tcp | sed 's/.*://')"
# migration 적용 후 스키마만 수집한다. 행 내용은 수집하지 않는다.
ruby adapters/postgresql/generate_schema.rb \
  --url "postgres://postgres:disposable@127.0.0.1:$PORT/gate_db" \
  --out .ai/generated/database-schema.json
docker rm -f "$CID"
```

27. `[additive]` `evidence/phase4/<repo>/COMPLETION.md`에 registry digest,
    generated facts digest 목록, required check 설정 결과, receipt 예시를 기록한다.

## 5. 검증 명령

| # | 명령 | 기대 결과 |
|---|---|---|
| V4-1 | `ruby -ryaml -e 'YAML.safe_load(File.read(".ai/SPEC_REGISTRY.yaml"))'` | exit 0 |
| V4-2 | `ruby "$KIT/engine/validators/validate_spec_registry.rb" .` | exit 0 |
| V4-3 | 각 생성기를 2회 실행해 `content_digest` 비교 | 두 값 동일 |
| V4-4 | 코드 1개 파일을 수정한 뒤 생성기 실행 | 관련 `content_digest`와 `source_tree_digest`가 모두 변한다 |
| V4-4a | `grep -rc '"source_commit"' .ai/generated/` | 0. gate 입력에 자기 commit SHA가 없다(SPEC S-07) |
| V4-5 | `ruby "$KIT/engine/validators/validate_spec_freshness.rb" --base <base> --head <head>` | 정상 PR에서 exit 0 |
| V4-6 | **negative**: 매핑되지 않은 고위험 경로(`db/migrations/new.sql`)만 추가한 PR | `unmapped_high_risk_path`로 실패 |
| V4-7 | **negative**: 코드는 바꾸고 spec의 `source_tree_digest`를 갱신하지 않은 PR | `spec_update_required`로 실패 |
| V4-7a | **negative**: spec 파일을 자신의 rule `source_globs`에 포함시킨 registry | `self_referencing_rule`로 실패 (SPEC VR-17) |
| V4-7b | 코드와 spec을 같은 commit에서 함께 갱신한 PR | 통과한다. commit SHA를 쓰지 않으므로 자기참조 역설이 없다 |
| V4-8 | **negative**: 코드를 바꾸고 generated facts를 갱신하지 않은 PR | `generated_facts_stale` 또는 `generated_facts_source_mismatch`로 실패 |
| V4-9 | **negative**: 문서에 공백만 추가하고 digest 필드만 갱신한 PR | generated facts 검사로 실패 |
| V4-10 | **negative**: 다른 PR의 `docs-impact: none` 블록을 복사한 PR | change-set digest 불일치로 실패 |
| V4-11 | **negative**: CODEOWNER 승인 없는 `docs-impact: none` PR | 실패 |
| V4-12 | **negative**: `git commit --no-verify`로 만든 위반 PR | required check가 실패한다 (Acceptance #18) |
| V4-13 | `grep -oE 'spec-gate\.yml@[0-9a-f]{40}' .github/workflows/agent-workflow-policy.yml` | 40자 hex SHA 참조가 나온다. 태그·브랜치 참조는 실패 |
| V4-13a | `gh api "repos/$OWNER/$REPO/rulesets"` | 적용된 ruleset이 응답에 있다. 경로 A를 택한 경우 필수 |
| V4-13b | `gh api ".../branches/$BASE/protection/required_status_checks" --jq '.contexts'`와 `gh api ".../commits/$SHA/check-runs" --jq '.check_runs[].name'` 비교 | required 이름 집합이 실제 check-run 이름 집합에 **포함된다**. 포함되지 않으면 required 지정이 무효다 |
| V4-13c | `grep -c 'name: spec-gate' <reusable workflow>` | 1 이상. check-run 이름이 고정되어 있다 |
| V4-13d | `grep -c 'validate-install' .github/workflows/agent-workflow-policy.yml` | 1 이상. Phase 3 job이 유지되었다 |
| V4-14 | `ruby -rjson -e 'JSON.parse(File.read(".ai/generated/deploy-receipt.json"))'` | exit 0, 스키마 검증 통과 |
| V4-14a | `grep -cE '"(code_sha\|required_checks)"' .ai/generated/deploy-receipt.json` | 0. 자기참조와 자기주장 필드가 없다 |
| V4-15 | **negative**: receipt 없이 deploy gate 실행 | 거부 |
| V4-16 | **negative**: required check 하나가 `failure`인 commit으로 deploy gate 실행 | 거부. 판정 근거는 API 응답이다 |
| V4-16a | **negative**: receipt의 digest를 손으로 고쳐 deploy gate 실행 | 재계산 불일치로 거부 |
| V4-16b | **negative**: receipt에 `required_checks: success`를 넣어 deploy gate 실행 | 스키마 미허용 필드로 거부. gate는 그 값을 읽지 않는다 |
| V4-17 | migration checksum 명령을 2회 실행 | 두 값 동일 |
| V4-18 | migration 1건 추가 후 checksum | 값이 변한다 |
| V4-19 | `grep -rniE '(password\|secret\|token)["'\'']?\s*[:=]' .ai/generated/` | 실제 값이 없다. 이름만 존재 |
| V4-20 | `docker ps -a --filter name=gate --format '{{.Names}}'` | 테스트 후 출력 없음(일회용 컨테이너 정리 확인) |
| V4-21 | `grep -rniE 'memsearch\|obsidian\|\.memsearch' "$KIT/engine/validators/" "$KIT/.github/workflows/spec-gate.yml"` | 출력 없음. gate 입력에 기억 계층이 포함되지 않는다 |
| V4-22 | **negative**: canonical spec과 MemSearch 기록이 충돌하는 상황을 만든 뒤 gate 실행 | gate 판정이 canonical spec과 generated facts만으로 결정된다. 기억이 판정을 바꾸지 않는다 |

## 6. 종료조건

| # | 종료조건 | 검증 | 계획 문서 대응 |
|---|---|---|---|
| G4-1 | 대상 저장소에 `SPEC_REGISTRY.yaml`이 존재하고 스키마를 통과한다 | V4-1, V4-2 | §9.1 |
| G4-2 | 고위험 source glob이 최소 하나의 canonical 또는 generated contract에 연결된다 | V4-5, V4-6 | Acceptance #8 |
| G4-3 | 매핑되지 않은 고위험 경로가 "영향 없음"으로 통과하지 않는다 | V4-6 | §9.1 |
| G4-4 | route/API/DB/generated fact가 현재 tree와 digest가 일치한다 | V4-3, V4-4, V4-4a, V4-8 | Acceptance #9 (§12.1 해석 주석 참조) |
| G4-4a | 저장소 파일이 자기 commit SHA를 참조하지 않는다 | V4-4a, V4-14a | [`SPEC`](../RELEASE_ARTIFACT_SPEC.md) S-07 |
| G4-4b | spec 또는 generated fact가 자신의 `source_globs`에 포함되면 `invalid`다 | V4-7a | SPEC §4.4 |
| G4-5 | spec 갱신 또는 승인된 `docs-impact:none` 없이는 merge되지 않는다 | V4-7, V4-7b, V4-11 | Acceptance #12 |
| G4-6 | 의미 없는 문서 touch만으로 generated drift를 숨길 수 없다 | V4-9 | §9.2 |
| G4-7 | 면제 블록을 재사용할 수 없다 | V4-10 | §9.2 |
| G4-8 | required check가 저장소에 설정되었고 **API 증거로 확인되었다** | V4-13, V4-13a, V4-13b, V4-13c | §9.3 |
| G4-8a | Phase 3의 `validate-install` job이 유지되면서 `spec-gate`가 추가되었다 | V4-13d | phase 의존 순서 |
| G4-9 | hook을 우회해도 required CI가 위반을 막는다 | V4-12 | Acceptance #18 |
| G4-10 | 검증된 SHA가 아니면 deploy가 거부되고, 판정 근거가 저장소 파일이 아니다 | V4-14, V4-14a, V4-15, V4-16, V4-16a, V4-16b | Acceptance #13 |
| G4-11 | migration checksum과 disposable introspection이 결정론적이다 | V4-17, V4-18 | §9.1 checks |
| G4-12 | generated facts에 secret 값과 운영 credential이 없다 | V4-19 | §7 |
| G4-13 | 일회용 DB 컨테이너가 정리되고 운영 DB에 접속하지 않았다 | V4-20 | §14 |
| G4-14 | 불완전한 `PROJECT_MAP`에서 DB/auth/deploy 작업이 fail-closed 된다 | Phase 2 V2-17 재확인 | Acceptance #10 |
| G4-15 | 완료 증거가 저장소별로 기록되었다 | `evidence/phase4/<repo>/COMPLETION.md` | §4.8 |
| G4-16 | MemSearch/Obsidian의 기억이 gate 판정에 입력되지 않는다 | V4-21, V4-22 | Acceptance #14, D-05 |

## 7. 롤백

| 상황 | 되돌리는 방법 |
|---|---|
| registry가 잘못된 경우 | `project-owned`이므로 저장소 커밋을 revert한다. kit은 덮어쓰지 않는다 |
| gate가 정상 PR을 막는 경우 | required check 지정을 일시 해제하지 않는다. 대신 `high_risk_paths.yaml` 또는 rule을 수정하는 PR을 먼저 merge한다. 해제는 우회 습관을 만든다 |
| generated facts가 잘못 생성된 경우 | 생성기 버전을 올려 재생성한다. `generator_version`이 바뀌면 digest도 바뀌므로 추적된다 |
| caller의 SHA 참조가 잘못된 경우 | caller 파일만 수정하는 PR로 교체한다 |
| receipt 스키마 변경 | `receipt_schema` 번호를 올린다. 기존 receipt를 다시 쓰지 않는다 |
| deploy gate 오작동 | 배포를 중단한다. gate를 우회해 배포하지 않는다 |

되돌릴 수 없는 단계는 없다. 단 required check를 해제하는 방식의 롤백은 금지한다.
gate 자체가 이 phase의 산출물이므로, 해제는 롤백이 아니라 phase 실패다.

## 8. 이 phase가 승인하지 않는 작업

[`HARNESS_GOVERNANCE_MIGRATION_PLAN.md`](../../HARNESS_GOVERNANCE_MIGRATION_PLAN.md) §14에서
이 phase가 해제하는 것은 **승인된 저장소의 `SPEC_REGISTRY`, `.ai/generated/**`,
CI caller, CODEOWNERS 추가**뿐이다. 다음은 금지된다.

- production DB 접속. 대상은 일회용 컨테이너뿐이다
- `127.0.0.1` 이외 주소의 DB 포트 접속
- live provider(X, Instagram, Kakao, OpenAI) 호출
- 실제 배포 실행. 이 phase는 deploy gate를 만들지만 배포하지 않는다
- required check의 일시 해제 또는 관리자 권한 우회 merge
- generated facts에 값(비밀번호, 토큰, 행 내용) 수집
- application business code 수정
- 여러 저장소 일괄 적용. 저장소별 승인이 필요하다
- nested clone 삭제
- 전역 설정과 hook 활성화 변경

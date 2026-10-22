# AI Harness Governance Plan

여러 저장소에 공통 AI 개발 하네스를 안전하게 적용하기 위한 설계 자료와 checkpoint 도구입니다.

- [거버넌스 계획](HARNESS_GOVERNANCE_MIGRATION_PLAN.md): 소유권, 정체성, 명세, 검증 원칙
- [인벤토리 템플릿](docs/INVENTORY_TEMPLATE.md): 적용 환경에서 수집할 정보
- [릴리스와 digest 명세](docs/RELEASE_ARTIFACT_SPEC.md): 불변 artifact와 plan/apply 결속
- [Phase 문서 규칙](docs/TEMPLATE_PHASE.md): 절차, 검증, 롤백 형식
- [실행 증거 관리](evidence/README.md): 공개 자료와 비공개 운영 기록의 경계

이 배포본은 실제 프로젝트의 인벤토리, 개인 MCP 설정, credential, 실행 로그와 승인 이력을
포함하지 않습니다. `sample-*` 프로젝트, 날짜와 경로는 설명용 예시입니다. `<commit-sha>`,
`<baseline-sha>`, `<sha256>`, `$WORKSPACE` 등은 적용 환경에서 정해야 하는 값입니다.
문서에 적힌 검증 절차는 실행 완료를 뜻하지 않습니다.

## Checkpoint 도구

Ruby 2.6 이상과 Git이 필요합니다. 명령의 옵션을 확인한 뒤 승인된 대상에서 실행합니다.

```sh
ruby bin/dirty-snapshot --help
ruby bin/harness-checkpoint --help
rake
```

checkpoint archive는 미커밋 파일과 credential을 포함할 수 있습니다. 저장소 밖의
접근 제한된 경로에 보관하고, 실제 실행 증거를 이 공개 저장소에 추가하지 마세요.

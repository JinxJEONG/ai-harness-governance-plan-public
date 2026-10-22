---
title: Project inventory template
project_id: ai-harness-governance-plan
status: reference-template
---

# 적용 전 인벤토리 템플릿

이 문서는 수집 형식입니다. 실제 값을 채운 사본은 비공개로 보관합니다.

## 1. 수집 범위

승인된 프로젝트만 열거하고 별도 worktree와 독립 저장소를 구분합니다.
공개 문서에서는 개인 절대경로 대신 논리적 프로젝트 ID를 사용합니다.

## 2. 수집 방법

```sh
git -C "$PROJECT_ROOT" branch --show-current
git -C "$PROJECT_ROOT" rev-parse HEAD
git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all
git -C "$PROJECT_ROOT" worktree list
git -C "$PROJECT_ROOT" config --get core.hooksPath
```

결과에는 파일명과 작업 맥락이 포함됩니다. 터미널 출력과 원본 결과도 비공개 증거로 취급합니다.
키·토큰·DB URL의 값은 수집하지 않습니다.

## 3. 중앙 kit

VERSION, annotated tag, commit, artifact digest, working-tree 상태를 기록합니다.
과거 실행 기록이나 문서에 적힌 버전을 현재 설치의 증거로 사용하지 않습니다.

## 4. 프로젝트별 상태

| 프로젝트 ID | branch / HEAD | 변경 범위 | 설치 상태 | active work / lock | nested clone |
|---|---|---|---|---|---|
| sample-api | 실행 시 수집 | 실행 시 검토 | managed 또는 legacy | 실행 시 확인 | 실행 시 확인 |
| sample-web | 실행 시 수집 | 실행 시 검토 | managed 또는 legacy | 실행 시 확인 | 실행 시 확인 |

위 ID는 가상 예시이며 실제 조직의 저장소 목록이 아닙니다.

## 5. 이전 기준선과의 차이

HEAD, branch, dirty content digest, semantic index와 worktree 목록을 비교합니다.
drift가 있으면 현재 입력을 다시 검토한 뒤 새 plan을 만듭니다.

## 6. 미결 결정

active lock의 소유자, 미검토 파일의 처리, provider 접근 범위, 배포 권한을 기록합니다.
알 수 없는 상태는 추정으로 채우지 않습니다.

## 7. 분류

| 상태 | 기준 |
|---|---|
| migrated | 승인된 release 적용과 필수 검증을 완료 |
| deferred | 진행 중 작업, 미검토 변경 또는 불충분한 증거가 있음 |
| excluded | 이번 적용 범위 밖이며 이유가 명확함 |

프로젝트별 근거와 다음 확인자를 비공개 기록에 남깁니다.

## 8. 재검사

적용 직전에 동일한 수집 명령을 다시 실행합니다. checkpoint 복원과 archive 권한을
검증하고, 승인된 입력과 달라졌다면 apply를 중지합니다.

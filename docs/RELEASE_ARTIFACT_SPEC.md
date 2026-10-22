---
title: Release Artifact and Digest Specification
project_id: ai-harness-governance-plan
status: reference-template
revision: 9
scope: kit_bundle_digest, rendered_install_digest, source_tree_digest, dirty_snapshot_digest, plan_digest, release manifest, source 추상화
implements: 'HARNESS_GOVERNANCE_MIGRATION_PLAN.md §5 P0-03, P0-04'
---

# Release Artifact 및 Digest 명세

이 문서는 Phase 0과 [`PHASE_1`](phases/PHASE_1_RELEASE_INTEGRITY.md)이 공유하는 digest
계약과 release artifact의 정의를 확정한다. Phase 0은 이 계획 저장소의 독립 구현을,
Phase 1은 중앙 kit runtime 구현을 사용하며 서로의 미래 경로를 호출하지 않는다.

공개본은 현재 digest 계약과 이전 형식의 호환성 원칙을 설명한다.
알고리즘 번호는 저장된 데이터와의 호환성을 위해 유지한다. 특정 조직의 실행 시각,
승인 내역, checkpoint 목록과 완료 증거는 포함하지 않는다.

## 1. 설계 원칙

| # | 원칙 |
|---|---|
| S-01 | **식별자는 전송 방식과 분리한다.** release의 정체성은 내용에서 파생되며, tarball이나 URL에 의존하지 않는다. |
| S-02 | **정체성 계산에 tar를 쓰지 않는다.** tar 구현체(bsdtar/GNU tar), mtime, uid/gid, 압축 수준에 따라 바이트가 달라지므로 정체성의 근거로 부적합하다. tarball은 전송 수단이며 별도 checksum을 갖는다. |
| S-03 | **로컬과 원격이 같은 식별자를 만든다.** 같은 tag에서 로컬로 만든 release와 GitHub Release로 게시한 release는 `kit_bundle_digest`가 같아야 한다. |
| S-04 | **날짜와 프로젝트에 무관하다.** `kit_bundle_digest`에는 시각, 호스트명, 프로젝트 경로가 들어가지 않는다. |
| S-05 | **fail-closed.** digest를 계산할 수 없거나 비교 대상이 없으면 `current`가 아니라 `blocked`다. |
| S-06 | **조용한 실패를 금지한다.** 거부 조건을 만나면 부분 결과를 내보내지 않고 0이 아닌 종료 코드로 끝낸다. 규범 구현은 이 요건을 만족해야 한다(§3.2). |
| S-07 | **파일에 기록되는 값은 그 파일이 속한 commit의 SHA를 참조하지 않는다.** commit SHA를 파일에 쓰면 SHA가 다시 바뀌므로 고정점이 없다. 저장소 안에서는 tree digest를, commit SHA와 CI 결과는 저장소 밖 증거에 기록한다(§4.4). |

## 2. digest 종류

| 이름 | 무엇의 digest인가 | 언제 계산하는가 | 변동 요인 |
|---|---|---|---|
| `kit_bundle_digest` | 중앙 kit release의 내용 | release 생성 시 1회. 이후 불변 | kit 내용만 |
| `rendered_install_digest` | 특정 프로젝트에 렌더링된 결과 | 프로젝트별 plan/apply 시 | kit 내용 + 프로젝트 토큰 + profile |
| `source_tree_digest` | registry rule이 지정한 코드 경로의 내용 | spec 갱신 시, gate 실행 시 | 해당 경로의 내용만 |
| `dirty_snapshot_digest` | 대상 worktree의 미커밋 상태 내용 | checkpoint는 전체 scope, plan/apply는 plan scope | tracked 수정 + staged + untracked의 실제 바이트 |
| `plan_digest` | plan의 입력·출력 전체 | plan 생성 시. apply가 재검증 | 위 전부 + target HEAD + 파일별 상태 + action |

다섯 값은 서로 대체할 수 없다. `installer/status.rb`가 `current`를 판정할 때는
`kit_version`, `schema_version`, `kit_bundle_digest`, `rendered_install_digest`,
managed file digest, plan counts, active lock/stream을 **모두** 본다(계획 문서 §5 P0-02).

## 3. `kit_bundle_digest`

### 3.1 계산 대상

release ref(`<tag>`)의 **git tree**에서 파생한다. working tree를 읽지 않는다.
따라서 checkout이 dirty해도 값이 흔들리지 않는다.

포함: ref tree의 모든 blob 중 §3.1의 제외 목록에 해당하지 않는 것.

제외 목록:

| 경로 패턴 | 제외 이유 |
|---|---|
| `.github/**` | 중앙 저장소의 CI 설정. 배포되는 kit 내용이 아니다 |
| `.gitignore` | 저장소 운영 파일 |
| `.memsearch/**` | 생성된 로컬 인덱스 상태 |
| `test/**` | release artifact에 포함하지 않는다. §3.5의 부속 digest로 별도 기록한다 |
| `.git/**` | tree에 존재하지 않으므로 자동 제외 |

제외 목록은 release manifest에 그대로 기록한다. 목록이 바뀌면 `kit_bundle_digest`가
바뀌므로 breaking change로 취급하고 `bundle_digest_algo` 번호를 올린다.

### 3.2 알고리즘 `bundle_digest_algo: 2`와 규범 구현

```text
for each blob in tree(ref) that passes the exclusion filter:
    refuse and exit 3 if mode is not 100644 or 100755
    row = [<path bytes>, <sha256(content)>, <git mode>]
sort rows by the byte sequence of <path>
material = domain_separator + algo + row_count
for each field: material += decimal_byte_length(field) + ":" + field
kit_bundle_digest = sha256(material)
```

- `sha256(content)`: 파일 내용의 SHA-256. git object id(SHA-1)를 쓰지 않는다.
- `<git mode>`: `100644` 또는 `100755`. 실행 권한 차이는 digest에 반영된다.
- `<path>`: repository root 기준 상대 경로.
- 정렬 키는 **경로 바이트열**이다.
- 모든 가변 길이 필드는 십진 byte-length prefix로 frame한다. 공백·탭·개행이 경로에
  포함되어도 서로 다른 tree가 같은 byte stream으로 직렬화되지 않는다.
- domain separator, 알고리즘 번호, row count도 material에 포함한다.
- mtime, uid, gid, 압축, 디렉터리 항목은 계산에 들어가지 않는다.
- symlink(`120000`)와 submodule(`160000`)이 선택 집합에 있으면 **거부하고 종료 코드 3**을 반환한다.

**규범 구현은 Ruby다.** 파일 경로는 NUL로 구분해 읽는다(`git ls-tree -r -z`).
shell 파이프라인 변형은 사용하지 않는다. 이유는 §3.2.1에 있다.

```ruby
# engine/release/release_digest.rb (요지)
require "digest"
require "open3"

EXIT_REFUSED = 3
DEFAULT_EXCLUDES = [".github/**", ".gitignore", ".memsearch/**", "test/**"].freeze

class RefusedEntry < StandardError; end

def capture_binary(*args)
  stdout, stderr, status = Open3.capture3(*args, binmode: true)
  raise "git failed: #{stderr}" unless status.success?
  stdout
end

def glob_match?(pattern, path)
  return true if pattern.end_with?("/**") && path.start_with?(pattern.delete_suffix("**"))
  File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
    File.fnmatch?(pattern, path, File::FNM_DOTMATCH)
end

# NUL 구분으로 읽는다. 경로에 공백, 개행, 비ASCII가 있어도 안전하다.
def tree_entries(kit, ref)
  capture_binary("git", "-C", kit, "ls-tree", "-r", "-z", ref)
    .split("\0").reject(&:empty?).map do |record|
      meta, path = record.split("\t", 2)
      mode, type, oid = meta.split(" ", 3)
      { mode: mode, type: type, oid: oid, path: path.dup.force_encoding(Encoding::BINARY) }
    end
end

def kit_bundle_digest(kit, ref, includes: nil, excludes: DEFAULT_EXCLUDES)
  selected = tree_entries(kit, ref).reject { |e| excludes.any? { |g| glob_match?(g, e[:path]) } }
  selected = selected.select { |e| includes.any? { |g| glob_match?(g, e[:path]) } } if includes

  # 부분 결과를 내보내지 않는다. 첫 위반에서 예외를 던진다(S-06).
  selected.each do |e|
    next if %w[100644 100755].include?(e[:mode])
    raise RefusedEntry, "non-regular entry: mode=#{e[:mode]} path=#{e[:path]}"
  end

  rows = selected.map do |e|
    content = capture_binary("git", "-C", kit, "cat-file", "blob", e[:oid])
    [e[:path], Digest::SHA256.hexdigest(content), e[:mode]]
  end

  rows.sort_by! { |path, _digest, _mode| path }
  material = +"workflow-kit-bundle-digest\\0".b
  material << "2\\0#{rows.length}\\0".b
  rows.each do |path, digest, mode|
    [path, mode.b, digest.b].each do |field|
      material << field.bytesize.to_s.b << ":".b << field
    end
  end
  Digest::SHA256.hexdigest(material)
end
```

호출부는 `RefusedEntry`를 잡아 `exit 3`으로 끝낸다. Ruby 2.6에서도 동작해야 한다
(선행 점 메서드 체인을 주석과 함께 쓰지 않는다. 최소 지원 Ruby 버전에서도 확인한다).

### 3.2.1 algo 1 퇴역과 shell 파이프라인 변형을 금지하는 이유

revision 1의 shell 참조 구현은 두 가지 결함이 있었다. YYYY-MM-DD에 재현했다.

symlink를 포함한 tree에 적용한 결과:

```text
$ kit_bundle_digest   # while 루프 안의 `return 3` 사용
REFUSE: non-regular entry link.txt
exit status = 0  digest = <sha256>
```

- `while` 루프가 파이프라인의 서브셸에서 돌기 때문에 `return 3`이 최종 종료 코드에 반영되지 않았다.
- 그 결과 루프가 위반 지점에서 중단되어 **뒤따르는 파일이 빠진 잘못된 digest가 종료 코드 0으로
  생성되었다.** 조용한 오답이므로 종료 코드 소실보다 위험하다.
- `LC_ALL=C sort`가 행 전체를 정렬하므로 정렬 키가 digest 필드가 되어 규범 텍스트와 불일치했다.
- `IFS=$'\t' read`는 개행이 포함된 경로를 처리하지 못한다.

revision 3까지의 Ruby algo 1도 `<digest> <mode> <path>\n`을 구분자만으로 이어 붙여
injective하지 않았다. YYYY-MM-DD 다음 두 tree가 같은 digest가 되는 것을 재현했다.

- tree A: 내용 A인 파일 경로가 `a\n<sha256(B)> 100644 b`
- tree B: 내용 A인 `a`와 내용 B인 `b`

따라서 release 전 알고리즘을 2로 올리고 length-prefix framing과 row count를 도입했다.
algo 1 digest는 release/lock/cache 신뢰값으로 사용하지 않는다.

같은 조건에서 §3.2의 Ruby 구현은 `REFUSED: non-regular entry: mode=120000 path=l.txt`를
출력하고 종료 코드 3을 반환한다. 부분 결과를 내보내지 않는다.

### 3.3 재현성 검증

같은 tag를 반복 빌드하고, 별도 clone, dirty working tree 및 archive round-trip에서
정체성 digest가 일치하는지 확인한다. symlink·submodule 등 허용하지 않는 항목은
부분 결과 없이 거부해야 한다. 검증 결과는 해당 release의 비공개 실행 기록에 보관한다.
공개본에는 실제 조직의 artifact·commit·운영 완료 내역을 포함하지 않는다.

### 3.4 tarball은 정체성이 아니다

전송용 tarball은 다음 규칙으로 만든다. 그 checksum은 `source` 블록에만 기록한다.

```bash
git -C "$KIT" archive --format=tar --prefix="ai-agentic-workflow-kit-$VERSION/" "$REF" \
  | gzip -n > "ai-agentic-workflow-kit-$VERSION.tar.gz"
shasum -a 256 "ai-agentic-workflow-kit-$VERSION.tar.gz" > "ai-agentic-workflow-kit-$VERSION.tar.gz.sha256"
```

`gzip -n`은 gzip 헤더에서 원본 파일명과 타임스탬프를 제거한다. 그럼에도 tar 구현체
차이로 바이트가 달라질 수 있으므로, **소비자는 tarball checksum이 아니라 압축 해제 후
계산한 `kit_bundle_digest`로 정체성을 검증한다.** tarball checksum은 다운로드 손상
탐지에만 쓴다.

`git archive`의 출력에는 제외 목록이 적용되지 않는다. 따라서 tarball에는 §3.1에서
제외한 경로가 포함되고, 소비자는 압축 해제 후 제외 목록을 적용해 digest를 계산한다.
제외 목록은 release manifest(§5)가 제공한다. VR-4가 이 왕복을 검증한다.

### 3.5 부속 digest

부속 digest는 §3.2 알고리즘을 경로 부분집합에 적용해 계산한다. 이때 §3.1 기본 제외
목록을 적용하지 않고 지정한 include glob만 쓴다.

| 이름 | 대상 glob | 용도 |
|---|---|---|
| `template_tree_digest` | `core/project-template/**` | 같은 `kit_version`에서 template만 바뀐 drift 감지(Acceptance #4) |
| `engine_digest` | `installer/**`(Phase 2 이후 `engine/**`) | 실행 로직 변경 감지. Phase 1의 최종 tag 판정에 쓴다 |
| `test_tree_digest` | `test/**` | release에 포함하지 않지만 재현 검증용으로 기록 |
| `bundle_archive_sha256` | tarball 바이트 | 다운로드 손상 탐지 |

## 4. `rendered_install_digest`와 `source_tree_digest`

### 4.1 `rendered_install_digest` 계산 대상

특정 프로젝트에 대해 렌더링한 결과 파일 집합. `bootstrap_project.rb`의
`render_template`이 토큰을 치환한 뒤의 내용이다. 디스크에 쓰기 전에 계산할 수 있어야 한다.

### 4.2 알고리즘 `rendered_digest_algo: 2`

```text
for each rendered file:
    row = [<target relative path>, <sha256(rendered content)>, <mode>, <ownership>]
sort rows by the byte sequence of <target relative path>
material = domain_separator + algo + row_count
for each field: material += decimal_byte_length(field) + ":" + field
rendered_install_digest = sha256(material)
```

`<ownership>`은 `kit-owned` / `merge-owned` / `project-owned` / `generated` 중 하나다.
소유권 판정이 apply 동작을 결정하므로 정체성에 포함한다.

`project-owned`와 `generated` 파일은 렌더링 대상이 아니므로 이 digest에 들어가지 않는다.
들어가는 것은 `kit-owned`와 `merge-owned`의 렌더링 결과뿐이다.

### 4.3 결정론 요건

같은 `kit_bundle_digest` + 같은 프로젝트 토큰 집합 + 같은 profile에서는 항상 같은
`rendered_install_digest`가 나와야 한다. 아래가 렌더링 결과에 들어가면 요건이 깨진다.
Phase 1은 이들이 포함되지 않음을 테스트로 확인한다.

- 현재 시각, 타임존
- 호스트명, 사용자명
- 절대 경로(프로젝트 root의 절대 경로 포함)
- 난수, UUID
- 환경변수 값

`installed_at`, `updated_at`, `workspace_root`는 `KIT_INSTALLATION.yaml`에만 두고
digest 계산에서 제외한다. 제외 필드 목록을 manifest에 명시한다.
현재 코드가 manifest에 쓰는 `workspace_root`는 절대 경로이므로 반드시 제외 대상이다.

### 4.4 `source_tree_digest` (`source_digest_algo: 1`)

S-07을 만족시키기 위한 값이다. canonical spec과 generated facts가 "무엇에 대해
검증되었는지"를 commit SHA 대신 이 값으로 기록한다.

```text
source_tree_digest(rule) = kit_bundle_digest 알고리즘을
                           include = rule.source_globs,
                           exclude = []
                           로 적용한 값 (§3.2)
```

계산 대상은 PR head **tree**이며 working tree가 아니다. gate는 실행 시점에 이 값을
다시 계산해 spec front matter의 값과 비교한다.

제약 두 가지를 반드시 지킨다.

1. **spec 파일 자신이 그 rule의 `source_globs`에 포함되면 안 된다.** 포함되면 값을
   기록하는 순간 digest가 바뀌어 §S-07의 역설이 재발한다. registry 검증기가 이 조건을
   검사하고, 위반이면 `invalid`로 판정한다.
2. `generated_facts` 파일도 자신의 rule의 `source_globs`에 포함되면 안 된다.

기록 형식:

```yaml
# .ai/canonical/contracts/database.md 의 front matter
verified_against:
  rule_id: database-contract
  source_digest_algo: 1
  source_tree_digest: 'sha256:...'
  # commit SHA는 gate 검사 대상이 아니다. 사람이 읽는 힌트로만 둔다.
  source_commit_hint: '<commit-sha>'
```

generated facts도 같은 방식이다. `source_commit`은 `source_commit_hint`로 이름을 바꾸고
gate 입력에서 제외한다. gate가 보는 값은 `content_digest`와 `source_tree_digest`다.

## 5. `release-manifest.json`은 sidecar다

manifest는 **tarball 안이 아니라 tarball 옆에 둔다.** tarball은 `git archive`로 tag tree에서
생성되므로(§3.4) 생성 시점에 만들어지는 manifest를 담을 수 없다.

release 산출물 3종:

```text
ai-agentic-workflow-kit-<ver>.tar.gz          # 전송용 아카이브
ai-agentic-workflow-kit-<ver>.tar.gz.sha256   # 손상 탐지용
ai-agentic-workflow-kit-<ver>.manifest.json   # release manifest (sidecar)
```

로컬 publisher는 이 3종을 차례로 staging한 뒤, 숨김 completion marker를 **마지막에**
원자적으로 rename한다. `verify`는 marker에 기록된 세 파일의 이름과 SHA-256이 현재
bytes와 모두 일치할 때만 산출물 세트를 읽는다. 따라서 프로세스 중단으로 일부 파일만
교체된 output directory는 release로 인정되지 않는다. 이 marker는 게시 산출물의 네 번째
정체성이 아니라 로컬 publish transaction의 완료 표식이며, 소비자 신뢰근거는 여전히
독립적으로 고정한 manifest digest, archive checksum, 압축 해제 후 bundle digest다.

스키마:

```json
{
  "manifest_schema": 2,
  "kit_version": "0.4.0",
  "release_ref": "refs/tags/v0.4.0",
  "release_commit": "<commit-sha>",
  "channel": "stable",
  "pinnable": true,
  "created_at": "2030-01-01T00:00:00Z",
  "bundle_digest_algo": 2,
  "kit_bundle_digest": "sha256:...",
  "excluded_paths": [".github/**", ".gitignore", ".memsearch/**", "test/**"],
  "auxiliary_digests": {
    "template_tree_digest": "sha256:...",
    "engine_digest": "sha256:...",
    "test_tree_digest": "sha256:..."
  },
  "rendered_digest_algo": 2,
  "source_digest_algo": 1,
  "dirty_snapshot_algo": 4,
  "rendered_digest_excluded_fields": ["installed_at", "updated_at", "workspace_root"],
  "manifest_schema_version_supported": [1, 2],
  "tombstones": [],
  "ownership_rules": [
    { "glob": ".ai/runtime/**", "ownership": "kit-owned" },
    { "glob": ".ai/SPEC_REGISTRY.yaml", "ownership": "project-owned" },
    { "glob": ".ai/project/**", "ownership": "project-owned" },
    { "glob": ".ai/canonical/**", "ownership": "project-owned" },
    { "glob": ".ai/tasks/**", "ownership": "project-owned" },
    { "glob": ".ai/local/**", "ownership": "project-owned" },
    { "glob": ".ai/generated/**", "ownership": "generated" },
    { "glob": ".github/CODEOWNERS", "ownership": "project-owned" },
    { "glob": ".github/workflows/agent-workflow-policy.yml", "ownership": "merge-owned" },
    { "glob": "AGENTS.md", "ownership": "merge-owned" }
  ],
  "protected_paths": [
    ".ai/SPEC_REGISTRY.yaml",
    ".ai/tasks/**",
    ".ai/canonical/**",
    ".ai/local/**",
    ".github/CODEOWNERS"
  ],
  "approval_required_paths": ["AGENTS.md", ".github/workflows/agent-workflow-policy.yml"],
  "source": {
    "kind": "local",
    "locator": "file://$WORKSPACE/releases/ai-agentic-workflow-kit-0.4.0.tar.gz",
    "manifest_locator": "file://$WORKSPACE/releases/ai-agentic-workflow-kit-0.4.0.manifest.json",
    "bundle_archive_sha256": "sha256:...",
    "signature": null
  },
  "provenance": {
    "producer": "local",
    "source_clean": true,
    "source_tagged": true,
    "bootstrap_exception": null
  }
}
```

`channel`이 `bootstrap`이면 `pinnable`은 반드시 `false`다. 프로젝트 lock이 `pinnable: false`인
digest를 pin하면 apply를 거부한다(§7.2). reader는 현재 algo 4를 요구하되,
`baseline/*` annotated tag와 manifest가 모두 `bootstrap`/`pinnable: false`인 경우에만
역사적 `dirty_snapshot_algo: 3` sidecar를 provenance verify용으로 읽을 수 있다.
version tag, `pinnable: true`, 또는 bootstrap 조건이 불일치하는 algo 3 manifest는 거부한다.

`AGENTS.md`와 프로젝트별 spec-gate caller workflow는 `merge-owned`다. 둘 다
`approval_required_paths`에 포함되므로 구조화 merge 결과를 적용할 때도 경로별 승인
(`--approve-path`와 exact merge content)이 필요하다. `.ai/SPEC_REGISTRY.yaml`과
`.github/CODEOWNERS`는 `project-owned`이자 protected다. 이로써 프로젝트가 정의하는 rule,
승인 주체, caller 입력을 중앙 upgrade가 자동으로 덮어쓰거나 자기증명하지 못한다.

`ownership_rules`는 위에서 아래로 평가하지 않는다. **가장 구체적인 glob이 이긴다.**
구체성이 같고 결과가 다르면 fail-closed 한다.

## 6. `source` 추상화와 GitHub Release 전환

프로젝트 lock(`.ai/KIT_INSTALLATION.yaml`)은 아래를 갖는다.

```yaml
schema_version: 2
project_id: example-project
kit_version: '0.4.0'
bundle_digest_algo: 2
# 권위 있는 기대값은 lock에만 있다. manifest에서 읽지 않는다.
kit_bundle_digest: 'sha256:...'
source:
  kind: local            # local | github-release
  locator: 'file://$WORKSPACE/releases/ai-agentic-workflow-kit-0.4.0.tar.gz'
  manifest_locator: 'file://$WORKSPACE/releases/ai-agentic-workflow-kit-0.4.0.manifest.json'
  bundle_archive_sha256: 'sha256:...'
```

### 6.1 resolver 요건

1. `manifest_locator`에서 manifest를 가져온다.
2. `locator`에서 tarball을 가져오고 `bundle_archive_sha256`으로 손상을 확인한다.
3. 압축을 풀고 manifest의 `excluded_paths`를 적용해 `kit_bundle_digest`를 **재계산**한다.
4. 재계산한 값을 **lock의 `kit_bundle_digest`와 비교한다.** manifest의 값과만 비교하지 않는다.
5. manifest의 `kit_bundle_digest`가 lock과 다르면 그 자체로 거부한다.
6. `pinnable`이 `false`면 거부한다.
7. 하나라도 실패하면 apply를 중단한다.

4단계와 5단계가 핵심이다. 기대값을 manifest에서 읽으면 **manifest와 tarball을 함께
바꾼 공격이 통과한다.** 권위 있는 기대값은 프로젝트 저장소가 커밋한 lock에만 존재한다.

release cache 주소는 버전 문자열이 아니라 digest다:
`$KIT_RELEASE_CACHE/<kit_bundle_digest>/`(기본 `$HOME/.cache/orca/kit-releases/<digest>/`).

### 6.2 로컬 → GitHub Release 전환

| 필드 | `kind: local` | `kind: github-release` | 전환 시 변경 |
|---|---|---|---|
| `kit_version` | `0.4.0` | `0.4.0` | 없음 |
| `kit_bundle_digest` | 내용에서 파생 | 내용에서 파생 | **없음** |
| `bundle_digest_algo` | 2 | 2 | 없음 |
| `auxiliary_digests` | 동일 | 동일 | 없음 |
| `ownership_rules` | 동일 | 동일 | 없음 |
| `source.kind` | `local` | `github-release` | 값 변경 |
| `source.locator` | `file://...tar.gz` | `https://github.com/<org>/<repo>/releases/download/v0.4.0/...tar.gz` | **값 변경** |
| `source.manifest_locator` | `file://...manifest.json` | `https://.../...manifest.json` | **값 변경** |
| `source.bundle_archive_sha256` | 로컬 tarball checksum | 게시된 tarball checksum | 값이 달라질 수 있다. 정체성이 아니므로 무해하다 |
| `source.signature` | `null` | 서명 도입 시 채운다 | 선택 (D-NEED-10) |

구조 변경 없이 `kind`와 두 `locator`만 바꾸면 전환이 끝난다. `kit_bundle_digest`가
같으므로 lock의 정체성 검증은 그대로 통과한다.

## 7. baseline tag와 release tag

### 7.1 bootstrap 필요 여부

아직 유효한 annotated release tag가 없는 저장소는 bootstrap 경로가 필요하다.
이미 release가 있는 저장소는 해당 tag와 artifact의 정체성을 검증한다.
이 공개본은 특정 환경에서 tag가 없었거나 생성되었다는 실행 기록을 포함하지 않는다.

### 7.2 tag 두 종류

| 종류 | 이름 규칙 | `channel` | `pinnable` | 언제 만드는가 | 용도 |
|---|---|---|---|---|---|
| baseline tag | `baseline/pre-integrity-<date>` | `bootstrap` | **`false`** | Phase 1 착수 직후 | 수정 전 상태 보존과 release 생성 경로 개통 |
| release tag | `v0.4.0` | `candidate` 또는 `stable` | `true` | Phase 1의 P0 구현과 테스트가 끝난 뒤 | 프로젝트가 pin하는 최초 대상 |

baseline tag는 fixture 검증과 release 생성 경로 자체를 시험하는 데만 쓴다.
manifest의 `pinnable`이 `false`이므로 §6.1-6에 의해 실제 프로젝트 apply에 사용할 수 없다.

release tag는 다음을 만족해야 한다. Phase 1 종료조건이 이를 검사한다.

- annotated tag이고, 가리키는 commit의 `VERSION`이 tag 이름과 일치한다
- tag tree에 P0 구현이 존재한다(`git show <tag>:engine/release/release_digest.rb`가 성공)
- `engine_digest`가 baseline tag의 값과 **다르다**
- 그 tag에서 만든 release로 fixture apply와 회귀 테스트가 통과한다

### 7.3 `--dev-source` 예외 조건(역사적 전환 규칙)

release 생성 경로와 적용 경로를 분리한다. P0-01은 적용 경로에만 적용한다.

| 경로 | P0-01 적용 | 요구 |
|---|---|---|
| release 생성(`rake release:build`) | 적용하지 않는다 | ref가 annotated tag이고 `VERSION`이 일치. tag tree만 읽으므로 working tree가 dirty해도 결정론적이다 |
| production apply | 적용한다 | §6.1 전 단계 통과 + `pinnable: true` |
| 개발용 apply(`--dev-source`) | 예외 허용 | 아래 조건 전부 충족 시에만 |

`--dev-source` 허용 조건:

1. 명령행에 `--dev-source`가 명시되었다. 기본값이 아니다.
2. target이 `fixtures/**` 아래의 합성 fixture다. `$WORKSPACE/projects/**`는 거부한다.
3. `plan_digest`를 정상적으로 계산해 apply에 전달한다.
4. 실행 로그와 생성된 `KIT_INSTALLATION.yaml`에
   `provenance.bootstrap_exception: {reason, actor, at, source_commit, source_dirty_digest}`를 기록한다.
5. `installation_state`를 `managed`가 아니라 `dev_unmanaged`로 표시한다.

### 7.4 예외의 만료

`--dev-source`는 다음이 모두 성립하면 제거한다. 제거는 Phase 2 종료조건에 포함한다.

- 중앙 kit에 `pinnable: true`인 release tag가 1개 이상 존재한다.
- 그 tag에서 만든 release로 fixture apply가 성공한다.
- fixture 테스트가 `--dev-source` 없이 통과한다.

만료 이전에도 `--dev-source`로 실제 프로젝트에 apply하는 것은 §7.3-2에 의해 불가능하다.

현재 kit의 CLI는 이 전환기 옵션을 제공하지 않는다. 적용할 버전에서 옵션 거부와
release-only 동작을 검증한다. 이 절은 과거 버전의 호환성 계약을 설명하며,
실행 예외를 새로 허용하지 않는다.

## 8. `plan_digest`

### 8.1 목적

plan 생성 시점의 입력과 결정을 하나의 값으로 묶어, apply 시점에 source나 target이
변했으면 중단한다(계획 문서 §5 P0-04).

### 8.2 포함 필드

plan JSON에 아래를 기록하고, 이 필드들의 정규화 직렬화에 대한 SHA-256을 `plan_digest`로 한다.

| 그룹 | 필드 | 설명 |
|---|---|---|
| source | `kit_version` | release 버전 |
| source | `kit_bundle_digest` | §3 |
| source | `bundle_digest_algo`, `rendered_digest_algo`, `dirty_snapshot_algo` | 알고리즘 버전 |
| source | `rendered_install_digest` | §4.2 |
| source | `pinnable` | `false`면 plan 자체가 `blocked` |
| target | `repository_fingerprint` | §8.3 |
| target | `head_commit` | `git rev-parse HEAD` |
| target | `worktree_path` | 대상 worktree 경로 |
| target | `branch` | 대상 브랜치. plan과 apply가 같은 브랜치여야 한다 |
| target | `dirty_snapshot_digest` | §8.4 |
| target | `dirty_snapshot_scope` | 전체 또는 scope glob 목록. §8.4 |
| target | `manifest_digest` | 기존 `KIT_INSTALLATION.yaml`의 SHA-256. 없으면 `null` |
| files | `path` | target 상대 경로 |
| files | `ownership` | 4분류 |
| files | `current_digest` | 현재 파일 내용 SHA-256. 없으면 `null` |
| files | `expected_digest` | 이전 release가 설치했어야 하는 내용의 SHA-256. 없으면 `null` |
| files | `desired_digest` | 이번 release가 설치할 내용의 SHA-256. 삭제면 `null` |
| files | `action` | `create` / `update` / `delete` / `skip` / `conflict` |
| approvals | `protected_path_approvals` | 승인된 경로와 승인자 |
| approvals | `approval_required_path_approvals` | `AGENTS.md` 등 merge-owned 승인 |
| activity | `active_streams`, `lock_paths` | 비어 있지 않으면 plan이 `blocked` |

### 8.3 `repository_fingerprint`

프로젝트 정체성을 절대 경로에 의존하지 않고 확정한다(계획 문서 §7-2).

```text
repository_fingerprint = sha256(
  first_commit_sha + "\n" +
  sorted(normalized remote urls).join("\n") + "\n" +
  project_id_from_manifest_or_empty
)
```

`first_commit_sha`는 `git rev-list --max-parents=0 HEAD`의 정렬된 목록이다.
remote url은 스킴과 자격증명을 제거하고 `host/org/repo`로 정규화한다.
remote가 없으면 빈 문자열로 두고 그 사실을 plan에 기록한다.

같은 저장소의 linked worktree는 `repository_fingerprint`가 같고 `worktree_path`가 다르다.
`sample-worker`과 `sample-worker-preview`가 이 경우다
([`INVENTORY`](INVENTORY_TEMPLATE.md) §4.2(a)).

### 8.4 `dirty_snapshot_digest` (`dirty_snapshot_algo: 4`, legacy 3)

revision 1은 `git status --porcelain` 출력 문자열만 해시했다. 이 방식은 이미 수정된
파일의 내용이 다시 바뀌어도 값이 변하지 않는다. YYYY-MM-DD 재현:

```text
같은 파일을 서로 다른 내용으로 두 번 수정
porcelain 출력: " M f.txt"  (양쪽 동일)
algo 1 digest:  bcd768a79fc3 / bcd768a79fc3   → 동일. 내용 변경 미감지
algo 2 digest:  c99f433e4953 / fe001d33b051   → 상이. 내용 변경 감지
```

algo 2는 실제 내용 변화를 감지했지만 탭/개행 구분자로 raw path를 이어 붙여 bundle
algo 1과 같은 구조적 collision이 재현됐다. 따라서 release 전에 퇴역했다.

`dirty_snapshot_algo: 3`은 YYYY-MM-DD Phase 0에서 기존 checkpoint를 위한
legacy 규범이다. 새 record를 algo 3으로 만들지 않는다. versioned verifier는 3과 4를
모두 읽지만 writer는 4만 출력한다.

legacy algo 3 정의:

```text
entries := parse(git status --porcelain=v1 -z --untracked-files=all)   # NUL 구분
if scope_globs is given: entries := entries matching scope_globs
for each entry:
    row = [<XY>, <worktree sha256>, <staged sha256 or '-'>, <origin or '-'>, <path>]
sort rows by <path bytes>
material = domain_separator + algo + entry_count
for each field: material += decimal_byte_length(field) + ":" + field
dirty_snapshot_digest = sha256(material)
```

- NUL 구분으로 읽어 공백과 개행이 포함된 경로를 처리한다.
- rename/copy(`R`, `C`)는 경로가 두 개이므로 `origin path`를 함께 기록한다.
- worktree 내용과 staged blob을 **따로** digest해 index와 작업 트리의 차이를 구분한다.
- 파일이 없거나 symlink면 빈 내용의 SHA-256을 쓴다.
- Git은 untracked nested repository를 `--untracked-files=all`에서도 디렉터리 한 항목으로
  보고할 수 있다. 이때 디렉터리를 빈 내용으로 취급하지 않고, 하위 경로를 NUL-safe byte
  order로 정렬해 파일 content SHA-256과 entry type을 재귀적으로 fold한다. symlink는 따라가지 않는다.

디렉터리 worktree digest의 규범 직렬화는 다음과 같다.

```text
for each descendant without following symlinks:
    type = "f" regular file, "d" directory, "l" symlink, "o" other
    content = sha256(file bytes) for "f", sha256(empty) otherwise
    record = "<type>\t<content>\t<relative path>\0"
sort records by the byte sequence of <relative path>
directory_worktree_digest = sha256(concat(records))
```

algo 3은 top-level symlink target byte를 포함하지 않으므로 새 checkpoint의 복원 증거로는
충분하지 않다. 단, 기존 algo 3 checkpoint는 별도의 type-count 증거로 untracked
symlink가 0개임을 확인했으므로 폐기하거나 다시 만들지 않는다.

`dirty_snapshot_algo: 4` 정의:

```text
entries := parse(git status --porcelain=v1 -z --untracked-files=all)   # NUL 구분
if scope is given: entries := entries matching that exact scope
for each entry:
    worktree_type = "f" regular, "d" directory, "l" symlink,
                    "o" other, "m" missing
    worktree_digest = sha256(file bytes)                         if type == "f"
                    = recursive_directory_digest_algo4           if type == "d"
                    = sha256(readlink target bytes, no follow)    if type == "l"
                    = sha256(empty)                               otherwise
    row = [<XY>, <worktree_type>, <worktree_digest>,
           <staged sha256 or '-'>, <origin or '-'>, <path>]
sort rows by <path bytes>
material = "ai-harness-governance-dirty-snapshot\0" + algo + "\0" + entry_count + "\0"
for each field: material += decimal_byte_length(field) + ":" + field
dirty_snapshot_digest = sha256(material)
```

algo 4의 recursive directory record는 algo 3과 같은
`<type>\t<content>\t<relative path>\0` framing을 쓴다. 차이는 type `l`의 content를
`sha256(readlink target bytes)`로 기록하는 것이다. symlink를 따라가지 않고 target의 raw
byte만 읽는다. staged symlink는 Git blob 자체가 target byte이므로 다른 staged blob과
같이 `git cat-file blob`의 결과를 digest한다.

runtime reader는 각 경로 component를 검증된 parent directory descriptor 기준으로 열고
symlink를 따라가지 않는다. regular file, directory, root와 ancestor의 identity 및 stable
metadata를 digest 전후 다시 확인한다. 읽는 동안 namespace가 교체되거나 내용이 변하면
부분 digest를 반환하지 않고 실패한다. socket/FIFO/device 같은 `other` entry는 검증된
parent와 stable no-follow metadata를 확인한 경우에만 type `o`로 기록한다.

Phase 0 checkpoint archive는 algo 4 digest와 다음 복원 규칙을 함께 사용한다.

1. writer는 archive를 `0600` no-clobber 방식으로 게시하고, verifier는 private fixed
   snapshot으로 복사하면서 index의 SHA-256과 대조한다.
2. POSIX PAX `path`와 `linkpath`를 적용한 effective 값을 검사한다.
3. absolute/root escape, hardlink, device/FIFO, GNU long-link, duplicate/type collision,
   symlink descendant, 기존 scratch symlink ancestor, tracked overwrite, 비정상
   directory/symlink payload와 malformed/duplicate/dangling PAX를 거부한다.
4. algo 3/4 모두 목적지 preflight를 먼저 수행한다. 기존 algo 3 archive는 material symlink를
   계속 거부하고 원래 AppleDouble 의미 보존을 위해 platform tar로 복원한다.
5. algo 4는 directory와 regular file을 먼저 만들고, 검증된 relative leaf symlink를
   마지막에 만든다.
6. 모든 symlink의 실제 해석 결과가 scratch root 안이고 손상되지 않았음을 확인한 뒤 algo 4
   digest를 다시 계산한다. archive member 이름과 target은 stdout이나 evidence에 기록하지 않는다.

검증은 algo 3 호환, algo 4의 안전한 상대 symlink, 악성 archive 거부와 복원 불변성을 포함해야 한다.

**확정된 scope(D-NEED-12 해소).** plan/apply는 저장소 전체가 아니라 아래 합집합을 쓴다.

```text
dirty_snapshot_scope = exact(plan target paths) union harness allowlist
harness allowlist = .ai/**, AGENTS.md, .githooks/**, .github/workflows/**
```

plan target은 glob으로 재해석하지 않는 exact path다. rename/copy는 destination과 origin 중
하나라도 exact path 또는 scope glob에 포함되면 entry 전체를 포함해 scope 밖으로 이동한
하네스 변경도 감지한다. 별도 scope glob도 지원하지만, glob과
exact path 목록 전체를 `dirty_snapshot_scope`에 기록한다. apply는 같은 목록으로 다시
계산하며 범위가 다르면 그 자체로 중단한다. Phase 0 checkpoint는 plan 이전의 복원 증거이므로
예외적으로 `mode: all`을 사용한다. 같은 algo 4와 conformance vector를 쓰되 Phase 0 digest와
plan digest의 scope가 같다고 가정하지 않는다.

### 8.5 정규화 직렬화

```text
canonical_json = JSON with:
  - 객체 키를 LC_ALL=C 기준 오름차순 정렬
  - 배열은 명시된 정렬 기준으로 정렬(files는 path 기준)
  - 공백 없음(separators ',' ':')
  - UTF-8, 비ASCII 이스케이프하지 않음
  - 부동소수 사용 금지
plan_digest = sha256(canonical_json)
```

`created_at` 같은 시각 필드는 plan JSON에 남기되 `plan_digest` 계산에서 제외하고,
제외 필드 목록을 `digest_excluded_fields`에 명시한다.

### 8.6 apply의 재검증

`apply --plan-digest <value>`는 아래 순서로 검증하고, 하나라도 불일치하면 중단한다.

1. plan JSON을 다시 읽고 `plan_digest`를 재계산해 인수와 비교한다.
2. source를 §6.1대로 다시 해석해 `kit_bundle_digest`를 재계산하고 **lock과** 비교한다.
3. target의 `head_commit`, `branch`, `worktree_path`, `repository_fingerprint`,
   `dirty_snapshot_digest`(같은 `dirty_snapshot_scope`로)를 다시 계산해 비교한다.
4. 파일별 `current_digest`를 다시 계산해 비교한다. 하나라도 다르면 그 파일만 건너뛰지 않고
   **apply 전체를 중단**한다.
5. `action`이 `delete`인 항목은 manifest의 `tombstones`에 존재하고 사람 승인이
   기록되어 있어야 한다. `project-owned`와 `.ai/tasks/**`는 `delete`를 가질 수 없다.

3단계가 `worktree_path`와 `branch`를 비교하므로, **plan과 apply는 같은 worktree의 같은
브랜치에서 수행해야 한다.** 격리 worktree에서 plan을 만들고 다른 곳에서 apply하면
정상적으로 중단된다. Phase 3의 절차가 이를 반영한다
([`PHASE_3`](phases/PHASE_3_CANARY_ADOPTION.md) §4.3).

## 9. 검증 명령

| # | 검사 | 기대 결과 |
|---|---|---|
| VR-1 | §3.2 규범 구현을 같은 ref에 2회 실행 | 두 값 동일 |
| VR-2 | working tree를 dirty하게 만든 뒤 같은 ref | VR-1과 동일 |
| VR-3 | 같은 ref를 별도 clone에서 계산 | VR-1과 동일 |
| VR-4 | tarball 생성 → 압축 해제 → 제외 목록 적용 → 재계산 | VR-1과 동일 |
| VR-5 | tarball을 다른 tar 구현체로 재생성해 `bundle_archive_sha256` 비교 | 값이 달라도 무관. VR-4가 통과하면 정체성 유지 |
| VR-6 | 같은 fixture에 두 번 plan | `rendered_install_digest`와 `plan_digest` 동일 |
| VR-7 | plan 후 fixture 파일 1개를 수정하고 `apply --plan-digest` | 중단 |
| VR-8 | plan 후 release를 다른 digest로 바꿔 apply | 중단 |
| VR-9 | `source.locator`를 다른 내용의 tarball로 바꿔 apply | 중단(§6.1-4) |
| VR-10 | symlink를 포함한 tree로 release 생성 시도 | 거부, 종료 코드 3, 부분 결과 없음 |
| VR-11 | 정렬 키 검증. 경로 순서와 digest 순서가 다른 두 파일로 계산 | 규범 구현과 경로 정렬 결과가 일치 |
| VR-12 | manifest와 tarball을 함께 바꿔 apply | 거부(§6.1-5). lock 값과 불일치 |
| VR-13 | `pinnable: false`인 baseline release를 lock에 pin해 apply | 거부(§6.1-6) |
| VR-14 | 같은 파일을 서로 다른 내용으로 두 번 수정하고 `dirty_snapshot_digest` 비교 | 두 값이 달라야 한다 |
| VR-15 | staged와 worktree 내용이 다른 상태에서 `dirty_snapshot_digest` | 두 내용을 구분해 반영 |
| VR-16 | 공백·탭·개행 경로와 untracked nested repository에서 digest 계산 | 정상 처리하고 nested content 변경을 감지 |
| VR-17 | spec 파일이 자신의 `source_globs`에 포함된 registry | 검증기가 `invalid` 판정(§4.4-1) |

## 10. 이 명세가 규정하지 않는 것

- 서명과 검증 체계(`source.signature`는 자리만 둔다). 도입 여부와 시점은 D-NEED-10에서 결정한다.
- GitHub Release 게시 절차와 권한 모델. Phase 5에서 다룬다.
- 프로젝트별 profile의 내용. Phase 2에서 정의한다.
- SHA-256 이외 해시로의 전환 경로. `bundle_digest_algo` 번호를 올려 처리한다.
- deploy receipt의 신뢰 모델. [`PHASE_4`](phases/PHASE_4_SPEC_FRESHNESS_GATE.md) §4.7이 소유한다.

# frozen_string_literal: true

require_relative "test_helper"
require "ai_harness_governance/dirty_snapshot"

class DirtySnapshotTest < Minitest::Test
  DirtySnapshot = AIHarnessGovernance::DirtySnapshot

  def test_content_changes_change_digest_even_when_porcelain_status_is_same
    with_repository do |_directory, repository|
      write_file(repository, "tracked.txt", "first version\n")
      first = DirtySnapshot.new(repository).calculate
      write_file(repository, "tracked.txt", "second version\n")
      second = DirtySnapshot.new(repository).calculate

      assert_equal [" M"], first.entries.map(&:status)
      assert_equal [" M"], second.entries.map(&:status)
      refute_equal first.digest, second.digest
    end
  end

  def test_staged_and_worktree_content_are_hashed_separately
    with_repository do |_directory, repository|
      write_file(repository, "tracked.txt", "staged bytes\n")
      git(repository, "add", "tracked.txt")
      write_file(repository, "tracked.txt", "worktree bytes\n")

      result = DirtySnapshot.new(repository).calculate
      entry = result.entries.fetch(0)

      assert_equal "MM", entry.status
      assert_equal Digest::SHA256.hexdigest("staged bytes\n"), entry.staged_sha256
      assert_equal Digest::SHA256.hexdigest("worktree bytes\n"), entry.worktree_sha256
      refute_equal entry.staged_sha256, entry.worktree_sha256
    end
  end

  def test_nul_status_parser_handles_spaces_tabs_and_newlines_in_paths
    with_repository do |_directory, repository|
      names = ["space name.txt", "tab\tname.txt", "line\nbreak.txt"]
      names.each { |name| write_file(repository, name, "payload for #{name.bytesize}\n") }

      result = DirtySnapshot.new(repository).calculate
      actual = result.entries.map(&:path).sort

      assert_equal names.sort, actual
      assert_equal 3, result.entries.length
    end
  end

  def test_length_prefix_framing_prevents_newline_path_record_injection
    digest_b = Digest::SHA256.hexdigest("B")
    injected_path = "a\n??\t#{digest_b}\t-\t-\tb"

    with_repository do |_first_directory, first_repository|
      write_file(first_repository, injected_path, "A")
      one_entry = DirtySnapshot.new(first_repository).calculate

      with_repository do |_second_directory, second_repository|
        write_file(second_repository, "a", "A")
        write_file(second_repository, "b", "B")
        two_entries = DirtySnapshot.new(second_repository).calculate

        assert_equal 1, one_entry.entries.length
        assert_equal 2, two_entries.entries.length
        refute_equal one_entry.digest, two_entries.digest
      end
    end
  end

  def test_rename_records_destination_and_origin_without_arrow_parsing
    with_repository do |_directory, repository|
      git(repository, "mv", "tracked.txt", "renamed file.txt")

      entry = DirtySnapshot.new(repository).calculate.entries.fetch(0)

      assert_equal "R ", entry.status
      assert_equal "renamed file.txt", entry.path
      assert_equal "tracked.txt", entry.origin_path
    end
  end

  def test_scope_includes_a_rename_out_by_its_origin_path
    with_repository do |_directory, repository|
      write_file(repository, ".ai/runtime/policy.rb", "policy\n")
      git(repository, "add", ".ai/runtime/policy.rb")
      git(repository, "commit", "-m", "add scoped policy")
      git(repository, "mv", ".ai/runtime/policy.rb", "outside-policy.rb")

      result = DirtySnapshot.new(
        repository,
        DirtySnapshot::Scope.plan([])
      ).calculate
      entry = result.entries.fetch(0)

      assert_equal "outside-policy.rb", entry.path
      assert_equal ".ai/runtime/policy.rb", entry.origin_path
    end
  end

  def test_untracked_nested_repository_directory_hashes_recursive_content
    with_repository do |_directory, repository|
      nested = File.join(repository, "nested-repository")
      FileUtils.mkdir_p(nested)
      Open3.capture3("git", "init", "-q", nested)
      write_file(nested, "payload.txt", "first nested content\n")
      first = DirtySnapshot.new(repository).calculate
      write_file(nested, "payload.txt", "second nested content\n")
      second = DirtySnapshot.new(repository).calculate

      assert_equal ["nested-repository/"], first.entries.map(&:path)
      assert_equal ["nested-repository/"], second.entries.map(&:path)
      refute_equal first.entries.fetch(0).worktree_sha256, second.entries.fetch(0).worktree_sha256
      refute_equal first.digest, second.digest
    end
  end

  def test_algorithm_four_hashes_top_level_symlink_type_and_target_bytes
    with_repository do |_directory, repository|
      write_file(repository, "first-target.txt", "first\n")
      write_file(repository, "second-target.txt", "second\n")
      link = File.join(repository, "current-target")
      File.symlink("first-target.txt", link)
      first = DirtySnapshot.new(repository).calculate
      first_entry = first.entries.find { |entry| entry.path == "current-target" }

      File.unlink(link)
      File.symlink("second-target.txt", link)
      second = DirtySnapshot.new(repository).calculate
      second_entry = second.entries.find { |entry| entry.path == "current-target" }

      assert_equal 4, first.algorithm
      assert_equal "l", first_entry.worktree_type
      assert_equal Digest::SHA256.hexdigest("first-target.txt"), first_entry.worktree_sha256
      assert_equal Digest::SHA256.hexdigest("second-target.txt"), second_entry.worktree_sha256
      refute_equal first.digest, second.digest
    end
  end

  def test_algorithm_four_hashes_nested_symlink_targets_without_following_them
    with_repository do |_directory, repository|
      nested = File.join(repository, "nested-repository")
      FileUtils.mkdir_p(nested)
      Open3.capture3("git", "init", "-q", nested)
      write_file(nested, "first.txt", "first\n")
      write_file(nested, "second.txt", "second\n")
      link = File.join(nested, "current")
      File.symlink("first.txt", link)
      v4_first = DirtySnapshot.new(repository).calculate
      v3_first = DirtySnapshot.new(
        repository,
        DirtySnapshot::Scope.all,
        algorithm: DirtySnapshot::LEGACY_ALGORITHM
      ).calculate

      File.unlink(link)
      File.symlink("second.txt", link)
      v4_second = DirtySnapshot.new(repository).calculate
      v3_second = DirtySnapshot.new(
        repository,
        DirtySnapshot::Scope.all,
        algorithm: DirtySnapshot::LEGACY_ALGORITHM
      ).calculate

      refute_equal v4_first.digest, v4_second.digest
      assert_equal v3_first.digest, v3_second.digest
    end
  end

  def test_algorithm_four_distinguishes_empty_regular_file_from_symlink
    with_repository do |_first_directory, first_repository|
      write_file(first_repository, "entry", "")
      v3_file = DirtySnapshot.new(
        first_repository,
        DirtySnapshot::Scope.all,
        algorithm: DirtySnapshot::LEGACY_ALGORITHM
      ).calculate
      v4_file = DirtySnapshot.new(first_repository).calculate

      with_repository do |_second_directory, second_repository|
        File.symlink("target", File.join(second_repository, "entry"))
        v3_link = DirtySnapshot.new(
          second_repository,
          DirtySnapshot::Scope.all,
          algorithm: DirtySnapshot::LEGACY_ALGORITHM
        ).calculate
        v4_link = DirtySnapshot.new(second_repository).calculate

        assert_equal v3_file.digest, v3_link.digest
        refute_equal v4_file.digest, v4_link.digest
      end
    end
  end

  def test_custom_scope_globs_include_only_matching_entries
    with_repository do |_directory, repository|
      write_file(repository, "app/inside.txt", "inside\n")
      write_file(repository, "other/outside.txt", "outside\n")

      scope = DirtySnapshot::Scope.custom(["app/**"])
      result = DirtySnapshot.new(repository, scope).calculate

      assert_equal ["app/inside.txt"], result.entries.map(&:path)
    end
  end

  def test_plan_scope_is_exact_targets_union_harness_allowlist
    with_repository do |_directory, repository|
      write_file(repository, "src/target[1].rb", "target\n")
      write_file(repository, "src/unrelated.rb", "unrelated\n")
      write_file(repository, ".ai/runtime/policy.rb", "policy\n")
      write_file(repository, "AGENTS.md", "instructions\n")

      scope = DirtySnapshot::Scope.plan(["src/target[1].rb"])
      result = DirtySnapshot.new(repository, scope).calculate

      assert_equal(
        [".ai/runtime/policy.rb", "AGENTS.md", "src/target[1].rb"],
        result.entries.map(&:path)
      )
      assert_equal "plan_targets_plus_harness_allowlist", result.scope.mode
    end
  end

  def test_empty_snapshot_uses_algorithm_bound_framing
    with_repository do |_directory, repository|
      result = DirtySnapshot.new(repository).calculate

      assert_empty result.entries
      assert_equal Digest::SHA256.hexdigest(
        "ai-harness-governance-dirty-snapshot\0#{DirtySnapshot::ALGORITHM}\0" + "0\0"
      ), result.digest
    end
  end

  def test_legacy_algorithm_three_empty_vector_remains_byte_compatible
    with_repository do |_directory, repository|
      result = DirtySnapshot.new(
        repository,
        DirtySnapshot::Scope.all,
        algorithm: DirtySnapshot::LEGACY_ALGORITHM
      ).calculate

      assert_equal 3, result.algorithm
      assert_equal "0ebe60c731cc45244e29c0eb51ee0f0c880ec647ff280508b3f2055ca177423b",
        result.digest
    end
  end

  def test_unknown_dirty_snapshot_algorithm_is_rejected
    with_repository do |_directory, repository|
      error = assert_raises(ArgumentError) do
        DirtySnapshot.new(repository, DirtySnapshot::Scope.all, algorithm: 99)
      end

      assert_equal "unsupported dirty snapshot algorithm", error.message
    end
  end

  def test_cli_outputs_metadata_but_not_file_content_or_entry_paths
    with_repository do |_directory, repository|
      secret_path = "do-not-print-name.txt"
      secret_content = "do-not-print-secret-value"
      write_file(repository, secret_path, secret_content)
      cli = File.expand_path("../bin/dirty-snapshot", __dir__)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        cli,
        "--worktree",
        repository
      )

      assert status.success?, stderr
      payload = JSON.parse(stdout)
      assert_equal 4, payload.fetch("dirty_snapshot_algo")
      assert_equal 1, payload.fetch("entry_count")
      refute_includes stdout, secret_path
      refute_includes stdout, secret_content
    end
  end

  def test_cli_supports_glob_and_plan_target_scopes
    with_repository do |_directory, repository|
      write_file(repository, "app/target.rb", "target\n")
      write_file(repository, "app/other.rb", "other\n")
      write_file(repository, ".ai/runtime/policy.rb", "policy\n")
      cli = File.expand_path("../bin/dirty-snapshot", __dir__)

      custom_stdout, custom_stderr, custom_status = Open3.capture3(
        RbConfig.ruby, cli, "--worktree", repository, "--scope", "app/target*"
      )
      assert custom_status.success?, custom_stderr
      custom = JSON.parse(custom_stdout)
      assert_equal 1, custom.fetch("entry_count")
      assert_equal "custom", custom.fetch("dirty_snapshot_scope").fetch("mode")

      plan_stdout, plan_stderr, plan_status = Open3.capture3(
        RbConfig.ruby, cli, "--worktree", repository, "--plan-path", "app/target.rb"
      )
      assert plan_status.success?, plan_stderr
      plan = JSON.parse(plan_stdout)
      assert_equal 2, plan.fetch("entry_count")
      assert_equal(
        "plan_targets_plus_harness_allowlist",
        plan.fetch("dirty_snapshot_scope").fetch("mode")
      )
    end
  end
end

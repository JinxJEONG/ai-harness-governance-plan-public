# frozen_string_literal: true

require_relative "test_helper"
require "ai_harness_governance/checkpoint"

class CheckpointTest < Minitest::Test
  Checkpoint = AIHarnessGovernance::Checkpoint

  def test_clean_worktree_gets_unique_head_ref_without_empty_archive
    with_repository do |directory, repository|
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")

      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T024500Z"
      ).create

      assert_equal "head", record.fetch("ref_target_kind")
      assert_nil record.fetch("untracked_archive")
      assert_equal record.fetch("head"), git(repository, "rev-parse", record.fetch("checkpoint_ref")).strip
      assert record.fetch("restore_verified")
      assert_equal 1, Checkpoint.verify_index(index)
    end
  end

  def test_checkpoint_preserves_staged_worktree_and_untracked_content
    with_repository do |directory, repository|
      write_file(repository, "tracked.txt", "staged\n")
      git(repository, "add", "tracked.txt")
      write_file(repository, "tracked.txt", "worktree\n")
      write_file(repository, "secret\nname.txt", "credential-like bytes must stay opaque\n")
      write_file(repository, "-C", "tar list option-like name\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")

      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T030000Z"
      ).create

      assert record.fetch("restore_verified")
      assert_equal "stash_commit", record.fetch("ref_target_kind")
      assert File.file?(record.fetch("untracked_archive"))
      assert_equal 0o600, File.stat(record.fetch("untracked_archive")).mode & 0o777
      assert_equal 0o700, File.stat(archive_root).mode & 0o777
      assert_equal 1, Checkpoint.verify_index(index)
      assert_equal "MM tracked.txt\n?? -C\n?? \"secret\\nname.txt\"\n", git(repository, "status", "--short")
    end
  end

  def test_untracked_nested_repository_is_archived_and_restore_verified
    with_repository do |directory, repository|
      nested = File.join(repository, "nested-repository")
      FileUtils.mkdir_p(nested)
      _stdout, stderr, status = Open3.capture3("git", "init", "-q", nested)
      assert status.success?, stderr
      write_file(nested, "payload.txt", "nested secret-like bytes\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")

      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T030500Z"
      ).create

      assert_equal "head", record.fetch("ref_target_kind")
      assert_equal 1, record.fetch("untracked_entries")
      assert File.file?(record.fetch("untracked_archive"))
      assert record.fetch("restore_verified")
      assert_equal 1, Checkpoint.verify_index(index)
    end
  end

  def test_safe_relative_symlink_round_trip_is_restore_verified
    with_repository do |directory, repository|
      write_file(repository, "target.txt", "target bytes\n")
      File.symlink("target.txt", File.join(repository, "safe-link"))
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")

      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T031000Z"
      ).create

      assert_equal 4, record.fetch("dirty_snapshot_algo")
      assert record.fetch("restore_verified")
      assert_equal 1, Checkpoint.verify_index(index)
      assert_equal "target.txt", File.readlink(File.join(repository, "safe-link"))
    end
  end

  def test_broken_relative_symlink_fails_closed_and_rolls_back
    with_repository do |directory, repository|
      File.symlink("missing-target", File.join(repository, "broken-link"))
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      timestamp = "20260813T031100Z"

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: repository,
          archive_root: archive_root,
          index_path: index,
          timestamp: timestamp
        ).create
      end

      assert_equal "archive_unsafe_entry", error.code
      assert_empty git(repository, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/#{timestamp}/")
      assert_empty Dir.glob(File.join(archive_root, "**", "#{timestamp}-*.tar.gz"))
      refute File.exist?(index)
      assert File.symlink?(File.join(repository, "broken-link"))
    end
  end

  def test_versioned_verifier_preserves_algorithm_three_records
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "legacy bytes\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T031200Z"
      ).create

      legacy = AIHarnessGovernance::DirtySnapshot.new(
        repository,
        AIHarnessGovernance::DirtySnapshot::Scope.all,
        algorithm: AIHarnessGovernance::DirtySnapshot::LEGACY_ALGORITHM
      ).calculate
      document = JSON.parse(File.binread(index))
      indexed = document.fetch("worktrees").fetch(0)
      indexed["dirty_snapshot_algo"] = legacy.algorithm
      indexed["dirty_snapshot_digest"] = legacy.digest
      File.binwrite(index, "#{JSON.pretty_generate(document)}\n")

      assert_equal 4, record.fetch("dirty_snapshot_algo")
      assert_equal 1, Checkpoint.verify_index(index)
    end
  end

  def test_verify_index_rejects_record_not_marked_restore_verified
    with_repository do |directory, repository|
      index = File.join(directory, "checkpoint-index.json")
      Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T031250Z"
      ).create
      document = JSON.parse(File.binread(index))
      document.fetch("worktrees").fetch(0)["restore_verified"] = false
      File.binwrite(index, "#{JSON.pretty_generate(document)}\n")

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.verify_index(index)
      end

      assert_equal "checkpoint_not_restore_verified", error.code
    end
  end

  def test_git_optional_locks_preserve_source_index_bytes
    with_repository do |directory, repository|
      write_file(repository, "tracked.txt", "dirty bytes\n")
      relative_index = git(repository, "rev-parse", "--git-path", "index").strip
      source_index = File.expand_path(relative_index, repository)
      before = Digest::SHA256.file(source_index).hexdigest

      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: File.join(directory, "checkpoint-index.json"),
        timestamp: "20260813T031300Z"
      ).create
      after = Digest::SHA256.file(source_index).hexdigest

      assert record.fetch("restore_verified")
      assert_equal before, after
    end
  end

  def test_source_change_during_restore_verification_rolls_back_before_index_publish
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      timestamp = "20260813T031400Z"
      original_new = Checkpoint::Verifier.method(:new)
      factory = lambda do |document|
        verifier = original_new.call(document)
        wrapper = Object.new
        wrapper.define_singleton_method(:verify) do |record|
          verifier.verify(record)
          File.open(File.join(repository, "tracked.txt"), "ab") { |file| file.write("external change\n") }
          true
        end
        wrapper
      end

      error = Checkpoint::Verifier.stub(:new, factory) do
        assert_raises(Checkpoint::Error) do
          Checkpoint.new(
            worktree: repository,
            archive_root: archive_root,
            index_path: index,
            timestamp: timestamp
          ).create
        end
      end

      assert_equal "worktree_changed_during_checkpoint", error.code
      assert_empty git(repository, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/#{timestamp}/")
      assert_empty Dir.glob(File.join(archive_root, "**", "#{timestamp}-*.tar.gz"))
      refute File.exist?(index)
    end
  end

  def test_approved_input_change_is_rejected_before_ref_archive_or_index_creation
    with_repository do |directory, repository|
      approved = AIHarnessGovernance::DirtySnapshot.new(repository).calculate
      approved_head = git(repository, "rev-parse", "HEAD").strip
      write_file(repository, "late-change.txt", "changed after approval\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      timestamp = "20260813T031450Z"

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: repository,
          archive_root: archive_root,
          index_path: index,
          timestamp: timestamp,
          expected_dirty_snapshot_digest: approved.digest,
          expected_head: approved_head,
          expected_branch: "main"
        ).create
      end

      assert_equal "approved_input_changed", error.code
      assert_empty git(repository, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/#{timestamp}/")
      assert_empty Dir.glob(File.join(archive_root, "**", "#{timestamp}-*.tar.gz"))
      refute File.exist?(index)
    end
  end

  def test_linked_worktrees_get_distinct_refs_and_archives_at_same_timestamp
    with_repository do |directory, repository|
      linked = File.join(directory, "linked-worktree")
      git(repository, "worktree", "add", "-q", "-b", "linked-test", linked)
      write_file(repository, "tracked.txt", "main dirty\n")
      write_file(repository, "main-untracked.txt", "main\n")
      write_file(linked, "tracked.txt", "linked dirty\n")
      write_file(linked, "linked-untracked.txt", "linked\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      timestamp = "20260813T031500Z"

      first = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: timestamp
      ).create
      second = Checkpoint.new(
        worktree: linked,
        archive_root: archive_root,
        index_path: index,
        timestamp: timestamp
      ).create

      refute_equal first.fetch("worktree_id"), second.fetch("worktree_id")
      refute_equal first.fetch("checkpoint_ref"), second.fetch("checkpoint_ref")
      refute_equal first.fetch("untracked_archive"), second.fetch("untracked_archive")
      refs = git(repository, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/").lines
      assert_equal 2, refs.length
      document = JSON.parse(File.binread(index))
      assert_equal 2, document.fetch("worktrees").length
      assert_equal 2, Checkpoint.verify_index(index)
    end
  end

  def test_same_ref_is_never_overwritten
    with_repository do |directory, repository|
      write_file(repository, "tracked.txt", "dirty\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      timestamp = "20260813T033000Z"
      first = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: timestamp
      ).create
      before = git(repository, "rev-parse", first.fetch("checkpoint_ref"))

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: repository,
          archive_root: archive_root,
          index_path: index,
          timestamp: timestamp
        ).create
      end

      assert_equal "checkpoint_ref_exists", error.code
      assert_equal before, git(repository, "rev-parse", first.fetch("checkpoint_ref"))
      assert_equal 1, JSON.parse(File.binread(index)).fetch("worktrees").length
    end
  end

  def test_existing_archive_is_never_overwritten
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      archive_root = File.join(directory, "archives")
      FileUtils.mkdir_p(archive_root)
      File.chmod(0o700, archive_root)
      common_dir = File.realpath(File.join(repository, ".git"))
      repository_id = "repository-#{Digest::SHA256.hexdigest(common_dir.b)[0, 8]}"
      worktree_id = Digest::SHA256.hexdigest(File.realpath(repository).b)[0, 12]
      repository_archive = File.join(archive_root, repository_id)
      FileUtils.mkdir_p(repository_archive)
      File.chmod(0o700, repository_archive)
      timestamp = "20260813T033500Z"
      existing = File.join(repository_archive, "#{timestamp}-#{worktree_id}-untracked.tar.gz")
      File.open(existing, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("existing archive must survive")
      end
      before = Digest::SHA256.file(existing).hexdigest

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: repository,
          archive_root: archive_root,
          index_path: File.join(directory, "checkpoint-index.json"),
          timestamp: timestamp
        ).create
      end

      assert_equal "archive_exists", error.code
      assert_equal before, Digest::SHA256.file(existing).hexdigest
      assert_empty git(repository, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/#{timestamp}/")
    end
  end

  def test_parallel_index_adds_do_not_lose_a_worktree_record
    Dir.mktmpdir("checkpoint-index-race") do |directory|
      path = File.join(directory, "index.json")
      metadata = {
        "schema_version" => Checkpoint::INDEX_SCHEMA,
        "tool_version" => Checkpoint::TOOL_VERSION,
        "archive_root" => directory,
        "repository" => {
          "repository_id" => "fixture",
          "git_common_dir" => "/fixture/.git",
          "source_path" => "/fixture",
        },
      }
      records = 2.times.map do |index|
        {
          "worktree_id" => "worktree-#{index}",
          "checkpoint_timestamp" => "20260813T05000#{index}Z",
          "checkpoint_ref" => "refs/harness-checkpoint/#{index}",
        }
      end
      threads = records.map do |record|
        Thread.new { Checkpoint::IndexStore.new(path).add(metadata, record) }
      end
      threads.each(&:value)

      document = Checkpoint::IndexStore.new(path).read
      assert_equal records.map { |record| record["checkpoint_ref"] }.sort,
        document.fetch("worktrees").map { |record| record["checkpoint_ref"] }.sort
    end
  end

  def test_archive_root_inside_any_git_repository_is_rejected
    with_repository do |_directory, repository|
      archive_root = File.join(repository, "unsafe-archives")
      index = File.join(repository, "checkpoint-index.json")

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: repository,
          archive_root: archive_root,
          index_path: index
        )
      end

      assert_equal "archive_root_inside_git", error.code
      refute File.exist?(archive_root)
    end
  end

  def test_existing_archive_root_permissions_are_not_silently_changed
    with_repository do |directory, repository|
      archive_root = File.join(directory, "shared-directory")
      FileUtils.mkdir_p(archive_root)
      File.chmod(0o755, archive_root)
      index = File.join(directory, "checkpoint-index.json")

      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: repository,
          archive_root: archive_root,
          index_path: index
        )
      end

      assert_equal "archive_root_permissions", error.code
      assert_equal 0o755, File.stat(archive_root).mode & 0o777
    end
  end

  def test_archive_tampering_fails_restore_verification
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T034500Z"
      ).create
      File.open(record.fetch("untracked_archive"), "ab") { |file| file.write("tamper") }

      error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }

      assert_equal "archive_digest_mismatch", error.code
    end
  end

  def test_archive_symlink_that_escapes_root_is_rejected_before_restore
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T035000Z"
      ).create

      Dir.mktmpdir("unsafe-checkpoint-archive") do |staging|
        File.symlink("../outside", File.join(staging, "unsafe-link"))
        _stdout, stderr, status = Open3.capture3(
          "tar", "-czf", record.fetch("untracked_archive"), "-C", staging, "unsafe-link"
        )
        assert status.success?, stderr
      end
      File.chmod(0o600, record.fetch("untracked_archive"))
      document = JSON.parse(File.binread(index))
      document.fetch("worktrees").first["untracked_archive_sha256"] =
        Digest::SHA256.file(record.fetch("untracked_archive")).hexdigest
      File.write(index, "#{JSON.pretty_generate(document)}\n")

      error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }

      assert_equal "archive_unsafe_entry", error.code
    end
  end

  def test_effective_pax_path_and_linkpath_restore_independent_of_archive_order
    with_repository do |directory, repository|
      write_file(repository, "target.txt", "pax target bytes\n")
      File.symlink("target.txt", File.join(repository, "safe-link"))
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T035100Z"
      ).create

      entries = [
        pax_entry("safe-link", "target.txt", "SCHILY.xattr.test" => "\x01\x00opaque"),
        raw_entry("ignored-link", "2", "", "ignored-target"),
        pax_entry("target.txt"),
        raw_entry("ignored-file", "0", "pax target bytes\n")
      ]
      replace_record_archive(index, record, entries)

      assert_equal 1, Checkpoint.verify_index(index)
    end
  end

  def test_unsafe_pax_overrides_are_rejected
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T035200Z"
      ).create

      archives = [
        [pax_entry("../escape"), raw_entry("benign", "0", "original\n")],
        [
          raw_entry("GlobalHead/material", "g", pax_payload("path" => "/absolute")),
          raw_entry("benign", "0", "original\n")
        ],
        [
          pax_entry("safe-link", "../../escape"),
          raw_entry("safe-link", "2", "", "untracked.txt")
        ]
      ]
      archives.each do |entries|
        replace_record_archive(index, record, entries)
        error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }
        assert_equal "archive_unsafe_entry", error.code
      end
    end
  end

  def test_malformed_duplicate_and_dangling_pax_headers_are_rejected
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T035250Z"
      ).create

      duplicate = pax_payload("path" => "first") + pax_payload("path" => "second")
      malformed = "999 path=short\n".b
      dangling = pax_payload("path" => "never-applied")
      archives = [
        [raw_entry("PaxHeader/material", "x", duplicate), raw_entry("benign", "0", "original\n")],
        [raw_entry("PaxHeader/material", "x", malformed), raw_entry("benign", "0", "original\n")],
        [raw_entry("PaxHeader/material", "x", dangling)]
      ]
      archives.each do |entries|
        replace_record_archive(index, record, entries)
        error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }
        assert_equal "archive_unsafe_entry", error.code
      end
    end
  end

  def test_hardlink_device_and_gnu_longlink_archive_types_are_rejected
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T035300Z"
      ).create

      [
        [raw_entry("hard", "1", "", "untracked.txt")],
        [raw_entry("device", "3")],
        [raw_entry("long-link", "K", "untracked.txt\0")]
      ].each do |entries|
        replace_record_archive(index, record, entries)
        error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }
        assert_equal "archive_unsafe_entry", error.code
      end
    end
  end

  def test_directory_and_symlink_payloads_are_rejected
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T035350Z"
      ).create

      [
        [raw_entry("directory", "5", "unexpected payload")],
        [raw_entry("safe-link", "2", "unexpected payload", "untracked.txt")]
      ].each do |entries|
        replace_record_archive(index, record, entries)
        error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }
        assert_equal "archive_unsafe_entry", error.code
      end
    end
  end

  def test_duplicate_type_collision_and_symlink_descendants_are_rejected_in_any_order
    with_repository do |directory, repository|
      write_file(repository, "untracked.txt", "original\n")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T035400Z"
      ).create

      link = raw_entry("pivot", "2", "", "untracked.txt")
      descendant = raw_entry("pivot/child", "0", "child\n")
      archives = [
        [raw_entry("duplicate", "0", "one"), raw_entry("duplicate", "0", "two")],
        [raw_entry("node/", "5"), raw_entry("node", "0", "collision")],
        [link, descendant],
        [descendant, link]
      ]
      archives.each do |entries|
        replace_record_archive(index, record, entries)
        error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }
        assert_equal "archive_unsafe_entry", error.code
      end
    end
  end

  def test_existing_scratch_symlink_ancestor_and_tracked_overwrite_are_rejected
    with_repository do |directory, repository|
      File.symlink(".", File.join(repository, "tracked-link"))
      git(repository, "add", "tracked-link")
      git(repository, "commit", "-q", "-m", "add tracked link")
      write_file(repository, "untracked.txt", "original\n")
      index = File.join(directory, "checkpoint-index.json")
      record = Checkpoint.new(
        worktree: repository,
        archive_root: File.join(directory, "archives"),
        index_path: index,
        timestamp: "20260813T035500Z"
      ).create

      legacy = AIHarnessGovernance::DirtySnapshot.new(
        repository,
        AIHarnessGovernance::DirtySnapshot::Scope.all,
        algorithm: AIHarnessGovernance::DirtySnapshot::LEGACY_ALGORITHM
      ).calculate

      unsafe_archives = [
        [raw_entry("tracked-link/child", "0", "child\n")],
        [raw_entry("tracked.txt", "0", "overwrite\n")]
      ]
      [
        [AIHarnessGovernance::DirtySnapshot::ALGORITHM, record.fetch("dirty_snapshot_digest")],
        [AIHarnessGovernance::DirtySnapshot::LEGACY_ALGORITHM, legacy.digest]
      ].each do |algorithm, digest|
        set_record_algorithm(index, record, algorithm, digest)
        unsafe_archives.each do |entries|
          replace_record_archive(index, record, entries)
          error = assert_raises(Checkpoint::Error) { Checkpoint.verify_index(index) }
          assert_equal "archive_unsafe_entry", error.code
        end
      end
    end
  end

  def test_failed_index_publish_rolls_back_new_ref_and_archive
    Dir.mktmpdir("checkpoint-rollback") do |directory|
      first_parent = File.join(directory, "first")
      second_parent = File.join(directory, "second")
      FileUtils.mkdir_p(first_parent)
      FileUtils.mkdir_p(second_parent)
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      first = initialize_repository(File.join(first_parent, "repository"))
      second = initialize_repository(File.join(second_parent, "repository"))
      write_file(first, "first.txt", "first\n")
      Checkpoint.new(
        worktree: first,
        archive_root: archive_root,
        index_path: index,
        timestamp: "20260813T035500Z"
      ).create

      write_file(second, "second.txt", "second\n")
      timestamp = "20260813T035501Z"
      error = assert_raises(Checkpoint::Error) do
        Checkpoint.new(
          worktree: second,
          archive_root: archive_root,
          index_path: index,
          timestamp: timestamp
        ).create
      end

      assert_equal "index_repository_mismatch", error.code
      refs = git(second, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/#{timestamp}/")
      assert_empty refs
      assert_empty Dir.glob(File.join(archive_root, "**", "#{timestamp}-*.tar.gz"))
      assert_equal "?? second.txt\n", git(second, "status", "--short")
    end
  end

  def test_cli_does_not_print_untracked_names_or_contents
    with_repository do |directory, repository|
      secret_name = "private-key-material.txt"
      secret_content = "SUPER-SECRET-CONTENT-DO-NOT-LOG"
      write_file(repository, secret_name, secret_content)
      secret_link = "private-link-name"
      File.symlink(secret_name, File.join(repository, secret_link))
      archive_root = File.join(directory, "archives")
      index = File.join(directory, "checkpoint-index.json")
      cli = File.expand_path("../bin/harness-checkpoint", __dir__)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        cli,
        "create",
        "--worktree",
        repository,
        "--archive-root",
        archive_root,
        "--index",
        index,
        "--timestamp",
        "20260813T040000Z"
      )

      assert status.success?, stderr
      payload = JSON.parse(stdout)
      assert_equal "created", payload.fetch("status")
      assert payload.fetch("restore_verified")
      refute_includes stdout, secret_name
      refute_includes stdout, secret_content
      refute_includes stdout, secret_link
      refute_includes stderr, secret_name
      refute_includes stderr, secret_content
      refute_includes stderr, secret_link
    end
  end

  def test_cli_failure_redacts_paths_and_child_diagnostics
    with_repository do |directory, repository|
      secret_component = "DO-NOT-LOG-THIS-PATH"
      unsafe_root = File.join(repository, secret_component)
      index = File.join(directory, "checkpoint-index.json")
      cli = File.expand_path("../bin/harness-checkpoint", __dir__)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        cli,
        "create",
        "--worktree",
        repository,
        "--archive-root",
        unsafe_root,
        "--index",
        index
      )

      refute status.success?
      assert_empty stdout
      assert_equal "error: checkpoint operation failed\n", stderr
      refute_includes stderr, secret_component
      refute File.exist?(unsafe_root)
    end
  end

  def test_cli_has_no_delete_subcommand
    cli = File.expand_path("../bin/harness-checkpoint", __dir__)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, cli, "delete")

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, "expected create or verify"
  end

  private

  def raw_entry(name, typeflag, data = "", linkname = "")
    {
      name: name.b,
      typeflag: typeflag.b,
      data: data.b,
      linkname: linkname.b
    }
  end

  def pax_entry(path, linkpath = nil, extra = {})
    attributes = { "path" => path }.merge(extra)
    attributes["linkpath"] = linkpath if linkpath
    raw_entry("PaxHeader/material", "x", pax_payload(attributes))
  end

  def pax_payload(attributes)
    attributes.map do |key, value|
      body = key.to_s.b + "=".b + value.to_s.b + "\n".b
      length = body.bytesize + 2
      loop do
        record = length.to_s.b + " ".b + body
        break record if record.bytesize == length
        length = record.bytesize
      end
    end.join
  end

  def write_raw_archive(path, entries)
    File.open(path, "wb") do |file|
      gzip = Zlib::GzipWriter.new(file)
      begin
        entries.each do |entry|
          data = entry.fetch(:data)
          header = Gem::Package::TarHeader.new(
            name: entry.fetch(:name),
            mode: entry.fetch(:typeflag) == "5" ? 0o755 : 0o644,
            size: data.bytesize,
            typeflag: entry.fetch(:typeflag),
            linkname: entry.fetch(:linkname),
            prefix: "",
            mtime: 0
          )
          gzip.write(header.to_s)
          gzip.write(data)
          gzip.write("\0" * ((512 - (data.bytesize % 512)) % 512))
        end
        gzip.write("\0" * 1024)
      ensure
        gzip.close
      end
    end
    File.chmod(0o600, path)
  end

  def replace_record_archive(index, record, entries)
    archive = record.fetch("untracked_archive")
    write_raw_archive(archive, entries)
    document = JSON.parse(File.binread(index))
    indexed = document.fetch("worktrees").find do |candidate|
      candidate.fetch("worktree_id") == record.fetch("worktree_id")
    end
    indexed["untracked_archive_sha256"] = Digest::SHA256.file(archive).hexdigest
    File.binwrite(index, "#{JSON.pretty_generate(document)}\n")
  end

  def set_record_algorithm(index, record, algorithm, digest)
    document = JSON.parse(File.binread(index))
    indexed = document.fetch("worktrees").find do |candidate|
      candidate.fetch("worktree_id") == record.fetch("worktree_id")
    end
    indexed["dirty_snapshot_algo"] = algorithm
    indexed["dirty_snapshot_digest"] = digest
    File.binwrite(index, "#{JSON.pretty_generate(document)}\n")
  end
end

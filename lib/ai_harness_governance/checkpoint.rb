# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "securerandom"
require "tempfile"
require "tmpdir"
require "time"
require "zlib"
require_relative "dirty_snapshot"

module AIHarnessGovernance
  class Checkpoint
    INDEX_SCHEMA = 1
    TOOL_VERSION = "0.4.1"

    class Error < CommandError
      def initialize(code, status = nil)
        super(code, status)
      end
    end

    class IndexStore
      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path)
      end

      def read
        raise Error.new("index_missing") unless File.file?(@path)

        document = JSON.parse(File.binread(@path))
        validate_document(document)
        document
      rescue JSON::ParserError
        raise Error.new("invalid_index")
      end

      def add(metadata, record)
        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory, mode: 0o755)
        lock_path = File.join(directory, ".#{File.basename(@path)}.lock")
        File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock_file|
          lock_file.flock(File::LOCK_EX)
          document = if File.exist?(@path)
                       read
                     else
                       metadata.merge("worktrees" => [])
                     end
          validate_repository!(document, metadata)
          if document.fetch("worktrees").any? do |item|
               item["checkpoint_ref"] == record["checkpoint_ref"]
             end
            raise Error.new("duplicate_checkpoint")
          end

          document["worktrees"] << record
          document["worktrees"].sort_by! do |item|
            [item.fetch("checkpoint_timestamp"), item.fetch("worktree_id")]
          end
          atomic_write(document)
          document
        end
      end

      private

      def validate_document(document)
        unless document.is_a?(Hash) &&
               document["schema_version"] == INDEX_SCHEMA &&
               document["repository"].is_a?(Hash) &&
               document["worktrees"].is_a?(Array)
          raise Error.new("invalid_index")
        end
      end

      def validate_repository!(document, metadata)
        validate_document(document)
        current = document.fetch("repository")
        expected = metadata.fetch("repository")
        unless current["repository_id"] == expected["repository_id"] &&
               current["git_common_dir"] == expected["git_common_dir"] &&
               document["archive_root"] == metadata["archive_root"]
          raise Error.new("index_repository_mismatch")
        end
      end

      def atomic_write(document)
        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory, mode: 0o755)
        temporary = File.join(
          directory,
          ".#{File.basename(@path)}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
        )
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
            file.write(JSON.pretty_generate(document))
            file.write("\n")
            file.flush
            file.fsync
          end
          File.rename(temporary, @path)
        ensure
          File.delete(temporary) if File.exist?(temporary)
        end
      end
    end

    class Verifier
      ArchiveMember = Struct.new(:path, :type, :link_target)
      VerifiedArchive = Struct.new(:file, :expected_digest, :members)
      PAX_HEADER_LIMIT = 1024 * 1024
      PAX_TOTAL_LIMIT = 64 * 1024 * 1024
      ARCHIVE_HEADER_LIMIT = 100_000
      ARCHIVE_CONTENT_LIMIT = 1024 * 1024 * 1024

      def initialize(document)
        @document = document
        @archive_root = Checkpoint.validate_archive_root!(document.fetch("archive_root"))
        @repository = document.fetch("repository")
      end

      def verify(record)
        validate_record!(record)
        source = @repository.fetch("source_path")
        git = GitRunner.new(source)
        ref_target = git.text("rev-parse", "--verify", record.fetch("checkpoint_ref"))
        raise Error.new("checkpoint_ref_changed") unless ref_target == record.fetch("ref_target")

        algorithm = record.fetch("dirty_snapshot_algo")
        repository_dir = archive_repository_dir
        ensure_private_directory!(repository_dir)
        restored_digest = nil
        Dir.mktmpdir("restore-", repository_dir) do |scratch_parent|
          archive = open_verified_archive(record, algorithm, scratch_parent)
          begin
            scratch = File.join(scratch_parent, "repository")
            Command.capture(
              ["git", "clone", "--quiet", "--shared", "--no-checkout", source, scratch],
              nil,
              false,
              Command::GIT_OPTIONAL_LOCKS_ENV
            )
            scratch_git = GitRunner.new(scratch)
            scratch_git.capture("checkout", "--quiet", "--detach", record.fetch("head"))

            if record.fetch("ref_target_kind") == "stash_commit"
              target = record.fetch("ref_target")
              scratch_git.capture("read-tree", "--reset", "-u", target)
              scratch_git.capture("read-tree", "#{target}^2")
            end

            restore_archive!(archive, scratch, algorithm) if archive
            restored_digest = DirtySnapshot.new(
              scratch,
              scope_from_record(record),
              algorithm: algorithm
            ).calculate.digest
            verify_open_archive_digest!(archive) if archive
          ensure
            if archive && !archive.file.closed?
              archive.file.respond_to?(:close!) ? archive.file.close! : archive.file.close
            end
          end
        end

        unless restored_digest == record.fetch("dirty_snapshot_digest")
          raise Error.new("restore_digest_mismatch")
        end

        true
      rescue KeyError, TypeError
        raise Error.new("invalid_index_record")
      end

      private

      def archive_repository_dir
        repository_id = @repository.fetch("repository_id")
        unless repository_id.is_a?(String) && repository_id =~ /\A[A-Za-z0-9._-]+\z/
          raise Error.new("unsafe_archive_path")
        end
        directory = File.join(@archive_root, repository_id)
        expanded = File.expand_path(directory)
        prefix = @archive_root.end_with?(File::SEPARATOR) ? @archive_root : @archive_root + File::SEPARATOR
        raise Error.new("unsafe_archive_path") unless expanded.start_with?(prefix)
        if File.exist?(expanded)
          raise Error.new("unsafe_archive_path") if File.lstat(expanded).symlink?
          raise Error.new("unsafe_archive_path") unless File.realpath(expanded) == expanded
        end
        expanded
      end

      def validate_record!(record)
        required = %w[
          worktree_id checkpoint_timestamp head checkpoint_ref ref_target
          ref_target_kind dirty_snapshot_algo dirty_snapshot_digest restore_verified
        ]
        raise Error.new("invalid_index_record") unless record.is_a?(Hash)
        raise Error.new("invalid_index_record") unless required.all? { |key| record.key?(key) }
        unless DirtySnapshot::SUPPORTED_ALGORITHMS.include?(record["dirty_snapshot_algo"])
          raise Error.new("invalid_index_record")
        end
        raise Error.new("invalid_index_record") unless record["dirty_snapshot_scope"].is_a?(Hash)
        unless ["head", "stash_commit"].include?(record["ref_target_kind"])
          raise Error.new("invalid_index_record")
        end
      end

      def ensure_private_directory!(directory)
        unless File.exist?(directory)
          FileUtils.mkdir_p(directory, mode: 0o700)
          File.chmod(0o700, directory)
        end
        raise Error.new("unsafe_archive_path") if File.lstat(directory).symlink?
        raise Error.new("unsafe_archive_path") unless File.realpath(directory) == File.expand_path(directory)
        raise Error.new("archive_root_permissions") unless File.directory?(directory)
        raise Error.new("archive_root_permissions") unless (File.stat(directory).mode & 0o777) == 0o700
      end

      def scope_from_record(record)
        scope = record.fetch("dirty_snapshot_scope")
        mode = scope.fetch("mode")
        paths = scope.fetch("paths")
        globs = scope.fetch("globs")
        raise Error.new("invalid_index_record") unless paths.is_a?(Array) && globs.is_a?(Array)
        allowed_modes = ["all", "custom", "plan_targets_plus_harness_allowlist"]
        raise Error.new("invalid_index_record") unless allowed_modes.include?(mode)
        if mode == "all" && (!paths.empty? || !globs.empty?)
          raise Error.new("invalid_index_record")
        end

        DirtySnapshot::Scope.new(mode, paths, globs)
      rescue ArgumentError
        raise Error.new("invalid_index_record")
      end

      def open_verified_archive(record, algorithm, snapshot_directory)
        path = record["untracked_archive"]
        expected_digest = record["untracked_archive_sha256"]
        if path.nil?
          raise Error.new("invalid_index_record") unless expected_digest.nil?
          return nil
        end

        expanded = File.expand_path(path)
        root_prefix = @archive_root.end_with?(File::SEPARATOR) ? @archive_root : @archive_root + File::SEPARATOR
        raise Error.new("unsafe_archive_path") unless expanded.start_with?(root_prefix)
        raise Error.new("archive_missing") unless File.file?(expanded)
        raise Error.new("unsafe_archive_path") if File.lstat(expanded).symlink?
        raise Error.new("unsafe_archive_path") unless File.realpath(expanded) == expanded

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        source = File.open(expanded, flags)
        snapshot = nil
        begin
          opened = source.stat
          named = File.lstat(expanded)
          unless opened.file? && !named.symlink? && opened.dev == named.dev && opened.ino == named.ino
            raise Error.new("unsafe_archive_path")
          end
          raise Error.new("archive_permissions") unless (opened.mode & 0o777) == 0o600

          snapshot = Tempfile.new(["verified-archive-", ".tar.gz"], snapshot_directory)
          snapshot.binmode
          snapshot.chmod(0o600)
          hasher = Digest::SHA256.new
          source.rewind
          while (chunk = source.read(1024 * 1024))
            snapshot.write(chunk)
            hasher.update(chunk)
          end
          snapshot.flush
          snapshot.fsync
          actual = hasher.hexdigest
          raise Error.new("archive_digest_mismatch") unless actual == expected_digest
          snapshot.rewind
          members = inspect_archive_entries!(snapshot, algorithm)
          VerifiedArchive.new(snapshot, expected_digest, members)
        rescue StandardError
          snapshot.close! if snapshot && !snapshot.closed?
          raise
        ensure
          source.close unless source.closed?
        end
      rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES
        raise Error.new("unsafe_archive_path")
      end

      def verify_open_archive_digest!(archive)
        actual = digest_io(archive.file)
        raise Error.new("archive_digest_mismatch") unless actual == archive.expected_digest
      end

      def digest_io(file)
        file.rewind
        digest = Digest::SHA256.new
        while (chunk = file.read(1024 * 1024))
          digest.update(chunk)
        end
        digest.hexdigest
      ensure
        file.rewind unless file.closed?
      end

      def inspect_archive_entries!(file, algorithm)
        members = []
        total_content = 0
        each_archive_member(file) do |member, entry|
          members << member
          total_content += entry.header.size if member.type == "file"
          raise Error.new("archive_unsafe_entry") if total_content > ARCHIVE_CONTENT_LIMIT
        end
        validate_manifest!(members, algorithm)
        members
      end

      def each_archive_member(file)
        global_attributes = {}
        next_attributes = nil
        header_count = 0
        pax_bytes = 0
        with_tar_reader(file) do |archive|
          archive.each do |entry|
            header_count += 1
            raise Error.new("archive_unsafe_entry") if header_count > ARCHIVE_HEADER_LIMIT
            typeflag = entry.header.typeflag
            if typeflag == "x"
              raise Error.new("archive_unsafe_entry") if next_attributes
              pax_bytes += entry.header.size
              raise Error.new("archive_unsafe_entry") if pax_bytes > PAX_TOTAL_LIMIT
              next_attributes = parse_pax(entry.read)
              next
            elsif typeflag == "g"
              pax_bytes += entry.header.size
              raise Error.new("archive_unsafe_entry") if pax_bytes > PAX_TOTAL_LIMIT
              merge_pax!(global_attributes, parse_pax(entry.read))
              next
            end

            attributes = global_attributes.dup
            merge_pax!(attributes, next_attributes || {})
            next_attributes = nil
            sparse = attributes.any? do |key, value|
              key.downcase.include?("sparse".b) ||
                (key == "SCHILY.filetype".b && value.downcase == "sparse".b)
            end
            if attributes.key?("size".b) || sparse
              raise Error.new("archive_unsafe_entry")
            end

            material_type = material_type(typeflag)
            if material_type != "file" && entry.header.size != 0
              raise Error.new("archive_unsafe_entry")
            end
            raw_path = attributes.fetch("path".b, entry.full_name).dup.force_encoding(Encoding::BINARY)
            path = normalize_member_path(raw_path, material_type == "directory")
            raw_link = attributes.fetch("linkpath".b, entry.header.linkname.to_s)
            raw_link = raw_link.dup.force_encoding(Encoding::BINARY)
            if material_type == "symlink"
              validate_symlink_target!(path, raw_link)
            elsif !raw_link.empty?
              raise Error.new("archive_unsafe_entry")
            end

            yield ArchiveMember.new(path, material_type, material_type == "symlink" ? raw_link : nil), entry
          end
          raise Error.new("archive_unsafe_entry") if next_attributes
        end
      end

      def with_tar_reader(file)
        file.rewind
        gzip = Zlib::GzipReader.new(file)
        archive = Gem::Package::TarReader.new(gzip)
        yield archive
      rescue Error
        raise
      rescue Gem::Package::TarInvalidError, Zlib::GzipFile::Error, EOFError, IOError
        raise Error.new("archive_invalid")
      ensure
        begin
          if gzip && !gzip.closed?
            begin
              gzip.read
            rescue Zlib::GzipFile::Error, EOFError, IOError
              nil
            end
            gzip.finish
          end
        rescue Zlib::GzipFile::Error, IOError
          nil
        end
        file.rewind unless file.closed?
      end

      def parse_pax(payload)
        payload = payload.dup.force_encoding(Encoding::BINARY)
        raise Error.new("archive_unsafe_entry") if payload.bytesize > PAX_HEADER_LIMIT

        attributes = {}
        offset = 0
        while offset < payload.bytesize
          space = payload.index(" ".b, offset)
          raise Error.new("archive_unsafe_entry") unless space
          length_bytes = payload.byteslice(offset, space - offset)
          raise Error.new("archive_unsafe_entry") unless length_bytes =~ /\A[1-9][0-9]*\z/
          raise Error.new("archive_unsafe_entry") if length_bytes.bytesize > 16
          length = length_bytes.to_i
          if length > payload.bytesize - offset || length <= length_bytes.bytesize + 2
            raise Error.new("archive_unsafe_entry")
          end
          record = payload.byteslice(offset, length)
          unless record && record.bytesize == length && record.end_with?("\n".b)
            raise Error.new("archive_unsafe_entry")
          end
          prefix_size = length_bytes.bytesize + 1
          data = record.byteslice(prefix_size, length - prefix_size - 1)
          equals = data && data.index("=".b)
          raise Error.new("archive_unsafe_entry") unless equals && equals.positive?
          key = data.byteslice(0, equals)
          value = data.byteslice(equals + 1, data.bytesize - equals - 1)
          if key.include?("\0".b) || attributes.key?(key)
            raise Error.new("archive_unsafe_entry")
          end
          attributes[key] = value
          offset += length
        end
        attributes
      end

      def merge_pax!(target, updates)
        updates.each do |key, value|
          value.empty? ? target.delete(key) : target[key] = value
        end
      end

      def material_type(typeflag)
        case typeflag
        when "0", "\0", ""
          "file"
        when "5"
          "directory"
        when "2"
          "symlink"
        else
          # Hardlinks, devices, FIFOs, GNU long-name/link records, and every
          # unknown material type are refused rather than delegated to tar.
          raise Error.new("archive_unsafe_entry")
        end
      end

      def normalize_member_path(raw_path, directory)
        raise Error.new("archive_unsafe_entry") if raw_path.empty? || raw_path.include?("\0".b)
        raise Error.new("archive_unsafe_entry") if raw_path.start_with?(File::SEPARATOR.b)

        components = raw_path.split(File::SEPARATOR.b, -1)
        components.pop if directory && components.last == "".b
        components = components.reject { |component| component == ".".b }
        unsafe = components.empty? || components.any? do |component|
          component.empty? || component == "..".b
        end
        raise Error.new("archive_unsafe_entry") if unsafe

        components.join(File::SEPARATOR.b)
      end

      def validate_symlink_target!(path, target)
        if target.empty? || target.include?("\0".b) || target.start_with?(File::SEPARATOR.b)
          raise Error.new("archive_unsafe_entry")
        end

        stack = path.split(File::SEPARATOR.b, -1)[0...-1]
        target.split(File::SEPARATOR.b, -1).each do |component|
          next if component.empty? || component == ".".b
          if component == "..".b
            raise Error.new("archive_unsafe_entry") if stack.empty?
            stack.pop
          else
            stack << component
          end
        end
      end

      def validate_manifest!(members, algorithm)
        raise Error.new("archive_unsafe_entry") if members.empty?

        by_path = {}
        members.each do |member|
          raise Error.new("archive_unsafe_entry") if by_path.key?(member.path)
          if member.type == "symlink" && algorithm != DirtySnapshot::ALGORITHM
            raise Error.new("archive_unsafe_entry")
          end
          by_path[member.path] = member
        end

        members.each do |member|
          components = member.path.split(File::SEPARATOR.b, -1)
          1.upto(components.length - 1) do |length|
            ancestor = by_path[components.first(length).join(File::SEPARATOR.b)]
            if ancestor && ancestor.type != "directory"
              raise Error.new("archive_unsafe_entry")
            end
          end
        end
      end

      def restore_archive!(archive, scratch, algorithm)
        # Destination safety is algorithm-independent. Legacy algo 3 records
        # still use the platform tar extractor to preserve their original
        # AppleDouble semantics, but must never be allowed to overwrite a
        # tracked path or traverse through a tracked symlink in the clone.
        preflight_destinations!(scratch, archive.members)
        if algorithm == DirtySnapshot::LEGACY_ALGORITHM
          Command.capture(["tar", "-xzf", archive.file.path, "-C", scratch])
          return
        end

        create_archive_directories!(scratch, archive.members)

        observed = []
        each_archive_member(archive.file) do |member, entry|
          observed << member_signature(member)
          extract_regular_file!(scratch, member, entry) if member.type == "file"
        end
        expected = archive.members.map { |member| member_signature(member) }
        raise Error.new("archive_digest_mismatch") unless observed == expected

        symlinks = archive.members.select { |member| member.type == "symlink" }
          .sort { |left, right| left.path.b <=> right.path.b }
        symlinks.each { |member| create_symlink!(scratch, member) }
        symlinks.each { |member| validate_created_symlink!(scratch, member) }
      rescue Error
        raise
      rescue SystemCallError, IOError
        raise Error.new("archive_unsafe_entry")
      end

      def member_signature(member)
        [member.path, member.type, member.link_target]
      end

      def preflight_destinations!(scratch, members)
        members.each do |member|
          components = member.path.split(File::SEPARATOR.b, -1)
          components.each_index do |index|
            path = File.join(scratch.b, *components.first(index + 1))
            stat = lstat_or_nil(path)
            next unless stat
            raise Error.new("archive_unsafe_entry") if index == components.length - 1
            unless stat.directory? && !stat.symlink?
              raise Error.new("archive_unsafe_entry")
            end
          end
        end
      end

      def create_archive_directories!(scratch, members)
        paths = []
        members.each do |member|
          components = member.path.split(File::SEPARATOR.b, -1)
          parent_count = member.type == "directory" ? components.length : components.length - 1
          1.upto(parent_count) do |length|
            paths << components.first(length).join(File::SEPARATOR.b)
          end
        end
        paths.uniq!
        paths.sort_by! { |path| [path.count(File::SEPARATOR) + 1, path.b] }
        paths.each { |path| ensure_directory!(scratch, path) }
      end

      def ensure_directory!(scratch, relative)
        path = File.join(scratch.b, relative.b)
        stat = lstat_or_nil(path)
        if stat
          unless stat.directory? && !stat.symlink?
            raise Error.new("archive_unsafe_entry")
          end
        else
          Dir.mkdir(path, 0o700)
        end
      end

      def extract_regular_file!(scratch, member, entry)
        path = File.join(scratch.b, member.path.b)
        raise Error.new("archive_unsafe_entry") if lstat_or_nil(path)

        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, 0o600) do |output|
          while (chunk = entry.read(64 * 1024)) && !chunk.empty?
            output.write(chunk)
          end
        end
      end

      def create_symlink!(scratch, member)
        path = File.join(scratch.b, member.path.b)
        raise Error.new("archive_unsafe_entry") if lstat_or_nil(path)
        ensure_safe_ancestors!(scratch, member.path)
        File.symlink(member.link_target, path)
        stat = File.lstat(path)
        unless stat.symlink? && File.readlink(path).b == member.link_target.b
          raise Error.new("archive_unsafe_entry")
        end
      end

      def validate_created_symlink!(scratch, member)
        path = File.join(scratch.b, member.path.b)
        root = File.realpath(scratch)
        resolved = File.realpath(path)
        prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
        unless resolved == root || resolved.start_with?(prefix)
          raise Error.new("archive_unsafe_entry")
        end
      rescue Errno::ENOENT, Errno::ELOOP
        raise Error.new("archive_unsafe_entry")
      end

      def ensure_safe_ancestors!(scratch, relative)
        components = relative.split(File::SEPARATOR.b, -1)
        1.upto(components.length - 1) do |length|
          path = File.join(scratch.b, *components.first(length))
          stat = File.lstat(path)
          unless stat.directory? && !stat.symlink?
            raise Error.new("archive_unsafe_entry")
          end
        end
      end

      def lstat_or_nil(path)
        File.lstat(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
    end

    attr_reader :worktree, :archive_root, :index_path

    def self.validate_archive_root!(root)
      expanded = File.realpath(File.expand_path(root))
      _stdout, status = Command.capture(
        ["git", "-C", expanded, "rev-parse", "--show-toplevel"],
        nil,
        true,
        Command::GIT_OPTIONAL_LOCKS_ENV
      )
      raise Error.new("archive_root_inside_git") if status.success?
      raise Error.new("archive_root_permissions") unless (File.stat(expanded).mode & 0o777) == 0o700

      expanded
    rescue Errno::ENOENT, Errno::EACCES
      raise Error.new("invalid_archive_root")
    end

    def self.verify_index(index_path, worktree_id = nil)
      document = IndexStore.new(index_path).read
      records = document.fetch("worktrees")
      records = records.select { |record| record["worktree_id"] == worktree_id } if worktree_id
      raise Error.new("checkpoint_not_found") if records.empty?
      unless records.all? { |record| record["restore_verified"] == true }
        raise Error.new("checkpoint_not_restore_verified")
      end

      verifier = Verifier.new(document)
      records.each { |record| verifier.verify(record) }
      records.length
    end

    EXPECTED_BRANCH_UNSPECIFIED = Object.new.freeze

    def initialize(
      worktree:,
      archive_root:,
      index_path:,
      timestamp: nil,
      expected_dirty_snapshot_digest: nil,
      expected_head: nil,
      expected_branch: EXPECTED_BRANCH_UNSPECIFIED
    )
      @git = GitRunner.new(worktree)
      @worktree = @git.worktree
      ensure_supported_repository!
      @archive_root = prepare_archive_root(archive_root)
      @index_path = File.expand_path(index_path)
      @timestamp = timestamp || default_timestamp
      unless @timestamp =~ /\A[0-9]{8}T[0-9]{6}(?:[0-9]{6})?Z\z/
        raise Error.new("invalid_timestamp")
      end
      @expected_dirty_snapshot_digest = expected_dirty_snapshot_digest
      @expected_head = expected_head
      @expected_branch = expected_branch
      validate_expected_source_state!

      @common_dir = common_dir
      @source_path = repository_source_path
      @repository_id = repository_id
      @worktree_id = Digest::SHA256.hexdigest(@worktree.b)[0, 12]
    end

    def create
      checkpoint_ref = nil
      ref_target = nil
      archive_path = nil
      ref_created = false
      before = DirtySnapshot.new(@worktree).calculate
      head = @git.text("rev-parse", "HEAD")
      branch = @git.try_text("symbolic-ref", "--quiet", "--short", "HEAD")
      ensure_expected_source_state!(before.digest, head, branch)
      checkpoint_ref = "refs/harness-checkpoint/#{@timestamp}/#{@worktree_id}"
      raise Error.new("checkpoint_ref_exists") if @git.try_text("rev-parse", "--verify", checkpoint_ref)

      stash_commit = @git.text("stash", "create")
      ref_target = stash_commit.empty? ? head : stash_commit
      ref_target_kind = stash_commit.empty? ? "head" : "stash_commit"

      untracked_paths = before.entries.select { |entry| entry.status == "??" }.map(&:path)
      archive_path, archive_digest = create_archive(untracked_paths)

      ensure_source_state_unchanged!(before.digest, head, branch)

      zero_object_id = "0" * head.length
      @git.capture("update-ref", checkpoint_ref, ref_target, zero_object_id)
      ref_created = true

      record = {
        "worktree_id" => @worktree_id,
        "worktree_path" => @worktree,
        "checkpoint_timestamp" => @timestamp,
        "head" => head,
        "branch" => branch,
        "dirty_entries" => before.entries.length,
        "checkpoint_ref" => checkpoint_ref,
        "ref_target" => ref_target,
        "ref_target_kind" => ref_target_kind,
        "untracked_archive" => archive_path,
        "untracked_archive_sha256" => archive_digest,
        "untracked_entries" => untracked_paths.length,
        "dirty_snapshot_algo" => before.algorithm,
        "dirty_snapshot_scope" => before.scope.to_h,
        "dirty_snapshot_digest" => before.digest,
        "restore_verified" => false
      }

      metadata = index_metadata
      Verifier.new(metadata.merge("worktrees" => [record])).verify(record)
      ensure_source_state_unchanged!(before.digest, head, branch)
      record["restore_verified"] = true
      IndexStore.new(@index_path).add(metadata, record)
      record
    rescue CommandError => error
      rollback_created_artifacts(checkpoint_ref, ref_target, ref_created, archive_path)
      raise error if error.is_a?(Error)
      raise Error.new(error.code, error.status)
    rescue StandardError
      rollback_created_artifacts(checkpoint_ref, ref_target, ref_created, archive_path)
      raise
    end

    private

    def validate_expected_source_state!
      values = [@expected_dirty_snapshot_digest, @expected_head]
      branch_provided = @expected_branch != EXPECTED_BRANCH_UNSPECIFIED
      return if values.all?(&:nil?) && !branch_provided

      unless values.none?(&:nil?) && branch_provided &&
             @expected_dirty_snapshot_digest =~ /\A[0-9a-f]{64}\z/ &&
             @expected_head =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/ &&
             (@expected_branch.nil? ||
               (@expected_branch.is_a?(String) && !@expected_branch.empty?))
        raise Error.new("invalid_expected_source_state")
      end
    end

    def ensure_expected_source_state!(digest, head, branch)
      return if @expected_dirty_snapshot_digest.nil?
      return if digest == @expected_dirty_snapshot_digest &&
        head == @expected_head && branch == @expected_branch

      raise Error.new("approved_input_changed")
    end

    def ensure_source_state_unchanged!(expected_digest, expected_head, expected_branch)
      current_digest = DirtySnapshot.new(@worktree).calculate.digest
      current_head = @git.text("rev-parse", "HEAD")
      current_branch = @git.try_text("symbolic-ref", "--quiet", "--short", "HEAD")
      return if current_digest == expected_digest &&
        current_head == expected_head && current_branch == expected_branch

      raise Error.new("worktree_changed_during_checkpoint")
    end

    def rollback_created_artifacts(checkpoint_ref, ref_target, ref_created, archive_path)
      if ref_created && checkpoint_ref && ref_target
        current = @git.try_text("rev-parse", "--verify", checkpoint_ref)
        @git.capture("update-ref", "-d", checkpoint_ref, ref_target) if current == ref_target
      end
      return unless archive_path && File.file?(archive_path) && !File.symlink?(archive_path)

      expanded = File.expand_path(archive_path)
      prefix = @archive_root.end_with?(File::SEPARATOR) ? @archive_root : @archive_root + File::SEPARATOR
      File.delete(expanded) if expanded.start_with?(prefix)
    rescue CommandError, SystemCallError
      # Preserve the original failure. Any rollback failure remains visible as
      # an orphan that is not recorded as a completed checkpoint.
      nil
    end

    def ensure_supported_repository!
      inside = @git.try_text("rev-parse", "--is-inside-work-tree")
      bare = @git.try_text("rev-parse", "--is-bare-repository")
      raise Error.new("not_a_git_worktree") unless inside == "true" && bare == "false"
      raise Error.new("unborn_repository") unless @git.try_text("rev-parse", "--verify", "HEAD")
    end

    def prepare_archive_root(root)
      expanded = File.expand_path(root)
      existing_ancestor = expanded
      until File.exist?(existing_ancestor)
        parent = File.dirname(existing_ancestor)
        raise Error.new("invalid_archive_root") if parent == existing_ancestor
        existing_ancestor = parent
      end
      _stdout, status = Command.capture(
        ["git", "-C", existing_ancestor, "rev-parse", "--show-toplevel"],
        nil,
        true,
        Command::GIT_OPTIONAL_LOCKS_ENV
      )
      raise Error.new("archive_root_inside_git") if status.success?

      unless File.exist?(expanded)
        FileUtils.mkdir_p(expanded, mode: 0o700)
        File.chmod(0o700, expanded)
      end
      self.class.validate_archive_root!(expanded)
    end

    def common_dir
      value = @git.text("rev-parse", "--git-common-dir")
      path = value.start_with?(File::SEPARATOR) ? value : File.expand_path(value, @worktree)
      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES
      raise Error.new("invalid_git_common_dir")
    end

    def repository_source_path
      if File.basename(@common_dir) == ".git"
        candidate = File.dirname(@common_dir)
        return File.realpath(candidate) if File.directory?(candidate)
      end
      @worktree
    end

    def repository_id
      basename = File.basename(@source_path).gsub(/[^A-Za-z0-9._-]/, "-")
      basename = "repository" if basename.empty?
      "#{basename}-#{Digest::SHA256.hexdigest(@common_dir.b)[0, 8]}"
    end

    def default_timestamp
      now = Time.now.utc
      now.strftime("%Y%m%dT%H%M%S") + format("%06d", now.usec) + "Z"
    end

    def index_metadata
      {
        "schema_version" => INDEX_SCHEMA,
        "tool_version" => TOOL_VERSION,
        "archive_root" => @archive_root,
        "repository" => {
          "repository_id" => @repository_id,
          "git_common_dir" => @common_dir,
          "source_path" => @source_path
        }
      }
    end

    def create_archive(paths)
      return [nil, nil] if paths.empty?

      paths.each { |path| validate_relative_path!(path) }
      directory = File.join(@archive_root, @repository_id)
      unless File.exist?(directory)
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end
      raise Error.new("unsafe_archive_path") if File.lstat(directory).symlink?
      raise Error.new("unsafe_archive_path") unless File.realpath(directory) == File.expand_path(directory)
      raise Error.new("archive_root_permissions") unless File.directory?(directory)
      raise Error.new("archive_root_permissions") unless (File.stat(directory).mode & 0o777) == 0o700
      final_path = File.join(
        directory,
        "#{@timestamp}-#{@worktree_id}-untracked.tar.gz"
      )
      raise Error.new("archive_exists") if File.exist?(final_path)

      temporary = "#{final_path}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
        # Prefix every -T member so a file name beginning with '-' can never be
        # interpreted as a tar list option by either bsdtar or GNU tar.
        list = paths.map { |path| "./".b + path.b }.join("\0".b) + "\0".b
        Command.capture(
          ["tar", "-czf", temporary, "-C", @worktree, "--null", "-T", "-"],
          list,
          false,
          { "COPYFILE_DISABLE" => "1" }
        )
        File.chmod(0o600, temporary)
        # Publish with a same-directory hard link so a concurrent file at the
        # final name can never be overwritten by rename(2). The temporary link
        # is removed in ensure after the no-clobber publication succeeds.
        begin
          File.link(temporary, final_path)
        rescue Errno::EEXIST
          raise Error.new("archive_exists")
        end
      ensure
        File.delete(temporary) if File.exist?(temporary)
      end
      [final_path, Digest::SHA256.file(final_path).hexdigest]
    rescue CommandError => error
      raise Error.new(error.code, error.status)
    end

    def validate_relative_path!(path)
      normalized = if path.end_with?(File::SEPARATOR.b)
                     path.byteslice(0, path.bytesize - 1)
                   else
                     path
                   end
      components = normalized.b.split(File::SEPARATOR.b, -1)
      unsafe = normalized.empty? || normalized.start_with?(File::SEPARATOR.b) ||
               components.any? { |component| component.empty? || component == ".".b || component == "..".b }
      raise Error.new("unsafe_untracked_path") if unsafe
    end
  end
end

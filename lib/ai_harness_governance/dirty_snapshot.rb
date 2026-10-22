# frozen_string_literal: true

require "digest"
require_relative "git_runner"

module AIHarnessGovernance
  class DirtySnapshot
    LEGACY_ALGORITHM = 3
    ALGORITHM = 4
    SUPPORTED_ALGORITHMS = [LEGACY_ALGORITHM, ALGORITHM].freeze
    EMPTY_SHA256 = Digest::SHA256.hexdigest("")
    HARNESS_ALLOWLIST = [
      ".ai/**",
      "AGENTS.md",
      ".githooks/**",
      ".github/workflows/**"
    ].freeze

    Entry = Struct.new(
      :status,
      :path,
      :origin_path,
      :worktree_type,
      :worktree_sha256,
      :staged_sha256
    )

    Result = Struct.new(:algorithm, :digest, :entries, :scope)

    class ParseError < CommandError
      def initialize
        super("malformed_git_status")
      end
    end

    class Scope
      attr_reader :mode, :paths, :globs

      def self.all
        new("all", [], [])
      end

      def self.custom(globs, paths = [])
        new("custom", paths, globs)
      end

      def self.plan(plan_paths, additional_globs = [])
        new(
          "plan_targets_plus_harness_allowlist",
          plan_paths,
          DirtySnapshot::HARNESS_ALLOWLIST + additional_globs
        )
      end

      def initialize(mode, paths, globs)
        @mode = mode
        @paths = normalize(paths)
        @globs = normalize(globs)
      end

      def all?
        @mode == "all"
      end

      def include?(path)
        return true if all?
        return true if @paths.any? { |candidate| candidate.b == path.b }

        glob_match?(path)
      end

      def glob_match?(path)
        flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
        @globs.any? do |pattern|
          candidates = [pattern.b]
          # Ruby 2.6 treats a trailing ** as one path component. Governance
          # manifests use "directory/**" to mean every descendant.
          candidates << (pattern.byteslice(0, pattern.bytesize - 2) + "**/*".b) if pattern.end_with?("/**".b)
          candidates.any? { |candidate| File.fnmatch(candidate, path.b, flags) }
        end
      end

      def to_h
        {
          "mode" => @mode,
          "paths" => @paths.map { |path| printable(path) },
          "globs" => @globs.map { |glob| printable(glob) }
        }
      end

      private

      def normalize(values)
        Array(values).map do |value|
          string = value.to_s.dup
          string.force_encoding(Encoding::BINARY)
          raise ArgumentError, "scope values cannot contain NUL" if string.include?("\0".b)
          string
        end.uniq.sort
      end

      def printable(value)
        value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end

    attr_reader :worktree, :scope, :algorithm

    def initialize(worktree, scope = Scope.all, algorithm: ALGORITHM)
      @git = GitRunner.new(worktree)
      @worktree = @git.worktree
      @scope = scope
      @algorithm = Integer(algorithm)
      unless SUPPORTED_ALGORITHMS.include?(@algorithm)
        raise ArgumentError, "unsupported dirty snapshot algorithm"
      end
      ensure_worktree!
    end

    def calculate
      entries = parse_status(@git.capture(
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignore-submodules=none"
      )).select do |entry|
        @scope.include?(entry.path) || (entry.origin_path && @scope.include?(entry.origin_path))
      end
      index = parse_index(@git.capture(
        "--literal-pathspecs",
        "ls-files",
        "--stage",
        "-z"
      ))
      blob_cache = {}

      entries.each do |entry|
        entry.worktree_type, entry.worktree_sha256 = worktree_state(entry.path)
        entry.staged_sha256 = staged_digest(entry.path, index, blob_cache)
      end
      entries.sort! { |left, right| left.path.b <=> right.path.b }

      digest = Digest::SHA256.new
      digest.update("ai-harness-governance-dirty-snapshot\0#{@algorithm}\0#{entries.length}\0".b)
      entries.each { |entry| digest.update(canonical_record(entry)) }
      Result.new(@algorithm, digest.hexdigest, entries, @scope)
    end

    private

    def ensure_worktree!
      inside = @git.try_text("rev-parse", "--is-inside-work-tree")
      raise CommandError.new("not_a_git_worktree") unless inside == "true"
    end

    def parse_status(raw)
      return [] if raw.empty?

      nul = "\0".b
      records = raw.split(nul, -1)
      raise ParseError unless records.last == "".b
      records.pop

      entries = []
      index = 0
      while index < records.length
        record = records[index]
        raise ParseError if record.bytesize < 4 || record.getbyte(2) != 32

        status = record.byteslice(0, 2)
        path = record.byteslice(3, record.bytesize - 3)
        raise ParseError if path.nil? || path.empty?

        origin = nil
        if rename_or_copy?(status)
          index += 1
          raise ParseError if index >= records.length || records[index].empty?
          origin = records[index]
        end

        entries << Entry.new(status, path, origin, nil, nil, nil)
        index += 1
      end
      entries
    end

    def rename_or_copy?(status)
      [status.getbyte(0), status.getbyte(1)].any? do |byte|
        byte == "R".ord || byte == "C".ord
      end
    end

    def worktree_state(path)
      absolute = File.join(@worktree.b, path.b)
      stat = File.lstat(absolute)
      return ["f", Digest::SHA256.file(absolute).hexdigest] if stat.file?
      return ["d", directory_digest(absolute)] if stat.directory?
      return ["l", symlink_digest(absolute)] if stat.symlink?

      ["o", EMPTY_SHA256]
    rescue Errno::ENOENT, Errno::ENOTDIR
      ["m", EMPTY_SHA256]
    rescue Errno::EACCES
      raise CommandError.new("unreadable_worktree_entry")
    end

    def symlink_digest(path)
      return EMPTY_SHA256 if @algorithm == LEGACY_ALGORITHM

      target = File.readlink(path).dup.force_encoding(Encoding::BINARY)
      Digest::SHA256.hexdigest(target)
    rescue Errno::EACCES, Errno::EINVAL
      raise CommandError.new("unreadable_worktree_entry")
    end

    # Git reports an untracked nested repository as one directory entry even
    # with --untracked-files=all. Hashing a directory as empty would miss every
    # content change below it, so fold a NUL-delimited recursive tree digest
    # without following symlinks.
    def directory_digest(root)
      records = []
      collect_directory_records(root, "".b, records)
      records.sort_by! { |record| record[0].b }
      digest = Digest::SHA256.new
      records.each do |relative, type, content_digest|
        digest.update(type.b + "\t".b + content_digest.b + "\t".b + relative.b + "\0".b)
      end
      digest.hexdigest
    end

    def collect_directory_records(directory, prefix, records)
      children = Dir.children(directory)
      children.each do |child|
        name = child.dup.force_encoding(Encoding::BINARY)
        relative = prefix.empty? ? name : File.join(prefix, name)
        absolute = File.join(directory.b, name)
        stat = File.lstat(absolute)
        if stat.file?
          records << [relative, "f", Digest::SHA256.file(absolute).hexdigest]
        elsif stat.directory?
          records << [relative, "d", EMPTY_SHA256]
          collect_directory_records(absolute, relative, records)
        elsif stat.symlink?
          records << [relative, "l", symlink_digest(absolute)]
        else
          records << [relative, "o", EMPTY_SHA256]
        end
      end
    rescue Errno::EACCES
      raise CommandError.new("unreadable_worktree_entry")
    end

    def staged_digest(path, index, blob_cache)
      stages = index.fetch(path, [])
      return "-" if stages.empty?

      stage_zero = stages.find { |entry| entry[0] == 0 }
      return blob_digest(stage_zero[1], blob_cache) if stage_zero

      # An unmerged index has stages 1..3 rather than stage 0. Folding their
      # separate content hashes retains change detection without printing paths.
      combined = stages.sort_by { |entry| entry[0] }.map do |stage, object_id|
        "#{stage}\t#{blob_digest(object_id, blob_cache)}\n"
      end.join
      Digest::SHA256.hexdigest(combined)
    end

    def parse_index(raw)
      return {} if raw.empty?

      records = raw.split("\0".b, -1)
      raise ParseError unless records.last == "".b
      records.pop

      records.each_with_object({}) do |record, index|
        tab = record.index("\t".b)
        raise ParseError unless tab
        metadata = record.byteslice(0, tab)
        path = record.byteslice(tab + 1, record.bytesize - tab - 1)
        fields = metadata.split(" ".b)
        raise ParseError unless fields.length == 3 && path && !path.empty?
        raise ParseError unless fields[2] =~ /\A[0-3]\z/

        index[path] ||= []
        index[path] << [fields[2].to_i, fields[1]]
      end
    end

    def blob_digest(object_id, cache)
      cache[object_id] ||= Digest::SHA256.hexdigest(@git.capture("cat-file", "blob", object_id))
    end

    def canonical_record(entry)
      origin = entry.origin_path || "-".b
      fields = if @algorithm == LEGACY_ALGORITHM
                 [
                   entry.status.b,
                   entry.worktree_sha256.b,
                   entry.staged_sha256.b,
                   origin.b,
                   entry.path.b
                 ]
               else
                 [
                   entry.status.b,
                   entry.worktree_type.b,
                   entry.worktree_sha256.b,
                   entry.staged_sha256.b,
                   origin.b,
                   entry.path.b
                 ]
               end
      fields.each_with_object(+"".b) do |field, record|
        record << field.bytesize.to_s.b << ":".b << field
      end
    end
  end
end

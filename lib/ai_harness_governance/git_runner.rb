# frozen_string_literal: true

require "open3"

module AIHarnessGovernance
  class CommandError < StandardError
    attr_reader :code, :status

    def initialize(code, status = nil)
      @code = code
      @status = status
      super(code)
    end
  end

  module Command
    GIT_OPTIONAL_LOCKS_ENV = { "GIT_OPTIONAL_LOCKS" => "0" }.freeze

    module_function

    # Never includes child stdout or stderr in an exception. Git and tar can put
    # file names in diagnostics, and Phase 0 output must be safe to retain.
    def capture(argv, stdin_data = nil, allow_failure = false, environment = {})
      options = {}
      options[:stdin_data] = stdin_data unless stdin_data.nil?
      stdout, _stderr, status = Open3.capture3(environment, *argv, options)
      stdout.force_encoding(Encoding::BINARY)
      return [stdout, status] if allow_failure

      raise CommandError.new("command_failed", status.exitstatus) unless status.success?

      stdout
    rescue Errno::ENOENT
      raise CommandError.new("command_not_found")
    end
  end

  class GitRunner
    attr_reader :worktree

    def initialize(worktree)
      @worktree = File.realpath(File.expand_path(worktree))
    rescue Errno::ENOENT, Errno::EACCES
      raise CommandError.new("invalid_worktree")
    end

    def capture(*arguments)
      Command.capture(
        ["git", "-C", @worktree] + arguments,
        nil,
        false,
        Command::GIT_OPTIONAL_LOCKS_ENV
      )
    end

    def try_capture(*arguments)
      stdout, status = Command.capture(
        ["git", "-C", @worktree] + arguments,
        nil,
        true,
        Command::GIT_OPTIONAL_LOCKS_ENV
      )
      status.success? ? stdout : nil
    end

    def text(*arguments)
      capture(*arguments).sub(/\n\z/, "")
    end

    def try_text(*arguments)
      value = try_capture(*arguments)
      value && value.sub(/\n\z/, "")
    end
  end
end

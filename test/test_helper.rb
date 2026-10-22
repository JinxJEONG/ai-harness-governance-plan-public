# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

module RepositoryTestHelper
  def git(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", directory, *arguments)
    return stdout if status.success?

    raise "git failed (#{arguments.first}): #{stderr}"
  end

  def initialize_repository(directory)
    FileUtils.mkdir_p(directory)
    _stdout, _stderr, status = Open3.capture3("git", "init", "-q", "-b", "main", directory)
    unless status.success?
      git(directory, "init", "-q")
      git(directory, "checkout", "-q", "-b", "main")
    end
    git(directory, "config", "user.email", "phase0@example.invalid")
    git(directory, "config", "user.name", "Phase Zero Test")
    write_file(directory, "tracked.txt", "baseline\n")
    git(directory, "add", "tracked.txt")
    git(directory, "commit", "-q", "-m", "baseline")
    directory
  end

  def write_file(directory, relative_path, content)
    path = File.join(directory, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def with_repository
    Dir.mktmpdir("phase0-test-") do |directory|
      repository = File.join(directory, "repository")
      initialize_repository(repository)
      yield directory, repository
    end
  end
end

class Minitest::Test
  include RepositoryTestHelper
end

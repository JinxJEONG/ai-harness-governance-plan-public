# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

RUBY_FILES = FileList[
  "Rakefile",
  "bin/*",
  "lib/**/*.rb",
  "test/**/*_test.rb",
  "test/test_helper.rb"
]

desc "Check Ruby syntax with the active (minimum supported: 2.6) interpreter"
task :syntax do
  RUBY_FILES.each do |path|
    sh RbConfig.ruby, "-c", path
  end
end

Rake::TestTask.new(:test) do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

task default: %i[syntax test]

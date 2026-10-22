# frozen_string_literal: true

require "pathname"
require "uri"
require "yaml"
require_relative "test_helper"

class DocumentationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def markdown_files
    Dir[
      File.join(ROOT, "*.md"),
      File.join(ROOT, "docs", "**", "*.md"),
      File.join(ROOT, "evidence", "**", "*.md"),
    ].sort
  end

  def test_all_yaml_front_matter_parses_as_a_mapping
    markdown_files.each do |path|
      content = read_markdown(path)
      next unless content.start_with?("---\n")

      closing = content.index("\n---\n", 4)
      refute_nil closing, "missing closing front matter delimiter: #{relative(path)}"
      document = YAML.safe_load(
        content.slice(4...closing),
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false,
      )
      assert_kind_of Hash, document, "front matter must be a mapping: #{relative(path)}"
    rescue Psych::Exception => error
      flunk "invalid front matter in #{relative(path)}: #{error.message}"
    end
  end

  def test_all_relative_markdown_links_resolve
    markdown_files.each do |path|
      content = read_markdown(path)
      content.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |raw_target|
        target = raw_target.strip.sub(/\A<(.+)>\z/, "\\1")
        next if target.empty? || target.start_with?("#")
        next if target.match?(/\A(?:https?:|mailto:)/)

        target = URI::DEFAULT_PARSER.unescape(target.split("#", 2).first.split("?", 2).first)
        resolved = File.expand_path(target, File.dirname(path))
        assert File.exist?(resolved), "broken link #{raw_target.inspect} in #{relative(path)}"
      end
    end
  end

  def test_phase_documents_keep_the_eight_standard_sections
    Dir[File.join(ROOT, "docs", "phases", "PHASE_*.md")].sort.each do |path|
      content = read_markdown(path)
      (1..8).each do |number|
        assert_match(/^## #{number}\. /, content, "missing section #{number} in #{relative(path)}")
      end
    end
  end

  private

  def read_markdown(path)
    content = File.binread(path).dup.force_encoding(Encoding::UTF_8)
    assert content.valid_encoding?, "markdown must be valid UTF-8: #{relative(path)}"
    content
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
  end
end

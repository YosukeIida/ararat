#!/usr/bin/env ruby
require 'psych'

def unpinned_uses(node)
  if node.is_a?(Psych::Nodes::Mapping)
    node.children.each_slice(2) do |key, value|
      next unless key.is_a?(Psych::Nodes::Scalar) && key.value == 'uses'
      next if value.is_a?(Psych::Nodes::Scalar) && value.value.match?(/\A[^@\s]+@[0-9a-fA-F]{40}\z/)

      yield key.start_line + 1
    end
  end
  (node.children || []).each { |child| unpinned_uses(child) { |line| yield line } }
end

paths = ARGV.empty? ? Dir.glob(File.join(__dir__, '../workflows/*.{yml,yaml}')) : ARGV
ok = !paths.empty?
warn 'No workflow files found' unless ok
paths.each do |path|
  unpinned_uses(Psych.parse_file(path)) do |line|
    warn "#{path}:#{line}: uses must pin a full 40-hex commit SHA"
    ok = false
  end
end
exit ok

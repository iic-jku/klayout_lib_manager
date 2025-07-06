#!/usr/bin/env ruby
require "json"

# 1) Read JSON mapping: lib_name → gds_path
json_path = File.expand_path("libs.json", __dir__)
unless File.exist?(json_path)
  abort "❌ libs.json not found at #{json_path}"
end

raw = JSON.parse(File.read(json_path))
unless raw.is_a?(Hash) && raw.any?
  abort "❌ libs.json must contain a non-empty object mapping library names to GDS paths"
end

# 2) Ensure GUI context
app = RBA::Application.instance
mw  = app.main_window
abort "❌ This script must be run in GUI mode: klayout -rm load_libs.rb" if mw.nil?

# 3) Register each library
raw.each do |lib_name, gds_path|
  # Check lib_name
  if lib_name.nil? || lib_name.strip.empty?
    warn "⚠️  Skipping entry with missing or empty library name for path: #{gds_path.inspect}"
    next
  end

  # Check gds_path existence
  unless gds_path.is_a?(String) && File.exist?(gds_path)
    warn "⚠️  File for library '#{lib_name}' not found: #{gds_path.inspect}"
    next
  end

  # Register the library
  lib = RBA::Library.new
  lib._create
  lib.description = "GDS library #{lib_name}"
  lib.layout.read(gds_path)
  lib.register(lib_name)
  puts "🔗 Registered ‘#{lib_name}’ → #{gds_path}"
end

puts "✅ All valid libraries from libs.json have been registered."

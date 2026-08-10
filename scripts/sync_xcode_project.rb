#!/usr/bin/env ruby
# Sync all Swift source files into the ZuTalk Xcode project
# Ensures every .swift file on disk is referenced by the correct target

require 'xcodeproj'
require 'pathname'

project_path = File.join(__dir__, '..', 'macos', 'ZuTalk', 'ZuTalk.xcodeproj')
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'ZuTalk' }
test_target = project.targets.find { |t| t.name == 'ZuTalkTests' }

unless app_target
  puts "ERROR: ZuTalk target not found"
  exit 1
end

# 使用 group 的 name 或 path 查找已有引用，避免创建重复 group。

project_dir = File.dirname(project_path)
source_dir = File.join(project_dir, 'ZuTalk')
test_dir = File.join(project_dir, 'ZuTalkTests')

# Helper: find or create nested group matching directory structure
# new_group(part, part) 可能只有 path，因此查询时同时检查 name 和 path。
def find_or_create_group(parent_group, relative_path, full_path)
  parts = relative_path.split('/')
  current = parent_group
  parts.each do |part|
    child = current.groups.find { |g| (g.name || g.path) == part }
    unless child
      child = current.new_group(part, part)
      puts "  Created group: #{part}"
    end
    current = child
  end
  current
end

# Collect existing file references in target
def existing_files_in_target(target)
  target.source_build_phase.files.map { |f| f.file_ref&.real_path&.to_s }.compact.to_set
rescue
  Set.new
end

# --- Sync app target ---
# ZuTalk/ 是 PBXFileSystemSynchronizedRootGroup；Xcode 会自动包含其中的
# Swift 文件，因此主 app 不再额外写入显式 build file。
puts "=== Syncing ZuTalk target ==="
puts "  (no-op: ZuTalk/ is a PBXFileSystemSynchronizedRootGroup;"
puts "   new .swift files are auto-picked up by Xcode)"
added_app = 0

# --- Sync test target ---
puts "\n=== Syncing ZuTalkTests target ==="

test_group = project.main_group.groups.find { |g| (g.name || g.path) == 'ZuTalkTests' }
unless test_group
  test_group = project.main_group.new_group('ZuTalkTests', 'ZuTalkTests')
  puts "Created ZuTalkTests group"
end

existing_test_files = Set.new
test_target&.source_build_phase&.files&.each do |bf|
  name = bf.file_ref&.name || bf.file_ref&.path
  existing_test_files.add(name) if name
end

added_test = 0
Dir.glob(File.join(test_dir, '*.swift')).each do |file|
  basename = File.basename(file)
  next if existing_test_files.include?(basename)

  file_ref = test_group.new_reference(basename)
  test_target.source_build_phase.add_file_reference(file_ref) if test_target
  puts "  Added to ZuTalkTests: #{basename}"
  added_test += 1
end

# --- Create ZuTalk scheme if missing ---
schemes_dir = File.join(project_path, 'xcshareddata', 'xcschemes')
zutalk_scheme = File.join(schemes_dir, 'ZuTalk.xcscheme')
unless File.exist?(zutalk_scheme)
  puts "\n=== Creating ZuTalk scheme ==="
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(app_target)
  scheme.set_launch_target(app_target)
  FileUtils.mkdir_p(schemes_dir)
  scheme.save_as(project_path, 'ZuTalk')
  puts "  Created ZuTalk.xcscheme"
end

project.save

puts "\n=== Done ==="
puts "App target: #{added_app} files added"
puts "Test target: #{added_test} files added"

#!/usr/bin/env ruby

path = ARGV.fetch(0) do
  abort "usage: #{$PROGRAM_NAME} /path/to/vt_ffi.swift"
end

content = File.read(path)

helper = <<~SWIFT
  public func uniffiVtFfiInitializationError() -> String? {
      switch initializationResult {
      case .ok:
          return nil
      case .contractVersionMismatch:
          return "UniFFI contract version mismatch: rebuild and redeploy Zulangue."
      case .apiChecksumMismatch:
          return "UniFFI API checksum mismatch: rebuild and redeploy Zulangue."
      }
  }

SWIFT

marker = <<~SWIFT
  // Make the ensure init function public so that other modules which have external type references to
  // our types can call it.
SWIFT

unless content.include?("public func uniffiVtFfiInitializationError() -> String? {")
  content.sub!(marker, helper + marker) or abort "failed to find init marker in #{path}"
end

old_ensure = <<~SWIFT
  public func uniffiEnsureVtFfiInitialized() {
      switch initializationResult {
      case .ok:
          break
      case .contractVersionMismatch:
          fatalError("UniFFI contract version mismatch: try cleaning and rebuilding your project")
      case .apiChecksumMismatch:
          fatalError("UniFFI API checksum mismatch: try cleaning and rebuilding your project")
      }
  }
SWIFT

new_ensure = <<~SWIFT
  public func uniffiEnsureVtFfiInitialized() {
      if let error = uniffiVtFfiInitializationError() {
          fatalError(error)
      }
  }
SWIFT

unless content.include?(new_ensure)
  content.sub!(old_ensure, new_ensure) or abort "failed to patch ensure init in #{path}"
end

File.write(path, content)

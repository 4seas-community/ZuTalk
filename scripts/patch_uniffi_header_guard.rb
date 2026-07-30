#!/usr/bin/env ruby
#
# UniFFI emits `#pragma once` at the top of the generated C header. When the
# header is exposed through a clang module map (`vt_ffiFFI.modulemap`), clang
# compiles it as a "main file" and warns:
#
#   warning: #pragma once in main file
#
# Replace `#pragma once` with a conventional include guard so the warning stops
# and we still get idempotent inclusion.

path = ARGV.fetch(0) do
  abort "usage: #{$PROGRAM_NAME} /path/to/vt_ffiFFI.h"
end

content = File.read(path, encoding: "UTF-8")
guard = "VT_FFI_FFI_H_"

# Already patched? — bail out.
exit 0 if content.include?("#ifndef #{guard}")

unless content.sub!(
  /^#pragma once\s*$/,
  "#ifndef #{guard}\n#define #{guard}"
)
  abort "failed to find `#pragma once` in #{path}"
end

content = content.rstrip + "\n#endif // #{guard}\n"

File.write(path, content)

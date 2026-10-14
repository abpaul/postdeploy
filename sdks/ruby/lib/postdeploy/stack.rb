# frozen_string_literal: true

module PostDeploy
  # Maps a Ruby backtrace to the wire `frames[]` shape
  # (`{file, function, lineno, in_app}`) with in-app vs library detection.
  #
  # Prefers `Exception#backtrace_locations` (structured, available since
  # Ruby 2.0) over parsing `#backtrace` strings; falls back to string
  # parsing only for backtraces that don't expose locations (e.g. a
  # synthetic backtrace assigned by hand).
  module Stack
    # Path fragments that mark a frame as library code regardless of
    # `app_dirs`: installed gems, the Ruby stdlib, and common version
    # manager layouts. Checked before `app_dirs`, so a gem vendored inside
    # the app directory is still treated as library code.
    LIBRARY_MARKERS = [
      "/gems/",
      "/lib/ruby/",
      "/vendor/bundle/",
      "/.rbenv/",
      "/.rvm/",
      "/.asdf/",
      "<internal:"
    ].freeze

    LINE_PATTERN = /\A(.+):(\d+):in [`'"](.+)['"]\z/.freeze

    # Longest source line kept in `pre_context`/`context_line`/
    # `post_context` (issue: source-context frames) -- a single absurdly
    # long line (minified/generated code) is truncated rather than blowing
    # up the envelope.
    MAX_SOURCE_LINE_CHARS = 500

    # Per-process cache of a source file's lines. A deep in-app backtrace,
    # or an error storm, otherwise re-reads the same files on the capturing
    # thread on every event. Source does not change within a process, so
    # each file is read at most once. Bounded (FIFO eviction) so it cannot
    # grow without limit.
    MAX_CACHED_SOURCE_FILES = 256
    SOURCE_CACHE = {}
    SOURCE_CACHE_MUTEX = Mutex.new
    private_constant :SOURCE_CACHE, :SOURCE_CACHE_MUTEX

    module_function

    # `context_lines:` (default `0`, i.e. disabled) is `config.context_lines`
    # at call sites -- see `Envelope.exception_item`. Source context is only
    # ever attached to `in_app` frames: library/gem frames have no value to
    # a host app's developer and reading arbitrary gem source is wasted
    # work.
    def frames_for(exception, app_dirs: [], context_lines: 0)
      locations = exception.respond_to?(:backtrace_locations) ? exception.backtrace_locations : nil
      if locations
        locations.map { |loc| build_frame(loc.path, loc.lineno, loc.label, app_dirs, context_lines) }
      else
        Array(exception.backtrace).filter_map { |line| frame_from_line(line, app_dirs, context_lines) }
      end
    end

    def build_frame(path, lineno, label, app_dirs, context_lines = 0)
      in_app = in_app?(path, app_dirs)
      frame = { file: path, lineno: lineno, function: label, in_app: in_app }
      frame.merge!(source_context(path, lineno, context_lines)) if in_app && context_lines.to_i.positive?
      frame.compact
    end

    def frame_from_line(line, app_dirs, context_lines = 0)
      match = LINE_PATTERN.match(line)
      return nil unless match

      build_frame(match[1], match[2].to_i, match[3], app_dirs, context_lines)
    end

    # Reads `context_lines` lines before/after `lineno` (1-indexed, as
    # backtraces report it) from `path`. Returns `{}` (attaching nothing)
    # for a missing/unreadable file or an out-of-range line number --
    # never raises, matching every other fail-safe boundary in this SDK.
    def source_context(path, lineno, context_lines)
      return {} unless path && File.file?(path) && File.readable?(path)

      lines = cached_source_lines(path)
      index = lineno - 1
      return {} unless index >= 0 && index < lines.length

      start_index = [index - context_lines, 0].max
      end_index = [index + context_lines, lines.length - 1].min

      {
        pre_context: lines[start_index...index].map { |line| cap_source_line(line) },
        context_line: cap_source_line(lines[index]),
        post_context: lines[(index + 1)..end_index].map { |line| cap_source_line(line) }
      }
    rescue StandardError
      {}
    end

    # Returns `path`'s lines, reading from disk at most once per process.
    # FIFO-evicts the oldest entry past the cap. Holds the mutex across the
    # read so concurrent captures of the same file do not each read it.
    def cached_source_lines(path)
      SOURCE_CACHE_MUTEX.synchronize do
        return SOURCE_CACHE[path] if SOURCE_CACHE.key?(path)

        lines = File.readlines(path)
        SOURCE_CACHE[path] = lines
        SOURCE_CACHE.shift if SOURCE_CACHE.size > MAX_CACHED_SOURCE_FILES
        lines
      end
    end

    def cap_source_line(line)
      line = line.chomp
      line.length > MAX_SOURCE_LINE_CHARS ? line[0, MAX_SOURCE_LINE_CHARS] : line
    end

    def in_app?(path, app_dirs)
      return false if path.nil?
      return false if LIBRARY_MARKERS.any? { |marker| path.include?(marker) }
      return true if app_dirs.empty?

      app_dirs.any? { |dir| path.start_with?(dir.to_s) }
    end
  end
end

# frozen_string_literal: true

module PostDeploy
  # Mandatory PII scrubbing runs before `config.before_send` so callbacks see
  # redacted values, and again immediately before serialization so callbacks
  # and PendingWindow cannot add secrets after the capture-time pass.
  # Deep-walks `context`/`contexts`/`tags`/`user` (nested hashes and
  # arrays) and replaces any value whose key matches `config.scrub_fields`
  # (case-insensitive substring match, so `"user_password"` is caught by
  # the `"password"` entry) with `"[FILTERED]"`.
  #
  # Runs against the already-built wire item hash (post `Envelope.*_item`),
  # not the raw call-site args. The two boundary passes keep callback
  # visibility safe while ensuring late breadcrumb additions are scrubbed.
  module Scrubber
    DEFAULT_SCRUB_FIELDS = %w[
      password passwd secret token authorization api_key apikey
      access_token cookie csrf ssn credit_card card_number
    ].freeze

    REDACTED = "[FILTERED]"
    # `breadcrumbs` is included so structured secrets in a crumb's `data`
    # hash (and any secret-keyed value an integration adds) are redacted.
    # A crumb's free-text `message` is NOT value-scrubbed -- key-based
    # scrubbing cannot see into an arbitrary string, same as Sentry. Do
    # not put a raw secret in a breadcrumb message.
    SCRUBBED_KEYS = %i[context contexts tags user breadcrumbs].freeze

    module_function

    # Returns a new item hash with sensitive values redacted. Never raises:
    # an internal error returns the item unscrubbed rather than drop a real
    # event over a scrubbing bug -- capture must not be less reliable than
    # scrubbing is broken.
    def scrub(item, fields)
      return item if fields.nil? || fields.empty?

      normalized_fields = fields.map { |f| f.to_s.downcase }
      scrubbed = SCRUBBED_KEYS.each_with_object({}) do |key, out|
        next unless item.key?(key)

        out[key] = deep_scrub(item[key], normalized_fields)
      end
      item.merge(scrubbed)
    rescue StandardError
      item
    end

    def deep_scrub(value, fields)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), out|
          out[key] = sensitive_key?(key, fields) ? REDACTED : deep_scrub(val, fields)
        end
      when Array
        value.map { |v| deep_scrub(v, fields) }
      else
        value
      end
    end

    def sensitive_key?(key, fields)
      normalized_key = key.to_s.downcase
      fields.any? { |field| normalized_key.include?(field) }
    end
  end
end

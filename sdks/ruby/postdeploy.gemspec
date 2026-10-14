# frozen_string_literal: true

require_relative "lib/postdeploy/version"

Gem::Specification.new do |spec|
  spec.name = "postdeploy"
  spec.version = PostDeploy::VERSION
  spec.authors = ["PostDeploy"]
  spec.email = ["support@postdeploy.dev"]

  spec.summary = "Ruby instrumentation for PostDeploy"
  spec.description = "Captures errors and operational signals for PostDeploy's production toolkit " \
                      "ingest endpoint, with an optional Rails railtie for automatic unhandled-exception capture."
  spec.homepage = "https://postdeploy.dev"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  # The source lives in the private PostDeploy monorepo, so the published gem
  # points at the product site rather than a repository URL.
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://postdeploy.dev/docs/observe/ruby"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb"] + %w[README.md LICENSE]
  end.select { |f| File.exist?(f) }
  spec.require_paths = ["lib"]

  # Zero runtime dependencies by design (Net::HTTP + stdlib only), matching
  # the JS SDK's own "ships to third-party production apps" constraint.

  # `bundle exec rake release` (bundler's gem tasks) is the documented release
  # path, driven by rubygems/release-gem in .github/workflows/release.yml.
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "rack", "~> 3.0"
  spec.add_development_dependency "rack-test", "~> 2.1"
  # Dev-only, to exercise the railtie against a real middleware stack
  # (spec/postdeploy/railtie_spec.rb) — never a runtime dependency.
  spec.add_development_dependency "railties", "~> 7.1"
  spec.add_development_dependency "actionpack", "~> 7.1"
  # Dev-only, to exercise the OPTIONAL Sidekiq/ActiveJob integrations
  # against the real libraries (spec/postdeploy/sidekiq_spec.rb,
  # spec/postdeploy/active_job_spec.rb) — the integrations themselves only
  # activate when `defined?(Sidekiq)`/`defined?(ActiveJob)` is true at
  # runtime in the HOST app; this gem never requires either.
  spec.add_development_dependency "sidekiq", "~> 7.3"
  spec.add_development_dependency "activejob", "~> 7.1"
end

# frozen_string_literal: true

module PostDeploy
  # In-memory recorder for host tests. Start with `config.test_mode = true`.
  #
  #   PostDeploy.configure { |c| c.test_mode = true }
  #   PostDeploy.capture_exception(error)
  #   PostDeploy.flush
  #   item = PostDeploy::Testing.events.first
  module Testing
    def self.events
      Array(transport&.envelopes).flat_map { |envelope| envelope[:items] || [] }
    end

    def self.sessions
      Array(transport&.session_envelopes).flat_map { |envelope| envelope[:items] || [] }
    end

    def self.reset!
      PostDeploy.reset!
    end

    def self.transport
      PostDeploy.initialized_client&.transport
    end
    private_class_method :transport
  end
end

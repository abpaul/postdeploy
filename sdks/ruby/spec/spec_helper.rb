# frozen_string_literal: true

require "webmock/rspec"
require "postdeploy"

WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    PostDeploy.reset!
    PostDeploy.configure do |c|
      c.key = "alp_p_test_key"
      c.environment = "test"
      c.release = "v1.0.0-test"
    end
  end
end

# frozen_string_literal: true

can_forward = ENV.fetch('CAN_FORWARD_REPORTS', '').split(/\s*,\s*/)

Rails.application.configure do
  config.x.can_forward_reports = can_forward
end

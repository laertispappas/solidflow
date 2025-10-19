# frozen_string_literal: true

module SolidFlow
  module Instrumentation
    module_function

    def subscribe(logger: SolidFlow.logger)
      ActiveSupport::Notifications.subscribe(/solidflow\./) do |event_name, start, finish, _id, payload|
        next unless logger

        duration = (finish - start) * 1000.0
        logger.info("[#{event_name}] (#{format('%.1fms', duration)}) #{payload.compact}")
      end
    end
  end
end

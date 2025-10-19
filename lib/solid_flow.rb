# frozen_string_literal: true

require "logger"
require "active_support"
require "active_support/core_ext/module"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/object/deep_dup"
require "active_support/notifications"
require "active_support/time"
require "zeitwerk"
require "securerandom"
require "thread"
require "digest"

loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/solidflow.rb")
loader.ignore("#{__dir__}/../app")
loader.setup

require "solid_flow/engine" if defined?(Rails::Engine)

module SolidFlow
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def logger
      configuration.logger
    end

    def store
      configuration.store
    end

    def task_registry
      configuration.task_registry
    end

    def instrument(event, payload = {})
      ActiveSupport::Notifications.instrument(event, payload)
    end
  end

  # Minimal dependency injection container for runtime components.
  class Configuration
    attr_accessor :logger,
                  :event_serializer,
                  :store,
                  :task_registry,
                  :workflow_registry,
                  :default_execution_queue,
                  :default_task_queue,
                  :default_timer_queue,
                  :time_provider,
                  :id_generator

    def initialize
      @logger                 = Logger.new($stdout, level: Logger::INFO)
      @event_serializer       = Serializers::Oj.new
      @workflow_registry      = Registries::WorkflowRegistry.new
      @task_registry          = Registries::TaskRegistry.new
      @default_execution_queue = "solidflow"
      @default_task_queue      = "solidflow_tasks"
      @default_timer_queue     = "solidflow_timers"
      @time_provider          = -> { Time.current }
      @id_generator           = -> { SecureRandom.uuid }
      @store                  = Stores::ActiveRecord.new(event_serializer: @event_serializer,
                                                        time_provider: @time_provider,
                                                        logger: @logger)
    end
  end
end

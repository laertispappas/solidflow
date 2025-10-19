# frozen_string_literal: true

module SolidFlow
  module Registries
    class WorkflowRegistry
      def initialize
        @mutex = Mutex.new
        @workflows = {}
      end

      def register(name, klass)
        @mutex.synchronize do
          @workflows.delete_if { |_key, value| value == klass }
          @workflows[name.to_s] = klass
        end
      end

      def fetch(name)
        @workflows.fetch(name.to_s)
      rescue KeyError
        raise Errors::ConfigurationError, "Workflow #{name} is not registered"
      end

      def resolve(klass)
        @workflows.key(klass)
      end

      def to_h
        @workflows.dup
      end
    end
  end
end

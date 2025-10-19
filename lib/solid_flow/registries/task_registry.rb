# frozen_string_literal: true

module SolidFlow
  module Registries
    class TaskRegistry
      def initialize
        @mutex = Mutex.new
        @tasks = {}
      end

      def register(name, klass)
        @mutex.synchronize do
          @tasks[name.to_sym] = klass
        end
      end

      def fetch(name)
        @tasks.fetch(name.to_sym)
      rescue KeyError
        raise Errors::ConfigurationError, "Task #{name} is not registered"
      end

      def resolve(klass)
        @tasks.key(klass)
      end

      def to_h
        @tasks.dup
      end
    end
  end
end

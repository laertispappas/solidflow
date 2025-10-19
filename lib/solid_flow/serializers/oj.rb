# frozen_string_literal: true

require "oj"

module SolidFlow
  module Serializers
    # Wrapper for Oj to provide consistent serialization configuration.
    class Oj
      def initialize(mode: :strict)
        @mode = mode
      end

      def dump(object)
        ::Oj.dump(object, mode: @mode)
      end

      def load(json)
        return {} if json.nil? || json.empty?

        ::Oj.load(json, mode: @mode, symbol_keys: false)
      end
    end
  end
end

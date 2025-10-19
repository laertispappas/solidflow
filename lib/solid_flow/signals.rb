# frozen_string_literal: true

module SolidFlow
  module Signals
    Message = Struct.new(
      :name,
      :payload,
      :metadata,
      :received_at,
      :consumed,
      keyword_init: true
    ) do
      def consumed?
        consumed
      end

      def consume!
        self.consumed = true
      end
    end

    # In-memory signal buffer used during replay to determine if waits can proceed.
    class Buffer
      def initialize(messages = [])
        @messages = messages
      end

      def push(message)
        @messages << message
      end

      def consume(name)
        entry = @messages.find { |m| m.name == name.to_sym && !m.consumed? }
        entry&.consume!
        entry
      end

      def pending?(name)
        @messages.any? { |m| m.name == name.to_sym && !m.consumed? }
      end

      def to_a
        @messages.map(&:dup)
      end
    end
  end
end

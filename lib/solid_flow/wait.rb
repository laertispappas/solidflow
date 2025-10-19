# frozen_string_literal: true

module SolidFlow
  module Wait
    class Instruction
      attr_reader :type, :options

      def initialize(type, options)
        @type = type
        @options = options
      end

      def to_h
        { type:, options: options }
      end
    end

    class TimerInstruction < Instruction
      def initialize(options)
        super(:timer, options)
      end
    end

    class SignalInstruction < Instruction
      def initialize(options)
        super(:signal, options)
      end
    end

    class Context
      attr_reader :instructions

      def initialize
        @instructions = []
      end

      def for(seconds: nil, timestamp: nil, at: nil, metadata: {})
        metadata_payload =
          case metadata
          when Hash
            metadata.deep_dup
          else
            metadata
          end
        options = { metadata: metadata_payload }
        if seconds
          raise ArgumentError, "seconds must be positive" unless seconds.to_f.positive?

          options[:delay_seconds] = seconds.to_f
        elsif at || timestamp
          target = at || timestamp
          options[:run_at] = target
        else
          raise ArgumentError, "wait.for requires :seconds or :timestamp"
        end

        instruction = TimerInstruction.new(options)
        @instructions << instruction
        instruction
      end

      def for_signal(name, metadata: {})
        metadata_payload =
          case metadata
          when Hash
            metadata.deep_dup
          else
            metadata
          end
        instruction = SignalInstruction.new(signal: name.to_sym, metadata: metadata_payload)
        @instructions << instruction
        instruction
      end
    end
  end
end

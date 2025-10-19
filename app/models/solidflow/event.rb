# frozen_string_literal: true

module SolidFlow
  class Event < ApplicationRecord
    self.table_name = "solidflow_events"

    belongs_to :execution,
               class_name: "SolidFlow::Execution",
               inverse_of: :events

    scope :ordered, -> { order(:sequence) }

    def to_replay_event
      Replay::Event.new(
        id: id,
        type: event_type,
        sequence: sequence,
        payload: payload,
        recorded_at: recorded_at
      )
    end
  end
end

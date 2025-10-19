# frozen_string_literal: true

module SolidFlow
  class Execution < ApplicationRecord
    self.table_name = "solidflow_executions"

    has_many :events,
             class_name: "SolidFlow::Event",
             foreign_key: :execution_id,
             inverse_of: :execution,
             dependent: :destroy

    has_many :timers,
             class_name: "SolidFlow::Timer",
             foreign_key: :execution_id,
             inverse_of: :execution,
             dependent: :destroy

    has_many :signal_messages,
             class_name: "SolidFlow::SignalMessage",
             foreign_key: :execution_id,
             inverse_of: :execution,
             dependent: :destroy

    enum state: {
      running: "running",
      completed: "completed",
      failed: "failed",
      cancelled: "cancelled"
    }

    def ctx_hash
      (self[:ctx] || {}).with_indifferent_access
    end
  end
end

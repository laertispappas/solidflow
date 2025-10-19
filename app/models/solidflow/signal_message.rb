# frozen_string_literal: true

module SolidFlow
  class SignalMessage < ApplicationRecord
    self.table_name = "solidflow_signal_messages"

    belongs_to :execution,
               class_name: "SolidFlow::Execution",
               inverse_of: :signal_messages

    enum status: {
      pending: "pending",
      consumed: "consumed"
    }
  end
end

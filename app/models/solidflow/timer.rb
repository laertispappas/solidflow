# frozen_string_literal: true

module SolidFlow
  class Timer < ApplicationRecord
    self.table_name = "solidflow_timers"

    belongs_to :execution,
               class_name: "SolidFlow::Execution",
               inverse_of: :timers

    enum status: {
      scheduled: "scheduled",
      fired: "fired",
      cancelled: "cancelled"
    }

    scope :due, ->(now = Time.current) { scheduled.where("run_at <= ?", now) }
  end
end

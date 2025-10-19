# frozen_string_literal: true

module SolidFlow
  module Jobs
    class TimerSweepJob < ActiveJob::Base
      queue_as do
        SolidFlow.configuration.default_timer_queue
      end

      def perform(batch_size: 100)
        now = SolidFlow.configuration.time_provider.call

        SolidFlow::Timer.transaction do
          SolidFlow::Timer
            .scheduled
            .where("run_at <= ?", now)
            .limit(batch_size)
            .lock("FOR UPDATE SKIP LOCKED")
            .each do |timer|
              SolidFlow.store.mark_timer_fired(timer_id: timer.id)
              SolidFlow.instrument(
                "solidflow.timer.fired",
                execution_id: timer.execution_id,
                timer_id: timer.id,
                step: timer.step
              )
            end
        end
      end
    end
  end
end

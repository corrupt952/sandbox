class SleepJob < ApplicationJob
  queue_as :default

  def perform(wait_time)
    Delayed::Worker.logger.info "start job"
    Kernel.sleep wait_time
    Delayed::Worker.logger.info "end job"
  end
end

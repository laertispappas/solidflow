# frozen_string_literal: true

require "rails/engine"

module SolidFlow
  class Engine < ::Rails::Engine
    isolate_namespace SolidFlow
    engine_name "solidflow"

    initializer "solidflow.active_job" do
      ActiveSupport.on_load(:active_job) do
        queue_adapter # touch to ensure ActiveJob loaded
      end
    end

    initializer "solidflow.append_migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config_file = root.join("db/migrate")
        app.config.paths["db/migrate"].concat([config_file.to_s])
      end
    end
  end
end

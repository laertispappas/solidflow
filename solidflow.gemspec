require_relative "lib/solid_flow/version"

Gem::Specification.new do |spec|
  spec.name          = "solidflow"
  spec.version       = SolidFlow::VERSION
  spec.authors       = ["Laerti Papa"]
  spec.email         = ["laertis.pappas@gmail.com"]

  spec.summary       = "Durable workflows for Ruby & Rails"
  spec.description   = <<~DESC
    SolidFlow provides deterministic workflow orchestration for Ruby on Rails using ActiveJob
    and ActiveRecord. It features event-sourced history, replay, timers, signals, tasks, and SAGA
    compensations designed for production-grade systems.
  DESC
  spec.license       = "MIT"
  spec.homepage      = "https://github.com/laertispappas/solidflow"
  spec.metadata      = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/CHANGELOG.md"
  }

  spec.files         = Dir.glob("lib/**/*") +
                       Dir.glob("app/**/*") +
                       Dir.glob("db/migrate/*.rb") +
                       %w[README.md Rakefile]
  spec.bindir        = "bin"
  spec.executables   = Dir.children("bin") rescue []
  spec.require_paths = ["lib"]

  spec.required_ruby_version = Gem::Requirement.new(">= 3.1")

  spec.add_dependency "activesupport", ">= 7.1", "< 8.0"
  spec.add_dependency "activejob", ">= 7.1", "< 8.0"
  spec.add_dependency "activerecord", ">= 7.1", "< 8.0"
  spec.add_dependency "zeitwerk", "~> 2.6"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "oj", "~> 3.16"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.65"
end

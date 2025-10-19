# frozen_string_literal: true

module SolidFlow
  class ApplicationRecord < ActiveRecord::Base
    primary_abstract_class
  end
end

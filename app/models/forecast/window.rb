class Forecast::Window
  OPTIONS = {
    "week" => {
      label: "Week",
      period: -> { Period.custom(start_date: Date.current.beginning_of_week, end_date: Date.current.end_of_week) },
      interval: "1 day"
    },
    "month" => {
      label: "Month",
      period: -> { Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month) },
      interval: "1 day"
    },
    "year" => {
      label: "Year",
      period: -> { Period.custom(start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year) },
      interval: "1 month"
    }
  }.freeze

  attr_reader :key

  def self.from_key(key)
    new(key.presence_in(OPTIONS.keys) || "month")
  end

  def self.as_options
    OPTIONS.map { |value, config| [ config[:label], value ] }
  end

  def initialize(key)
    @key = key
  end

  def label
    OPTIONS.fetch(key).fetch(:label)
  end

  def period
    OPTIONS.fetch(key).fetch(:period).call
  end

  def interval
    OPTIONS.fetch(key).fetch(:interval)
  end
end

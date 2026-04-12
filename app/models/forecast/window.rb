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

  attr_reader :key, :offset

  def self.from_key(key, offset: 0)
    new(key.presence_in(OPTIONS.keys) || "month", offset: offset)
  end

  def self.as_options
    OPTIONS.map { |value, config| [ config[:label], value ] }
  end

  def initialize(key, offset: 0)
    @key = key
    @offset = offset.to_i
  end

  def label
    OPTIONS.fetch(key).fetch(:label)
  end

  def period
    case key
    when "week"
      start_date = Date.current.beginning_of_week + offset.weeks
      Period.custom(start_date: start_date, end_date: start_date.end_of_week)
    when "month"
      start_date = (Date.current.beginning_of_month >> offset)
      Period.custom(start_date: start_date, end_date: start_date.end_of_month)
    when "year"
      start_date = Date.current.beginning_of_year.advance(years: offset)
      Period.custom(start_date: start_date, end_date: start_date.end_of_year)
    end
  end

  def interval
    OPTIONS.fetch(key).fetch(:interval)
  end

  def range_label
    case key
    when "week"
      "#{I18n.l(period.start_date, format: :long)} - #{I18n.l(period.end_date, format: :long)}"
    when "month"
      period.start_date.strftime("%B %Y")
    when "year"
      period.start_date.strftime("%Y")
    end
  end
end

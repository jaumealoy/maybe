class Forecast::Window
  CUSTOM_INTERVAL_THRESHOLD = 120
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

  attr_reader :key, :offset, :custom_start_date, :custom_end_date

  def self.from_key(key, offset: 0)
    new(key.presence_in(OPTIONS.keys) || "month", offset: offset)
  end

  def self.from_params(key:, offset: 0, start_date: nil, end_date: nil)
    parsed_start_date = parse_date(start_date)
    parsed_end_date = parse_date(end_date)

    if parsed_start_date.present? && parsed_end_date.present? && parsed_start_date <= parsed_end_date
      new(key.presence_in(OPTIONS.keys) || "month", offset: offset, custom_start_date: parsed_start_date, custom_end_date: parsed_end_date)
    else
      from_key(key, offset: offset)
    end
  end

  def self.as_options
    OPTIONS.map { |value, config| [ config[:label], value ] }
  end

  def initialize(key, offset: 0, custom_start_date: nil, custom_end_date: nil)
    @key = key
    @offset = offset.to_i
    @custom_start_date = custom_start_date
    @custom_end_date = custom_end_date
  end

  def label
    return "Custom" if custom?

    OPTIONS.fetch(key).fetch(:label)
  end

  def period
    return Period.custom(start_date: custom_start_date, end_date: custom_end_date) if custom?

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
    return period.days > CUSTOM_INTERVAL_THRESHOLD ? "1 month" : "1 day" if custom?

    OPTIONS.fetch(key).fetch(:interval)
  end

  def range_label
    return "#{I18n.l(period.start_date, format: :long)} - #{I18n.l(period.end_date, format: :long)}" if custom?

    case key
    when "week"
      "#{I18n.l(period.start_date, format: :long)} - #{I18n.l(period.end_date, format: :long)}"
    when "month"
      period.start_date.strftime("%B %Y")
    when "year"
      period.start_date.strftime("%Y")
    end
  end

  def custom?
    custom_start_date.present? && custom_end_date.present?
  end

  def start_date_value
    custom_start_date&.iso8601
  end

  def end_date_value
    custom_end_date&.iso8601
  end

  def previous_params
    navigation_params(-1)
  end

  def next_params
    navigation_params(1)
  end

  private
    def navigation_params(direction)
      if custom?
        shift = period.days * direction

        {
          window: key,
          start_date: (period.start_date + shift).iso8601,
          end_date: (period.end_date + shift).iso8601
        }
      else
        {
          window: key,
          offset: offset + direction
        }
      end
    end

    def self.parse_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
end

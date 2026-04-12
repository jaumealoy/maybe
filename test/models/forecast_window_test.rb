require "test_helper"

class ForecastWindowTest < ActiveSupport::TestCase
  test "month offset moves the displayed period" do
    window = Forecast::Window.from_key("month", offset: 1)

    assert_equal Date.current.next_month.beginning_of_month, window.period.start_date
    assert_equal Date.current.next_month.end_of_month, window.period.end_date
  end

  test "custom range uses the provided dates" do
    start_date = Date.current.next_month.beginning_of_month
    end_date = start_date + 9.days

    window = Forecast::Window.from_params(key: "month", start_date: start_date.iso8601, end_date: end_date.iso8601)

    assert_predicate window, :custom?
    assert_equal start_date, window.period.start_date
    assert_equal end_date, window.period.end_date
  end
end

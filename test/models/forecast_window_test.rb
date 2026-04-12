require "test_helper"

class ForecastWindowTest < ActiveSupport::TestCase
  test "month offset moves the displayed period" do
    window = Forecast::Window.from_key("month", offset: 1)

    assert_equal Date.current.next_month.beginning_of_month, window.period.start_date
    assert_equal Date.current.next_month.end_of_month, window.period.end_date
  end
end

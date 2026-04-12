require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @forecast = forecasts(:monthly_rent)
  end

  test "should get index" do
    get forecasts_url
    assert_response :success
  end

  test "should create forecast" do
    assert_difference("Forecast.count") do
      post forecasts_url, params: {
        forecast: {
          name: "Bonus",
          account_id: accounts(:depository).id,
          amount: 250,
          currency: "USD",
          kind: "income",
          schedule: "one_time",
          occurs_on: 1.day.from_now.to_date
        }
      }
    end

    assert_redirected_to forecasts_url
  end

  test "should materialize forecast" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      category: categories(:food_and_drink),
      name: "Gym",
      amount: 20,
      currency: "USD",
      kind: "expense",
      schedule: "one_time",
      occurs_on: Date.current
    )

    assert_difference [ "Entry.count", "Forecast::Materialization.count" ], 1 do
      post materialize_forecast_url(forecast)
    end

    assert_redirected_to forecasts_url
  end
end

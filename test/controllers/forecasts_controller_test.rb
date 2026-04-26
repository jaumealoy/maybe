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

  test "should show next period" do
    get forecasts_url, params: { window: "month", offset: 1 }

    assert_response :success
    assert_match Date.current.next_month.strftime("%B %Y"), response.body
  end


  test "should show custom date range" do
    start_date = Date.current.next_month.beginning_of_month
    end_date = start_date + 6.days

    get forecasts_url, params: { start_date: start_date.iso8601, end_date: end_date.iso8601 }

    assert_response :success
    assert_match start_date.strftime("%Y-%m-%d"), response.body
    assert_match end_date.strftime("%Y-%m-%d"), response.body
  end

  test "should render delta column in the simulation table" do
    get forecasts_url

    assert_response :success
    assert_match ">Delta<", response.body
  end
  test "should use saved account set" do
    get forecasts_url, params: { account_set_id: forecast_account_sets(:liquid_assets).id }

    assert_response :success
    assert_match "Using set: Liquid assets", response.body
  end

  test "should order forecasts by next occurrence" do
    soon = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Soon forecast",
      amount: 10,
      currency: "USD",
      kind: "expense",
      schedule: "one_time",
      occurs_on: 1.day.from_now.to_date
    )

    later = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Later forecast",
      amount: 10,
      currency: "USD",
      kind: "expense",
      schedule: "one_time",
      occurs_on: 10.days.from_now.to_date
    )

    get forecasts_url

    assert_response :success
    assert_operator response.body.index(soon.name), :<, response.body.index(later.name)
  end

  test "should create forecast" do
    assert_difference("Forecast.count") do
      post forecasts_url, params: {
        account_id: accounts(:depository).id,
        forecast: {
          name: "Bonus",
          amount: 250,
          currency: "USD",
          kind: "income",
          schedule: "one_time",
          occurs_on: 1.day.from_now.to_date
        }
      }
    end

    assert_redirected_to forecasts_url
    assert_equal 1.day.from_now.to_date, Forecast.order(:created_at).last.occurs_on
  end

  test "should create yearly fixed forecast with annual increase" do
    assert_difference("Forecast.count") do
      post forecasts_url, params: {
        account_id: accounts(:depository).id,
        forecast: {
          name: "Annual insurance",
          amount: 250,
          annual_increase_rate: 4.5,
          currency: "USD",
          kind: "expense",
          schedule: "yearly",
          occurs_on: Date.current.next_month.beginning_of_month
        }
      }
    end

    assert_redirected_to forecasts_url
    forecast = Forecast.order(:created_at).last
    assert_equal "yearly", forecast.schedule
    assert_equal BigDecimal("4.5"), forecast.annual_increase_rate
  end

  test "should create account-value forecast" do
    assert_difference("Forecast.count") do
      post forecasts_url, params: {
        account_id: accounts(:investment).id,
        forecast: {
          name: "Brokerage yield",
          value_strategy: "percentage_of_balance",
          annual_rate: 6,
          currency: "USD",
          kind: "income",
          schedule: "monthly",
          day_of_month: 1,
          starts_on: Date.current.beginning_of_month
        }
      }
    end

    assert_redirected_to forecasts_url
    forecast = Forecast.order(:created_at).last
    assert_equal "percentage_of_balance", forecast.value_strategy
    assert_equal BigDecimal("6"), forecast.annual_rate
  end

  test "should create forecast account set" do
    assert_difference("ForecastAccountSet.count") do
      post forecast_account_sets_url, params: {
        window: "month",
        offset: 0,
        forecast_account_set: {
          name: "Cash only",
          account_ids: [ accounts(:depository).id ]
        }
      }
    end

    assert_redirected_to forecasts_url(window: "month", offset: 0, account_set_id: ForecastAccountSet.order(:created_at).last.id)
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

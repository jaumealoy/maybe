require "test_helper"

class ForecastTest < ActiveSupport::TestCase
  setup do
    @forecast = forecasts(:monthly_rent)
  end

  test "spread monthly forecasts do not require a day of month" do
    forecast = Forecast.new(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Distributed rent",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      spread_across_month: true
    )

    assert_predicate forecast, :valid?
    assert_equal "Monthly throughout month", forecast.schedule_label
  end

  test "monthly occurrence dates ignore already materialized dates and the past" do
    @forecast.materializations.create!(entry: entries(:transaction), occurrence_date: Date.current)

    dates = @forecast.occurrence_dates_between(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      from_date: Date.current.beginning_of_month
    )

    assert_not_includes dates, Date.current
  end

  test "materialize creates a real entry and materialization" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      category: categories(:food_and_drink),
      name: "Electric bill",
      amount: 95,
      currency: "USD",
      kind: "expense",
      schedule: "one_time",
      occurs_on: Date.current
    )

    assert_difference [ "Entry.count", "Forecast::Materialization.count" ], 1 do
      entry = forecast.materialize!(occurrence_date: Date.current)
      assert_equal 95, entry.amount.to_i
      assert_equal "Electric bill", entry.name
      assert_equal categories(:food_and_drink), entry.transaction.category
    end
  end
end

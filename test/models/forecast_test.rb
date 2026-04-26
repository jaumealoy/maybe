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

  test "annual forecasts recur on the start date anniversary" do
    forecast = Forecast.new(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Annual insurance",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "annual",
      starts_on: Date.new(2024, 5, 10)
    )

    assert_predicate forecast, :valid?
    assert_equal "Annual on May 10", forecast.schedule_label
    assert_equal [
      Date.new(2026, 5, 10),
      Date.new(2027, 5, 10)
    ], forecast.occurrence_dates_between(
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2027, 12, 31),
      from_date: Date.new(2026, 1, 1)
    )
  end

  test "annual forecasts require a start date" do
    forecast = Forecast.new(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Annual insurance",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "annual"
    )

    assert_not forecast.valid?
    assert_includes forecast.errors[:starts_on], "can't be blank"
  end

  test "annual forecasts clamp leap day anniversaries to month end" do
    forecast = Forecast.new(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Leap day bill",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "annual",
      starts_on: Date.new(2024, 2, 29)
    )

    assert_equal [
      Date.new(2025, 2, 28),
      Date.new(2026, 2, 28),
      Date.new(2027, 2, 28),
      Date.new(2028, 2, 29)
    ], forecast.occurrence_dates_between(
      start_date: Date.new(2025, 1, 1),
      end_date: Date.new(2028, 12, 31),
      from_date: Date.new(2025, 1, 1)
    )
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

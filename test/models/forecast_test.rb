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

  test "projection events apply annual increases after each anniversary" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Inflating rent",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      day_of_month: 1,
      starts_on: Date.new(2024, 1, 1),
      annual_increase_rate: 10
    )

    events = forecast.projection_events_between(
      target_currency: "USD",
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 1, 31),
      from_date: Date.new(2026, 1, 1)
    )

    assert_equal Date.new(2026, 1, 1), events.first.first
    assert_equal BigDecimal("-121"), events.first.last
  end

  test "spread monthly forecasts with annual increases prorate partial months" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Inflating utilities",
      amount: 300,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      spread_across_month: true,
      starts_on: Date.new(2024, 6, 16),
      annual_increase_rate: 10
    )

    first_june = forecast.projection_events_between(
      target_currency: "USD",
      start_date: Date.new(2024, 6, 16),
      end_date: Date.new(2024, 6, 30),
      from_date: Date.new(2024, 6, 16)
    )

    second_june = forecast.projection_events_between(
      target_currency: "USD",
      start_date: Date.new(2025, 6, 16),
      end_date: Date.new(2025, 6, 30),
      from_date: Date.new(2025, 6, 16)
    )

    assert_equal BigDecimal("-150"), first_june.sum(&:last)
    assert_equal BigDecimal("-165"), second_june.sum(&:last)
  end

  test "yearly forecasts repeat on the same calendar date" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Insurance",
      amount: 500,
      currency: "USD",
      kind: "expense",
      schedule: "yearly",
      occurs_on: Date.new(2025, 6, 15),
      starts_on: Date.new(2025, 1, 1)
    )

    dates = forecast.occurrence_dates_between(
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2027, 12, 31),
      from_date: Date.new(2026, 1, 1)
    )

    assert_equal [Date.new(2026, 6, 15), Date.new(2027, 6, 15)], dates
    assert_equal "Yearly on Jun 15", forecast.schedule_label
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

  test "materialize uses the current account balance for account-value forecasts" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:investment),
      name: "Investment income",
      currency: "USD",
      kind: "income",
      schedule: "monthly",
      day_of_month: Date.current.day,
      starts_on: Date.current.beginning_of_month,
      value_strategy: "percentage_of_balance",
      annual_rate: 12
    )

    entry = forecast.materialize!(occurrence_date: Date.current)
    expected_amount = accounts(:investment).balance * BigDecimal("0.12") / 12

    assert_equal(-expected_amount.to_i, entry.amount.to_i)
  end

  test "entry amount can use an explicit projected balance for account-value forecasts" do
    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:investment),
      name: "Projected yield",
      currency: "USD",
      kind: "income",
      schedule: "monthly",
      day_of_month: 1,
      starts_on: Date.current.beginning_of_month,
      value_strategy: "percentage_of_balance",
      annual_rate: 12
    )

    assert_equal BigDecimal("-24"), forecast.entry_amount(occurrence_date: Date.current, balance_amount: 2400)
  end

  test "account-value forecasts materialize as zero when the account balance is zero" do
    accounts(:investment).update!(balance: 0)

    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:investment),
      name: "Empty yield",
      currency: "USD",
      kind: "income",
      schedule: "monthly",
      day_of_month: Date.current.day,
      starts_on: Date.current.beginning_of_month,
      value_strategy: "percentage_of_balance",
      annual_rate: 12
    )

    entry = forecast.materialize!(occurrence_date: Date.current)

    assert_equal 0, entry.amount.to_i
  end

  test "converted amount uses the occurrence date exchange rate when available" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.10, date: Date.current)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.05, date: 1.day.ago.to_date)

    forecast = Forecast.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "Consulting",
      amount: 100,
      currency: "EUR",
      kind: "income",
      schedule: "one_time",
      occurs_on: Date.current
    )

    assert_equal BigDecimal("110"), forecast.converted_amount("USD", occurrence_date: Date.current).amount
    assert_equal BigDecimal("105"), forecast.converted_amount("USD", occurrence_date: 1.day.ago.to_date).amount
  end
end

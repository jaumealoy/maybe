require "test_helper"

class Forecast::SimulatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.forecasts.delete_all
  end

  test "keeps balance continuity across future yearly windows" do
    Forecast.create!(
      family: @family,
      account: @account,
      name: "Monthly expense",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      day_of_month: 15,
      starts_on: Date.current.beginning_of_month
    )

    current_year = Forecast::Simulator.new(
      family: @family,
      account_ids: [ @account.id ],
      window: Forecast::Window.from_key("year")
    ).call

    next_year = Forecast::Simulator.new(
      family: @family,
      account_ids: [ @account.id ],
      window: Forecast::Window.from_key("year", offset: 1)
    ).call

    assert_equal current_year.rows.last.total_balance.amount, next_year.rows.first.total_balance.amount
  end

  test "distributes monthly forecasts across the days of the month" do
    next_month = Date.current.next_month

    Forecast.create!(
      family: @family,
      account: @account,
      name: "Distributed expense",
      amount: next_month.end_of_month.day,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      spread_across_month: true,
      starts_on: next_month.beginning_of_month
    )

    simulation = Forecast::Simulator.new(
      family: @family,
      account_ids: [ @account.id ],
      window: Forecast::Window.from_params(
        key: "month",
        start_date: next_month.beginning_of_month.iso8601,
        end_date: next_month.end_of_month.iso8601
      )
    ).call

    assert_equal(-1, simulation.rows.second.delta.amount)
    assert_equal(-1, simulation.rows.third.delta.amount)
  end

  test "applies annual increases to future fixed forecasts" do
    next_month = Date.current.next_month.beginning_of_month

    Forecast.create!(
      family: @family,
      account: @account,
      name: "Travel",
      amount: 100,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      day_of_month: 1,
      starts_on: next_month - 2.years,
      annual_increase_rate: 10
    )

    simulation = Forecast::Simulator.new(
      family: @family,
      account_ids: [ @account.id ],
      window: Forecast::Window.from_params(
        key: "custom",
        start_date: Date.current.iso8601,
        end_date: (next_month + 2.days).iso8601
      )
    ).call

    forecast_row = simulation.rows.find { |row| row.date == next_month }

    assert_equal(-121, forecast_row.delta.amount)
  end

  test "net positive recurring cash flow does not diverge negative with annualized spread expenses" do
    next_month = Date.current.next_month.beginning_of_month

    Forecast.create!(
      family: @family,
      account: @account,
      name: "Salary",
      amount: 1000,
      currency: "USD",
      kind: "income",
      schedule: "monthly",
      day_of_month: 1,
      starts_on: next_month - 2.years
    )

    Forecast.create!(
      family: @family,
      account: @account,
      name: "Living expenses",
      amount: 500,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      spread_across_month: true,
      starts_on: next_month - 2.years,
      annual_increase_rate: 10
    )

    simulation = Forecast::Simulator.new(
      family: @family,
      account_ids: [ @account.id ],
      window: Forecast::Window.from_params(
        key: "custom",
        start_date: Date.current.iso8601,
        end_date: 13.months.from_now.to_date.iso8601
      )
    ).call

    assert_operator simulation.rows.last.total_balance.amount, :>, simulation.rows.first.total_balance.amount
  end

  test "exposes row breakdown data for projected deltas" do
    next_month = Date.current.next_month.beginning_of_month

    Forecast.create!(
      family: @family,
      account: @account,
      category: categories(:income),
      name: "Salary",
      amount: 1000,
      currency: "USD",
      kind: "income",
      schedule: "monthly",
      day_of_month: 1,
      starts_on: next_month
    )

    Forecast.create!(
      family: @family,
      account: @account,
      category: categories(:food_and_drink),
      name: "Groceries",
      amount: 310,
      currency: "USD",
      kind: "expense",
      schedule: "monthly",
      spread_across_month: true,
      starts_on: next_month
    )

    simulation = Forecast::Simulator.new(
      family: @family,
      account_ids: [ @account.id ],
      window: Forecast::Window.from_params(
        key: "custom",
        start_date: Date.current.iso8601,
        end_date: (next_month + 1.day).iso8601
      )
    ).call

    projected_row = simulation.rows.find { |row| row.date == next_month }

    assert_equal 2, projected_row.breakdown.size
    assert_equal [ "Groceries", "Salary" ], projected_row.breakdown.map(&:concept).sort
    assert_equal [ "expense", "income" ], projected_row.breakdown.map(&:kind).sort
  end

  test "uses account balance for monthly account-value yield forecasts" do
    next_month = Date.current.next_month.beginning_of_month

    Forecast.create!(
      family: @family,
      account: accounts(:investment),
      name: "Investment income",
      currency: "USD",
      kind: "income",
      schedule: "monthly",
      day_of_month: 1,
      starts_on: Date.current.beginning_of_month,
      value_strategy: "percentage_of_balance",
      annual_rate: 12
    )

    simulation = Forecast::Simulator.new(
      family: @family,
      account_ids: [ accounts(:investment).id ],
      window: Forecast::Window.from_params(
        key: "custom",
        start_date: Date.current.iso8601,
        end_date: (next_month + 2.days).iso8601
      )
    ).call

    forecast_row = simulation.rows.find { |row| row.date == next_month }

    assert_equal(100, forecast_row.delta.amount)
  end
end

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
end

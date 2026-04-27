class Forecast::Simulator
  Result = Data.define(:accounts, :rows, :chart_series, :window)
  ForecastEvent = Data.define(:date, :amount, :forecast)
  BreakdownItem = Data.define(:date, :concept, :amount, :category_name, :kind)
  Row = Data.define(:date, :balances, :total_balance, :projected, :delta, :breakdown)

  def initialize(family:, account_ids:, window:, offset: 0)
    @family = family
    @account_ids = Array(account_ids).compact_blank
    @window = window.is_a?(Forecast::Window) ? window : Forecast::Window.from_key(window, offset: offset)
  end

  def call
    Result.new(
      accounts: accounts,
      rows: rows,
      chart_series: chart_series,
      window: window
    )
  end

  private
    attr_reader :family, :account_ids, :window

    def accounts
      @accounts ||= begin
        scope = family.accounts.manual.visible.alphabetically
        scope = scope.where(id: account_ids) if account_ids.present?
        scope.to_a
      end
    end

    def rows
      @rows ||= begin
        previous_balances = nil
        previous_total_balance = nil

        simulation_checkpoint_dates.filter_map do |date|
          previous_date = previous_date_for(date)
          balances, breakdown = if date <= Date.current
            [ actual_balances_for(date), actual_breakdown_between(previous_date, date) ]
          else
            projected_balances_for(date, previous_date, previous_balances)
          end

          previous_balances = balances
          total_balance = Money.new(balances.values.sum(&:amount), family.currency)
          next unless visible_checkpoint_dates.include?(date)

          row = Row.new(
            date: date,
            balances: balances,
            total_balance: total_balance,
            projected: date > Date.current,
            delta: previous_total_balance.present? ? Money.new(total_balance.amount - previous_total_balance.amount, family.currency) : nil,
            breakdown: previous_total_balance.present? ? breakdown : []
          )

          previous_total_balance = total_balance
          row
        end
      end
    end

    def chart_series
      series = Series.from_raw_values(
        rows.map { |row| { date: row.date, value: row.total_balance } },
        interval: window.interval
      )

      series.as_json.merge(forecast_start_date: Date.current)
    end

    def visible_checkpoint_dates
      @visible_checkpoint_dates ||= checkpoint_dates_for(window.period)
    end

    def simulation_checkpoint_dates
      @simulation_checkpoint_dates ||= checkpoint_dates_for(simulation_period)
    end

    def checkpoint_dates_for(period)
      if window.interval == "1 month"
        monthly_checkpoint_dates_for(period)
      else
        period.date_range.to_a
      end
    end

    def monthly_checkpoint_dates_for(period)
      dates = []
      cursor = period.start_date.beginning_of_month

      while cursor <= period.end_date
        dates << cursor
        cursor = cursor.next_month.beginning_of_month
      end

      dates << Date.current if period.start_date <= Date.current && Date.current <= period.end_date
      dates << period.end_date unless dates.last == period.end_date
      dates.uniq.sort
    end

    def previous_date_for(date)
      index = simulation_checkpoint_dates.index(date)
      return if index.blank? || index.zero?

      simulation_checkpoint_dates[index - 1]
    end

    def actual_balances_for(date)
      accounts.index_with do |account|
        actual_balance_points_by_account.fetch(account.id).fetch(date, fallback_current_balance_for(account))
      end
    end

    def projected_balances_for(date, previous_date, previous_balances)
      previous_balances ||= actual_balances_for(previous_date || Date.current)
      breakdown = []

      balances = accounts.index_with do |account|
        running_balance = previous_balances.fetch(account).amount

        applicable_forecast_events(account.id, previous_date, date).each do |event|
          event_amount = event.amount || event.forecast.signed_projection_amount(
            target_currency: family.currency,
            occurrence_date: event.date,
            balance_amount: running_balance
          )

          running_balance += event_amount
          breakdown << forecast_breakdown_item(event.forecast, event.date, event_amount)
        end

        Money.new(running_balance, family.currency)
      end

      [ balances, breakdown.sort_by(&:date) ]
    end

    def actual_balance_points_by_account
      @actual_balance_points_by_account ||= accounts.each_with_object({}) do |account, result|
        actual_period_end = [ simulation_period.end_date, Date.current ].min

        if actual_period_end < simulation_period.start_date || account.balances.none?
          result[account.id] = {}
          next
        end

        series = Balance::ChartSeriesBuilder.new(
          account_ids: [ account.id ],
          currency: family.currency,
          period: Period.custom(start_date: simulation_period.start_date, end_date: actual_period_end),
          favorable_direction: "up",
          interval: window.interval
        ).balance_series

        result[account.id] = series.values.index_by(&:date).transform_values(&:value)
      end
    end

    def forecast_events_by_account
      @forecast_events_by_account ||= forecasts.group_by(&:account_id).transform_values do |account_forecasts|
        account_forecasts.flat_map do |forecast|
          build_forecast_events(forecast)
        end.sort_by(&:date)
      end
    end

    def forecasts
      @forecasts ||= family.forecasts.includes(:materializations).for_accounts(filtered_account_ids).to_a
    end

    def fallback_current_balance_for(account)
      Money.new(account.balance_money.exchange_to(family.currency, fallback_rate: latest_exchange_rate_for(account.currency)).amount, family.currency)
    end

    def latest_exchange_rate_for(source_currency)
      ExchangeRate.latest_rate(from_currency: source_currency, to_currency: family.currency)
    end

    def filtered_account_ids
      @filtered_account_ids ||= accounts.map(&:id)
    end

    def simulation_period
      @simulation_period ||= Period.custom(start_date: [ window.period.start_date, Date.current ].min, end_date: window.period.end_date)
    end

    def applicable_forecast_events(account_id, previous_date, date)
      forecast_events_by_account.fetch(account_id, []).select do |event|
        event.date > (previous_date || Date.current) && event.date <= date
      end
    end

    def build_forecast_events(forecast)
      if forecast.percentage_of_balance?
        forecast.projection_occurrence_dates_between(
          start_date: [ Date.current, simulation_period.start_date ].min,
          end_date: window.period.end_date,
          from_date: Date.current
        ).map { |occurrence_date| ForecastEvent.new(date: occurrence_date, amount: nil, forecast: forecast) }
      else
        forecast.projection_events_between(
          target_currency: family.currency,
          start_date: [ Date.current, simulation_period.start_date ].min,
          end_date: window.period.end_date,
          from_date: Date.current
        ).map { |occurrence_date, amount| ForecastEvent.new(date: occurrence_date, amount: amount, forecast: forecast) }
      end
    end

    def actual_breakdown_between(previous_date, date)
      return [] if previous_date.blank?

      ((previous_date + 1.day)..date).flat_map do |entry_date|
        actual_entries_by_date.fetch(entry_date, []).map { |entry| entry_breakdown_item(entry) }
      end
    end

    def actual_entries_by_date
      @actual_entries_by_date ||= begin
        actual_period_end = [ simulation_period.end_date, Date.current ].min
        if actual_period_end < simulation_period.start_date
          {}
        else
          Entry.visible
            .where(account_id: filtered_account_ids, date: simulation_period.start_date..actual_period_end)
            .includes(:entryable)
            .chronological
            .to_a
            .group_by(&:date)
        end
      end
    end

    def entry_breakdown_item(entry)
      balance_effect = -entry.amount_money.exchange_to(
        family.currency,
        date: entry.date,
        fallback_rate: latest_exchange_rate_for(entry.currency)
      ).amount

      BreakdownItem.new(
        date: entry.date,
        concept: entry.name,
        amount: Money.new(balance_effect, family.currency),
        category_name: entry.transaction? ? entry.transaction.category&.name : nil,
        kind: balance_effect.negative? ? "expense" : "income"
      )
    end

    def forecast_breakdown_item(forecast, occurrence_date, amount)
      BreakdownItem.new(
        date: occurrence_date,
        concept: forecast.name,
        amount: Money.new(amount, family.currency),
        category_name: forecast.category&.name,
        kind: forecast.kind
      )
    end
end

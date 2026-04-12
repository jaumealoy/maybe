class Forecast::Simulator
  Result = Data.define(:accounts, :rows, :chart_series, :window)
  Row = Data.define(:date, :balances, :total_balance, :projected, :delta)

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
          balances = if date <= Date.current
            actual_balances_for(date)
          else
            projected_balances_for(date, previous_date_for(date), previous_balances)
          end

          previous_balances = balances
          total_balance = Money.new(balances.values.sum(&:amount), family.currency)
          next unless visible_checkpoint_dates.include?(date)

          row = Row.new(
            date: date,
            balances: balances,
            total_balance: total_balance,
            projected: date > Date.current,
            delta: previous_total_balance.present? ? Money.new(total_balance.amount - previous_total_balance.amount, family.currency) : nil
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

      accounts.index_with do |account|
        prior_balance = previous_balances.fetch(account)
        delta = forecast_amounts_by_account.fetch(account.id, []).sum do |occurrence_date, amount|
          occurrence_date > (previous_date || Date.current) && occurrence_date <= date ? amount : 0
        end

        Money.new(prior_balance.amount + delta, family.currency)
      end
    end

    def actual_balance_points_by_account
      @actual_balance_points_by_account ||= accounts.each_with_object({}) do |account, result|
        actual_period_end = [ simulation_period.end_date, Date.current ].min

        if actual_period_end < simulation_period.start_date
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

    def forecast_amounts_by_account
      @forecast_amounts_by_account ||= forecasts.group_by(&:account_id).transform_values do |account_forecasts|
        account_forecasts.flat_map do |forecast|
          forecast.projection_events_between(
            target_currency: family.currency,
            start_date: [ Date.current, simulation_period.start_date ].min,
            end_date: window.period.end_date,
            from_date: Date.current
          )
        end
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
end

class Forecast::Simulator
  Result = Data.define(:accounts, :rows, :chart_series, :window)
  Row = Data.define(:date, :balances, :total_balance, :projected)

  def initialize(family:, account_ids:, window:)
    @family = family
    @account_ids = Array(account_ids).compact_blank
    @window = Forecast::Window.from_key(window)
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

        checkpoint_dates.map do |date|
          balances = if date <= Date.current
            actual_balances_for(date)
          else
            projected_balances_for(date, previous_date_for(date), previous_balances)
          end

          previous_balances = balances

          Row.new(
            date: date,
            balances: balances,
            total_balance: Money.new(balances.values.sum(&:amount), family.currency),
            projected: date > Date.current
          )
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

    def checkpoint_dates
      @checkpoint_dates ||= begin
        period = window.period

        if window.interval == "1 month"
          dates = []
          cursor = period.start_date.beginning_of_month

          while cursor <= period.end_date
            dates << cursor
            cursor = cursor.next_month.beginning_of_month
          end

          dates << period.end_date unless dates.last == period.end_date
          dates.uniq
        else
          period.date_range.to_a
        end
      end
    end

    def previous_date_for(date)
      checkpoint_dates[checkpoint_dates.index(date) - 1]
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
        series = Balance::ChartSeriesBuilder.new(
          account_ids: [ account.id ],
          currency: family.currency,
          period: Period.custom(start_date: window.period.start_date, end_date: [ window.period.end_date, Date.current ].min),
          favorable_direction: "up",
          interval: window.interval
        ).balance_series

        result[account.id] = series.values.index_by(&:date).transform_values(&:value)
      end
    end

    def forecast_amounts_by_account
      @forecast_amounts_by_account ||= forecasts.group_by(&:account_id).transform_values do |account_forecasts|
        account_forecasts.flat_map do |forecast|
          converted_amount = forecast.converted_amount(family.currency).amount
          forecast.occurrence_dates_between(
            start_date: Date.current,
            end_date: window.period.end_date,
            from_date: Date.current
          ).map { |occurrence_date| [ occurrence_date, forecast.income? ? converted_amount : -converted_amount ] }
        end
      end
    end

    def forecasts
      @forecasts ||= family.forecasts.includes(:materializations).for_accounts(accounts.map(&:id)).to_a
    end

    def fallback_current_balance_for(account)
      Money.new(account.balance_money.exchange_to(family.currency, fallback_rate: latest_exchange_rate_for(account.currency)).amount, family.currency)
    end

    def latest_exchange_rate_for(source_currency)
      return 1 if source_currency == family.currency

      ExchangeRate.where(from_currency: source_currency, to_currency: family.currency).order(date: :desc).pick(:rate) || 1
    end
end

class ForecastsController < ApplicationController
  DEFAULT_SORT_DATE = Date.new(9999, 12, 31)
  before_action :set_accounts
  before_action :set_forecast, only: %i[edit update destroy materialize]

  ACCOUNT_SHORTCUTS = {
    "Cash" => [ "Depository" ],
    "Investments" => [ "Investment", "Crypto" ],
    "Properties" => [ "Property" ]
  }.freeze

  def index
    @selected_account_set = selected_account_set
    @selected_account_ids = selected_account_ids
    @window = Forecast::Window.from_params(
      key: params[:window],
      offset: params[:offset],
      start_date: params[:start_date],
      end_date: params[:end_date]
    )
    @simulation = Forecast::Simulator.new(
      family: Current.family,
      account_ids: @selected_account_ids,
      window: @window
    ).call
    @forecast_account_sets = Current.family.forecast_account_sets.alphabetically
    @account_shortcuts = build_account_shortcuts
    @forecasts = Current.family.forecasts
      .includes(:account, :category, :tags)
      .for_accounts(@selected_account_ids.presence || @accounts.map(&:id))
      .alphabetically
      .to_a
      .sort_by { |forecast| [ forecast.next_occurrence_date || DEFAULT_SORT_DATE, forecast.name ] }

    @breadcrumbs = [ [ "Forecast", nil ] ]
  end

  def new
    @forecast = Current.family.forecasts.new(
      currency: Current.family.currency,
      kind: "expense",
      schedule: "monthly",
      value_strategy: "fixed_amount"
    )

    render layout: false
  end

  def create
    @forecast = Current.family.forecasts.new(forecast_params.merge(account: selected_account_for_params))

    if @forecast.save
      redirect_to forecasts_path, notice: "Forecast created"
    else
      render :new, status: :unprocessable_entity, layout: false
    end
  end

  def edit
    render layout: false
  end

  def update
    if @forecast.update(forecast_params.merge(account: selected_account_for_params))
      redirect_to forecasts_path, notice: "Forecast updated"
    else
      render :edit, status: :unprocessable_entity, layout: false
    end
  end

  def destroy
    @forecast.destroy
    redirect_to forecasts_path, notice: "Forecast deleted"
  end

  def materialize
    occurrence_date = @forecast.materializable_occurrence_date

    if occurrence_date.blank?
      redirect_to forecasts_path, alert: "This forecast is not due yet"
      return
    end

    entry = @forecast.materialize!(occurrence_date: occurrence_date)
    entry.sync_account_later
    entry.lock_saved_attributes!
    entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?

    redirect_to forecasts_path, notice: "Forecast materialized"
  end

  private
    def set_accounts
      @accounts = Current.family.accounts.manual.visible.alphabetically
    end

    def selected_account_ids
      ids = Array(params[:account_ids]).compact_blank
      ids = @selected_account_set&.account_ids if ids.blank? && @selected_account_set.present?
      return @accounts.pluck(:id) if ids.blank?

      @accounts.where(id: ids).pluck(:id)
    end

    def selected_account_set
      return nil if params[:account_set_id].blank?

      account_set = Current.family.forecast_account_sets.find_by(id: params[:account_set_id])
      return nil if account_set.blank?

      explicit_ids = Array(params[:account_ids]).compact_blank.map(&:to_s)
      return account_set if explicit_ids.blank? || explicit_ids.sort == account_set.account_ids.map(&:to_s).sort

      nil
    end

    def build_account_shortcuts
      ACCOUNT_SHORTCUTS.map do |label, accountable_types|
        ids = @accounts.where(accountable_type: accountable_types).pluck(:id)
        next if ids.empty?

        { label: label, account_ids: ids }
      end.compact
    end

    def set_forecast
      @forecast = Current.family.forecasts.find(params[:id])
    end

    def forecast_params
      params.require(:forecast).permit(
        :name,
        :category_id,
        :amount,
        :value_strategy,
        :annual_rate,
        :annual_increase_rate,
        :currency,
        :kind,
        :schedule,
        :spread_across_month,
        :occurs_on,
        :day_of_month,
        :starts_on,
        :ends_on,
        tag_ids: []
      )
    end

    def selected_account_for_params
      Current.family.accounts.manual.find(params.fetch(:account_id))
    end
end

class ForecastsController < ApplicationController
  before_action :set_accounts
  before_action :set_forecast, only: %i[edit update destroy materialize]

  def index
    @selected_account_ids = selected_account_ids
    @window = Forecast::Window.from_key(params[:window])
    @simulation = Forecast::Simulator.new(
      family: Current.family,
      account_ids: @selected_account_ids,
      window: @window.key
    ).call
    @forecasts = Current.family.forecasts
      .includes(:account, :category, :tags)
      .for_accounts(@selected_account_ids.presence || @accounts.map(&:id))
      .alphabetically

    @breadcrumbs = [ [ "Forecast", nil ] ]
  end

  def new
    @forecast = Current.family.forecasts.new(currency: Current.family.currency, kind: "expense", schedule: "monthly")

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
      return @accounts.pluck(:id) if ids.blank?

      @accounts.where(id: ids).pluck(:id)
    end

    def set_forecast
      @forecast = Current.family.forecasts.find(params[:id])
    end

    def forecast_params
      params.require(:forecast).permit(
        :name,
        :category_id,
        :amount,
        :currency,
        :kind,
        :schedule,
        :occurs_on,
        :day_of_month,
        :starts_on,
        :ends_on,
        tag_ids: []
      )
    end

    def selected_account_for_params
      Current.family.accounts.manual.find(params.require(:forecast).fetch(:account_id))
    end
end

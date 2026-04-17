class ForecastAccountSetsController < ApplicationController
  def create
    @forecast_account_set = Current.family.forecast_account_sets.new(forecast_account_set_params)

    if @forecast_account_set.save
      redirect_to forecasts_path(window: params[:window], offset: params[:offset], start_date: params[:start_date], end_date: params[:end_date], account_set_id: @forecast_account_set.id), notice: "Account set saved"
    else
      redirect_to forecasts_path(window: params[:window], offset: params[:offset], start_date: params[:start_date], end_date: params[:end_date], account_ids: params[:forecast_account_set][:account_ids]), alert: @forecast_account_set.errors.full_messages.to_sentence
    end
  end

  def destroy
    account_set = Current.family.forecast_account_sets.find(params[:id])
    account_set.destroy

    redirect_to forecasts_path(window: params[:window], offset: params[:offset], start_date: params[:start_date], end_date: params[:end_date]), notice: "Account set deleted"
  end

  private
    def forecast_account_set_params
      params.require(:forecast_account_set).permit(:name, account_ids: [])
    end
end
